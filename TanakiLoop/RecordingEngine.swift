import AVFoundation
import AudioToolbox
import Accelerate
import OSLog

private let log = Logger(subsystem: "com.altbizney.jammy", category: "audio")

// MARK: - Track

// A track IS a sample: one recorded sound + step toggles, one row per bar.
struct Track: Identifiable, Equatable {
    let id: UUID = UUID()
    let colorIndex: Int   // stable — survives other tracks being removed
    var steps: [[Bool]]   // [bar][step]
    var hasSample: Bool = false
    var sampleDuration: TimeInterval = 0

    init(colorIndex: Int, bars: Int) {
        self.colorIndex = colorIndex
        self.steps = Array(repeating: Array(repeating: false, count: LoopEngine.stepCount),
                           count: max(1, bars))
    }

    var hasAnySteps: Bool { steps.contains { $0.contains(true) } }
}

// MARK: - LoopEngine

final class LoopEngine: ObservableObject, @unchecked Sendable {

    static let stepCount = 16   // one bar of 4/4 at 16th-note resolution
    static let maxTracks = 8
    static let maxBars   = 8
    static let minBPM: Double = 40
    static let maxBPM: Double = 240

    // MARK: - Published state

    // Always exactly 8 tracks — slots and sequencer rows correspond one-to-one.
    @Published private(set) var tracks:        [Track] = (0..<8).map { Track(colorIndex: $0, bars: 1) }
    @Published private(set) var isPlaying:     Bool    = false
    @Published private(set) var isRecording:   Bool    = false
    @Published private(set) var currentStep:   Int     = 0    // 0..<16, within the playing bar
    @Published private(set) var currentBar:    Int     = 0
    @Published private(set) var barCount:      Int     = 1
    @Published private(set) var loopedBar:     Int?    = nil   // when set, only this bar plays
    @Published private(set) var bpm:           Double  = 120
    @Published private(set) var armedTrack:    Int     = 0
    @Published private(set) var fftMagnitudes: [Float] = [Float](repeating: 0, count: 64)
    @Published private(set) var metronomeOn:     Bool  = false
    @Published private(set) var metronomeSilent: Bool  = false  // haptics only, no click
    @Published private(set) var metronomeBeat: Int     = -1   // 0–3, cycles every beat; 0 = downbeat
    @Published private(set) var countInEnabled: Bool   = false
    @Published private(set) var isCountingIn:   Bool   = false
    @Published private(set) var countInBeat:    Int    = 0    // 4,3,2,1 while counting in
    @Published private(set) var canUndo:        Bool   = false
    @Published private(set) var canRedo:        Bool   = false

    // MARK: - Audio engine

    private let audioEngine = AVAudioEngine()
    private var inputTapInstalled = false

    // All track players route through this submix so their output can be tapped for
    // resampling. The metronome connects to the main mixer directly — clicks are
    // never captured into recordings.
    private let trackMixer = AVAudioMixerNode()
    private var outputTapInstalled = false

    // Player nodes / sample buffers, keyed by track id.
    // Guarded by stateLock — read from the sequencer queue, mutated on main.
    private let stateLock = NSLock()
    private var playerNodes: [UUID: AVAudioPlayerNode] = [:]
    private var sampleBufs:  [UUID: AVAudioPCMBuffer]  = [:]

    // MARK: - Sequencer

    private let seqQueue = DispatchQueue(label: "com.altbizney.jammy.sequencer", qos: .userInteractive)
    private var stepTimer: DispatchSourceTimer?
    private var nextDeadline: DispatchTime = .now()

    // Guarded by stateLock
    private var seqRunning:    Bool = false
    private var nextStepIndex: Int = 0          // global: 0..<(stepCount * bars)
    private var bpmValue:      Double = 120
    private var barsValue:     Int = 1
    private var loopedBarValue: Int = -1        // -1 = play all bars; else confine to this bar
    private var gridSnapshot:  [(id: UUID, steps: [[Bool]])] = []
    private var lastStepDate:  Date = .distantPast
    private var lastStepIndex: Int = 0          // global index

    private var stepInterval: TimeInterval { 60.0 / bpmValue / 4.0 }

    // MARK: - Metronome

    private let metroNode = AVAudioPlayerNode()
    private var metroAccentBuf: AVAudioPCMBuffer?
    private var metroTickBuf:   AVAudioPCMBuffer?
    private var metroTimer: DispatchSourceTimer?          // standalone clock (seqQueue only)
    private var metroDeadline: DispatchTime = .now()      // seqQueue only
    private var metroBeatCount = 0                        // seqQueue only
    private var metronomeEnabled = false                  // guarded by stateLock
    private var metronomeSilentValue = false              // guarded by stateLock

    // Count-in (seqQueue only)
    private var countTimer: DispatchSourceTimer?
    private var countDeadline: DispatchTime = .now()
    private var countRemaining = 0
    private var countActive = false

    // MARK: - Ring buffer (always-on mic capture, ~60 s at 48 kHz)

    private let ringCapacity = 48_000 * 60
    private var ringBuffer   = [Float](repeating: 0, count: 48_000 * 60)
    private var ringWritePos: Int = 0      // audio thread writes; Int is word-atomic on arm64
    private var captureStartPos: Int = 0
    private var captureFormat:   AVAudioFormat?

    // Playback ring buffer (track-submix output) — mixed into recordings for resampling.
    private var outRing        = [Float](repeating: 0, count: 48_000 * 60)
    private var outWritePos:   Int    = 0
    private var outCaptureStart: Int  = 0
    private var outSampleRate: Double = 0

    // AudioQueue fallback — used when AVAudioEngine inputNode reports sr=0 (iOS 26 USB "Other" bug)
    private var inputQueue:          AudioQueueRef? = nil
    private var aqChannels:          Int            = 1
    private var usingAudioQueueInput: Bool          = false

    // MARK: - FFT

    private let fftN         = 1024
    private let fftBinCount  = 64
    private var fftSetup:    FFTSetup?
    private var fftWindow    = [Float](repeating: 0, count: 1024)
    private var fftInput     = [Float](repeating: 0, count: 1024)
    private var fftSmooth    = [Float](repeating: 0, count: 64)
    private var fftNextFire: Date = .distantPast

    // MARK: - Recording

    private var recordTrackID:   UUID? = nil
    private var recordStartStep: Int?  = nil   // quantized grid step when recording started while playing

    // MARK: - Init

    private var routeObserver:    NSObjectProtocol?
    private var engineObserver:   NSObjectProtocol?
    private var routeChangeWork:  DispatchWorkItem?

    init() {
        setupAudioSession()
        fftSetup = vDSP_create_fftsetup(vDSP_Length(10), FFTRadix(kFFTRadix2))
        vDSP_hann_window(&fftWindow, vDSP_Length(fftN), Int32(vDSP_HANN_DENORM))
        setupMetronome()
        syncGrid()
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in self?.handleRouteChange(note) }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine, queue: .main
        ) { [weak self] _ in self?.handleEngineConfigChange() }
        #endif
    }

    deinit {
        teardownInputTap()
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
        if let obs = routeObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = engineObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Audio session

    private func setupAudioSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        var opts: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if !externalOutputConnected { opts.insert(.defaultToSpeaker) }
        try? s.setCategory(.playAndRecord, mode: .default, options: opts)
        try? s.setPreferredSampleRate(48_000)
        // Small IO buffer for snappy pad-trigger latency (default is ~23 ms)
        try? s.setPreferredIOBufferDuration(0.005)
        // Never request more channels than available — on iOS 26, requesting 2 when only
        // 1 is present (built-in mic) causes a continuous route re-negotiation storm.
        let availCh = max(1, s.inputNumberOfChannels)
        try? s.setPreferredInputNumberOfChannels(min(2, availCh))
        try? s.setActive(true)
        log.info("setupAudioSession: external=\(self.externalOutputConnected) sr=\(s.sampleRate) inputs=\(availCh)")
        #endif
    }

    // True when any non-built-in output is active (headphones, BT, USB — including
    // USB interfaces whose port type iOS reports as "Other" instead of .usbAudio).
    private var externalOutputConnected: Bool {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
        #else
        return true
        #endif
    }

    private func updatePlaybackVolume() {
        let vol: Float = (isRecording && !externalOutputConnected) ? 0.25 : 1.0
        audioEngine.mainMixerNode.outputVolume = vol
    }

    // Re-apply session options and re-install the input tap whenever the hardware
    // route changes (USB interface plugged in or removed).
    private func handleRouteChange(_ notification: Notification) {
        // Debounce: iOS 26 can fire dozens of route-change notifications in rapid succession
        // (especially during route negotiation). Cancel any pending work and reschedule so
        // we only act once, 300 ms after the last notification in the burst.
        routeChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyRouteChange() }
        routeChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    private func applyRouteChange() {
        // Do NOT call setupAudioSession here — setCategory/setPreferredInputNumberOfChannels
        // trigger another route change notification, creating an infinite loop.
        // The session is configured once at init() and iOS handles output routing automatically.
        updatePlaybackVolume()
        teardownInputTap()
        guard audioEngine.isRunning, !inputTapInstalled else { return }
        installInputTap()
    }

    // AVAudioEngine posts this when hardware configuration changes and stops the engine.
    // Reconnect all player nodes (graph connections are invalidated) and restart.
    // The sequencer clock keeps running independently — triggers resume at the next step.
    private func handleEngineConfigChange() {
        teardownInputTap()
        if outputTapInstalled {
            trackMixer.removeTap(onBus: 0)
            outputTapInstalled = false
        }
        stateLock.lock()
        audioEngine.attach(trackMixer)
        audioEngine.connect(trackMixer, to: audioEngine.mainMixerNode, format: nil)
        for (id, node) in playerNodes {
            guard let buf = sampleBufs[id] else { continue }
            audioEngine.attach(node)
            audioEngine.connect(node, to: trackMixer, format: buf.format)
        }
        audioEngine.attach(metroNode)
        if let fmt = metroAccentBuf?.format {
            audioEngine.connect(metroNode, to: audioEngine.mainMixerNode, format: fmt)
        }
        stateLock.unlock()
        guard isPlaying || isRecording || metronomeOn else { return }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            log.error("handleEngineConfigChange: restart failed: \(error)")
            return
        }
        installInputTap()
        installOutputTapIfNeeded()
    }

    // MARK: - Engine lifecycle

    private func startEngineIfNeeded() {
        guard !audioEngine.isRunning else {
            installOutputTapIfNeeded()
            return
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            installInputTap()
            installOutputTapIfNeeded()
        } catch { print("Engine error: \(error)") }
    }

    private func installInputTap() {
        guard !inputTapInstalled else { return }
        inputTapInstalled = true   // claim immediately — prevents double-install from concurrent calls
        let inputNode = audioEngine.inputNode
        let hwFmt     = inputNode.outputFormat(forBus: 0)

        #if os(iOS)
        let session   = AVAudioSession.sharedInstance()
        let sessionSR = session.sampleRate
        let sessionCh = session.inputNumberOfChannels
        #else
        let sessionSR = 44_100.0
        let sessionCh = 1
        #endif

        log.info("installInputTap: hwFmt sr=\(hwFmt.sampleRate) ch=\(hwFmt.channelCount) sessionSR=\(sessionSR) sessionCh=\(sessionCh)")

        if hwFmt.sampleRate > 0 {
            // Standard path: engine knows the hw format, tap with nil (native format).
            captureFormat = AVAudioFormat(standardFormatWithSampleRate: hwFmt.sampleRate, channels: 1)
            inputNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
                self?.processEngineTapBuffer(buffer)
            }
            inputTapInstalled = true
            log.info("installInputTap: engine tap installed ✓ sr=\(hwFmt.sampleRate)")
        } else {
            // iOS 26 USB "Other" fallback: inputNode can't resolve format (sr=0).
            // AudioQueue bypasses AVAudioEngine format detection and talks to CoreAudio directly.
            let sr = sessionSR > 0 ? sessionSR : 48_000.0
            let ch = max(1, min(2, sessionCh))
            startAudioQueueInput(sampleRate: sr, channels: ch)
        }
    }

    // Shared input buffer processing for AVAudioEngine tap path.
    private func processEngineTapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let chData = buffer.floatChannelData else { return }
        let n       = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        let ch0     = chData[0]
        let ch1: UnsafeMutablePointer<Float>? = chCount > 1 ? chData[1] : nil

        if let cf = captureFormat, cf.sampleRate != buffer.format.sampleRate {
            captureFormat = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1)
            log.info("captureFormat updated to \(buffer.format.sampleRate) Hz")
        }

        let cap = ringCapacity
        for i in 0..<n {
            ringBuffer[ringWritePos % cap] = ch1 != nil ? (ch0[i] + ch1![i]) * 0.5 : ch0[i]
            ringWritePos += 1
        }

        let now = Date()
        guard now > fftNextFire else { return }
        fftNextFire = now.addingTimeInterval(1.0 / 30.0)
        if let ch1 {
            var mixed = [Float](repeating: 0, count: n)
            mixed.withUnsafeMutableBufferPointer { buf in
                for i in 0..<n { buf[i] = (ch0[i] + ch1[i]) * 0.5 }
            }
            mixed.withUnsafeBufferPointer { computeFFT(samples: $0.baseAddress!, count: n) }
        } else {
            computeFFT(samples: ch0, count: n)
        }
    }

    // Called from AudioQueue C callback — must be fast, no allocations.
    func processRawAudioSamples(ptr: UnsafePointer<Float>, frameCount: Int, channelCount: Int) {
        let cap = ringCapacity
        for i in 0..<frameCount {
            let s: Float = channelCount > 1
                ? (ptr[i * channelCount] + ptr[i * channelCount + 1]) * 0.5
                : ptr[i]
            ringBuffer[ringWritePos % cap] = s
            ringWritePos += 1
        }
        let now = Date()
        guard now > fftNextFire else { return }
        fftNextFire = now.addingTimeInterval(1.0 / 30.0)
        if channelCount > 1 {
            var mixed = [Float](repeating: 0, count: frameCount)
            mixed.withUnsafeMutableBufferPointer { buf in
                for i in 0..<frameCount { buf[i] = (ptr[i * channelCount] + ptr[i * channelCount + 1]) * 0.5 }
            }
            mixed.withUnsafeBufferPointer { computeFFT(samples: $0.baseAddress!, count: frameCount) }
        } else {
            computeFFT(samples: ptr, count: frameCount)
        }
    }

    // MARK: - AudioQueue input (iOS 26 USB "Other" fallback)

    private func startAudioQueueInput(sampleRate: Double, channels: Int) {
        aqChannels = channels
        captureFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // C callback: no Swift captures allowed — engine is recovered via userData.
        let aqCallback: AudioQueueInputCallback = { userData, queue, buffer, _, numPackets, _ in
            defer { AudioQueueEnqueueBuffer(queue, buffer, 0, nil) }
            guard let userData, numPackets > 0 else { return }
            let engine    = Unmanaged<LoopEngine>.fromOpaque(userData).takeUnretainedValue()
            let ch        = engine.aqChannels
            let byteCount = Int(buffer.pointee.mAudioDataByteSize)
            let frames    = byteCount / (ch * 4)
            guard frames > 0 else { return }
            let ptr = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
            engine.processRawAudioSamples(ptr: ptr, frameCount: frames, channelCount: ch)
        }

        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        guard AudioQueueNewInput(&asbd, aqCallback, selfRef, nil, nil, 0, &inputQueue) == noErr,
              let q = inputQueue else {
            log.error("startAudioQueueInput: AudioQueueNewInput failed sr=\(sampleRate) ch=\(channels)")
            return
        }

        let bufSize = UInt32(512 * channels * 4)
        for _ in 0..<3 {
            var buf: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(q, bufSize, &buf) == noErr, let buf {
                AudioQueueEnqueueBuffer(q, buf, 0, nil)
            }
        }

        guard AudioQueueStart(q, nil) == noErr else {
            log.error("startAudioQueueInput: AudioQueueStart failed")
            AudioQueueDispose(q, true); inputQueue = nil
            return
        }
        usingAudioQueueInput = true
        inputTapInstalled    = true
        log.info("startAudioQueueInput: ✓ sr=\(sampleRate) ch=\(channels)")
    }

    private func stopAudioQueueInput() {
        guard let q = inputQueue else { return }
        AudioQueueStop(q, true)
        AudioQueueDispose(q, true)
        inputQueue           = nil
        usingAudioQueueInput = false
        inputTapInstalled    = false
    }

    private func teardownInputTap() {
        if usingAudioQueueInput {
            stopAudioQueueInput()
        } else if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
    }

    // MARK: - FFT

    private func computeFFT(samples: UnsafePointer<Float>, count: Int) {
        guard let setup = fftSetup else { return }
        let n     = fftN
        let halfN = n / 2

        // Slide input window forward with new samples
        fftInput.withUnsafeMutableBufferPointer { buf in
            let p     = buf.baseAddress!
            let shift = min(count, n)
            let keep  = n - shift
            if keep > 0 { memmove(p, p.advanced(by: shift), keep * MemoryLayout<Float>.size) }
            memcpy(p.advanced(by: keep),
                   samples.advanced(by: max(0, count - shift)),
                   shift * MemoryLayout<Float>.size)
        }

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(fftInput, 1, fftWindow, 1, &windowed, 1, vDSP_Length(n))

        // Real FFT via split-complex
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var mags  = [Float](repeating: 0, count: halfN)

        windowed.withUnsafeBytes { rawBuf in
            rawBuf.withMemoryRebound(to: DSPComplex.self) { cBuf in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cBuf.baseAddress!, 2, &split, 1, vDSP_Length(halfN))
                        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(10), FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        var scale = Float(2.0) / Float(n)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(halfN))

        // Map to log-spaced display bins (~130 Hz – ~9 kHz)
        let dispN  = fftBinCount
        let minBin = 3
        let maxBin = min(halfN - 2, 210)
        var result = [Float](repeating: 0, count: dispN)

        for i in 0..<dispN {
            let t    = Double(i) / Double(dispN - 1)
            let binF = Double(minBin) * pow(Double(maxBin) / Double(minBin), t)
            let b0   = max(0, min(halfN - 2, Int(binF)))
            let frac = Float(binF - Double(Int(binF)))
            let mag  = mags[b0] * (1 - frac) + mags[b0 + 1] * frac
            let db   = 20.0 * log10f(max(mag, 1e-8))
            let norm = max(0, min(1, (db + 80.0) / 80.0))
            result[i] = max(norm, fftSmooth[i] * 0.82)   // fast attack, slow decay
        }
        fftSmooth = result
        DispatchQueue.main.async { self.fftMagnitudes = result }
    }

    // MARK: - Transport

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    private func play() {
        guard !isPlaying else { return }
        startEngineIfNeeded()
        isPlaying = true
        updatePlaybackVolume()
        stateLock.lock()
        seqRunning = true
        stateLock.unlock()
        seqQueue.async { [weak self] in
            guard let self else { return }
            // The sequencer clock drives metronome beats while playing.
            self.metroTimer?.cancel()
            self.metroTimer = nil
            self.nextDeadline = .now()
            self.tick()
        }
    }

    private func pause() {
        guard isPlaying else { return }
        isPlaying = false
        stateLock.lock()
        seqRunning = false
        let metroOn = metronomeEnabled
        let nodes = Array(playerNodes.values)
        stateLock.unlock()
        seqQueue.async { [weak self] in
            guard let self else { return }
            self.stepTimer?.cancel()
            self.stepTimer = nil
            nodes.forEach { $0.stop() }   // silence ringing tails
            if metroOn { self.startStandaloneMetronomeOnSeqQueue() }
        }
    }

    // MARK: - Metronome

    private func setupMetronome() {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return }
        metroAccentBuf = synthesizeClick(format: fmt, frequency: 1250, duration: 0.06, amplitude: 0.60)
        metroTickBuf   = synthesizeClick(format: fmt, frequency: 850,  duration: 0.05, amplitude: 0.42)
        audioEngine.attach(metroNode)
        audioEngine.connect(metroNode, to: audioEngine.mainMixerNode, format: fmt)
        audioEngine.attach(trackMixer)
        audioEngine.connect(trackMixer, to: audioEngine.mainMixerNode, format: nil)
    }

    // MARK: - Output tap (resampling)

    private func installOutputTapIfNeeded() {
        guard !outputTapInstalled else { return }
        let fmt = trackMixer.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        outSampleRate = fmt.sampleRate
        trackMixer.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            self?.processOutputTapBuffer(buffer)
        }
        outputTapInstalled = true
        log.info("installOutputTap: ✓ sr=\(fmt.sampleRate)")
    }

    private func processOutputTapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let chData = buffer.floatChannelData else { return }
        let n       = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        let ch0     = chData[0]
        let ch1: UnsafeMutablePointer<Float>? = chCount > 1 ? chData[1] : nil
        let cap = ringCapacity
        for i in 0..<n {
            outRing[outWritePos % cap] = ch1 != nil ? (ch0[i] + ch1![i]) * 0.5 : ch0[i]
            outWritePos += 1
        }
    }

    // Sum the playback ring into a freshly drained mic buffer (sample rates must match;
    // with a mismatched route the playback layer is skipped rather than pitch-shifted).
    private func mixOutputIntoBuffer(_ buf: AVAudioPCMBuffer, outStart: Int, outEnd: Int) {
        guard let fmt = captureFormat,
              outSampleRate > 0, abs(outSampleRate - fmt.sampleRate) < 1.0,
              let dst = buf.floatChannelData?[0] else { return }
        let n = min(Int(buf.frameLength), outEnd - outStart)
        guard n > 0 else { return }
        outRing.withUnsafeBufferPointer { rb in
            let ptr = rb.baseAddress!
            var si  = ((outStart % ringCapacity) + ringCapacity) % ringCapacity
            for i in 0..<n {
                dst[i] = max(-1.0, min(1.0, dst[i] + ptr[si]))
                si += 1
                if si == ringCapacity { si = 0 }
            }
        }
    }

    // Friendly woodblock-ish click: short sine burst with a fast exponential decay.
    private func synthesizeClick(format: AVAudioFormat, frequency: Double,
                                 duration: Double, amplitude: Float) -> AVAudioPCMBuffer? {
        let sr     = format.sampleRate
        let frames = AVAudioFrameCount(sr * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch  = buf.floatChannelData else { return nil }
        buf.frameLength = frames
        for c in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) {
                let t = Double(i) / sr
                ch[c][i] = Float(sin(2 * .pi * frequency * t) * exp(-t * 34.0)) * amplitude
            }
        }
        return buf
    }

    func toggleMetronome() {
        metronomeOn.toggle()
        let on = metronomeOn
        stateLock.lock()
        metronomeEnabled = on
        let playing = seqRunning
        stateLock.unlock()

        if on {
            startEngineIfNeeded()
            // While playing, the sequencer clock emits the beats; standalone clock
            // only needed when the transport is stopped.
            if !playing {
                seqQueue.async { [weak self] in self?.startStandaloneMetronomeOnSeqQueue() }
            }
        } else {
            seqQueue.async { [weak self] in
                self?.metroTimer?.cancel()
                self?.metroTimer = nil
            }
            DispatchQueue.main.async { [weak self] in self?.metronomeBeat = -1 }
        }
    }

    private func startStandaloneMetronomeOnSeqQueue() {
        metroTimer?.cancel()
        metroBeatCount = 0
        metroDeadline  = .now()
        metroTick()
    }

    // Standalone metronome clock — same drift-free pattern as the sequencer tick.
    private func metroTick() {
        stateLock.lock()
        let enabled  = metronomeEnabled && !seqRunning
        let interval = 60.0 / bpmValue
        stateLock.unlock()
        guard enabled else {
            metroTimer?.cancel()
            metroTimer = nil
            return
        }

        let beat = metroBeatCount % 4
        metroBeatCount += 1
        playClick(downbeat: beat == 0)
        DispatchQueue.main.async { [weak self] in self?.metronomeBeat = beat }

        metroDeadline = metroDeadline + interval
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: seqQueue)
        timer.schedule(deadline: metroDeadline, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.metroTick() }
        timer.resume()
        metroTimer = timer
    }

    func toggleMetronomeSilent() {
        metronomeSilent.toggle()
        stateLock.lock()
        metronomeSilentValue = metronomeSilent
        stateLock.unlock()
    }

    private func playClick(downbeat: Bool) {
        stateLock.lock()
        let silent = metronomeSilentValue
        stateLock.unlock()
        guard !silent,                       // silent mode: beats still publish for haptics
              audioEngine.isRunning,
              let buf = downbeat ? metroAccentBuf : metroTickBuf else { return }
        metroNode.scheduleBuffer(buf, at: nil, completionHandler: nil)
        metroNode.play()
    }

    // MARK: - Sequencer clock

    // Runs on seqQueue. Drift-free: the next deadline accumulates from the previous one,
    // and the interval is re-read each step so live tempo changes take effect immediately.
    private func tick() {
        stateLock.lock()
        guard seqRunning else { stateLock.unlock(); return }
        let bars     = max(1, barsValue)
        let total    = Self.stepCount * bars
        let loop     = loopedBarValue
        let useLoop  = loop >= 0 && loop < bars
        // In loop mode the bar is pinned and only the 16th step advances inside it.
        let stepIdx  = nextStepIndex % Self.stepCount
        let bar      = useLoop ? loop : (nextStepIndex % total) / Self.stepCount
        let global   = bar * Self.stepCount + stepIdx
        let snapshot = gridSnapshot
        let metroOn  = metronomeEnabled
        for (id, steps) in snapshot where bar < steps.count && steps[bar][stepIdx] {
            triggerLocked(id: id)
        }
        lastStepDate  = Date()
        lastStepIndex = global
        nextStepIndex = useLoop
            ? loop * Self.stepCount + ((stepIdx + 1) % Self.stepCount)
            : (global + 1) % total
        let interval  = stepInterval
        stateLock.unlock()

        if metroOn && stepIdx % 4 == 0 {
            playClick(downbeat: stepIdx == 0)
            let beat = stepIdx / 4
            DispatchQueue.main.async { [weak self] in self?.metronomeBeat = beat }
        }

        DispatchQueue.main.async { [weak self] in
            self?.currentStep = stepIdx
            self?.currentBar  = bar
        }

        nextDeadline = nextDeadline + interval
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: seqQueue)
        timer.schedule(deadline: nextDeadline, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        stepTimer = timer
    }

    // Monophonic retrigger: stop() cuts whatever this track is still playing,
    // then the sample restarts from the top. Must be called with stateLock held.
    private func triggerLocked(id: UUID) {
        guard audioEngine.isRunning,
              let node = playerNodes[id],
              let buf  = sampleBufs[id] else { return }
        node.stop()
        node.scheduleBuffer(buf, at: nil, completionHandler: nil)
        node.play()
    }

    // MARK: - Tempo

    func setBPM(_ newBPM: Double) {
        let clamped = max(Self.minBPM, min(Self.maxBPM, newBPM))
        bpm = clamped
        stateLock.lock()
        bpmValue = clamped
        stateLock.unlock()
    }

    // MARK: - Undo / Redo

    // Whole-project snapshots: tracks are value types and sample buffers are immutable
    // once recorded, so a snapshot is cheap (copy-on-write arrays + buffer references).
    private struct Snapshot {
        let tracks:     [Track]
        let barCount:   Int
        let sampleBufs: [UUID: AVAudioPCMBuffer]
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    // Call on main before any undoable mutation.
    private func pushUndo() {
        undoStack.append(currentSnapshot())
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoFlags()
    }

    private func currentSnapshot() -> Snapshot {
        stateLock.lock()
        let bufs = sampleBufs
        stateLock.unlock()
        return Snapshot(tracks: tracks, barCount: barCount, sampleBufs: bufs)
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        restore(snap)
        updateUndoFlags()
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        restore(snap)
        updateUndoFlags()
    }

    private func restore(_ snap: Snapshot) {
        stateLock.lock()
        for node in playerNodes.values {
            node.stop()
            audioEngine.detach(node)
        }
        playerNodes.removeAll()
        sampleBufs = snap.sampleBufs
        stateLock.unlock()

        tracks     = snap.tracks
        barCount   = snap.barCount
        armedTrack = min(armedTrack, tracks.count - 1)

        for t in tracks where t.hasSample {
            stateLock.lock()
            let buf = sampleBufs[t.id]
            stateLock.unlock()
            guard let buf else { continue }
            let node = AVAudioPlayerNode()
            audioEngine.attach(node)
            audioEngine.connect(node, to: trackMixer, format: buf.format)
            stateLock.lock()
            playerNodes[t.id] = node
            stateLock.unlock()
        }
        syncGrid()
    }

    // MARK: - Grid editing

    // Toggles a range of steps (one display cell at coarse resolutions covers several
    // 16th steps): if any step in the range is on, the whole range clears; otherwise
    // the first (musically aligned) step turns on.
    func toggleSteps(track: Int, bar: Int, range: Range<Int>) {
        guard tracks.indices.contains(track),
              tracks[track].steps.indices.contains(bar),
              range.lowerBound >= 0, range.upperBound <= Self.stepCount else { return }
        pushUndo()
        if tracks[track].steps[bar][range].contains(true) {
            for i in range { tracks[track].steps[bar][i] = false }
        } else {
            tracks[track].steps[bar][range.lowerBound] = true
        }
        syncGrid()
    }

    // MARK: - Bars

    // Adds a bar that starts as a copy of the current last bar, for every track.
    func addBar() {
        guard barCount < Self.maxBars else { return }
        pushUndo()
        for i in tracks.indices {
            let lastBar = tracks[i].steps[barCount - 1]
            tracks[i].steps.append(lastBar)
        }
        barCount += 1
        syncGrid()
    }

    func removeBar(_ index: Int) {
        guard barCount > 1, (0..<barCount).contains(index) else { return }
        pushUndo()
        for i in tracks.indices {
            tracks[i].steps.remove(at: index)
        }
        barCount -= 1
        // Keep any single-bar loop pointing at a valid bar (or clear it).
        if let lb = loopedBar, lb >= barCount { setLoopedBar(barCount - 1) }
        syncGrid()
    }

    // The bar the UI is currently showing — where paused recordings drop their default trigger.
    var editingBar: Int = 0
    func setEditingBar(_ bar: Int) { editingBar = max(0, bar) }

    // Single-bar loop: pass a bar index to confine playback to it, or nil to play all bars.
    func setLoopedBar(_ bar: Int?) {
        let b = (bar.map { (0..<barCount).contains($0) } ?? false) ? bar! : -1
        loopedBar = b >= 0 ? b : nil
        stateLock.lock()
        loopedBarValue = b
        stateLock.unlock()
    }

    // MARK: - Track management

    // Arm the track for recording; if it already holds a sample, audition it (Keezy pad feel).
    func selectTrack(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        armedTrack = index
        guard tracks[index].hasSample else { return }
        startEngineIfNeeded()
        stateLock.lock()
        triggerLocked(id: tracks[index].id)
        stateLock.unlock()
    }

    // Arm without auditioning (e.g. long-press on a row).
    func armTrack(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        armedTrack = index
    }

    // Clears a track's sample and steps — the row itself is permanent (always 8).
    func clearTrack(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        pushUndo()
        let id = tracks[index].id
        stateLock.lock()
        if let node = playerNodes[id] {
            node.stop()
            audioEngine.detach(node)
        }
        playerNodes.removeValue(forKey: id)
        sampleBufs.removeValue(forKey: id)
        stateLock.unlock()

        tracks[index].steps = Array(
            repeating: Array(repeating: false, count: Self.stepCount), count: barCount)
        tracks[index].hasSample      = false
        tracks[index].sampleDuration = 0
        syncGrid()
    }

    // Mirror the published track grid into the lock-guarded snapshot the sequencer reads.
    // Call on main after any tracks mutation.
    private func syncGrid() {
        stateLock.lock()
        gridSnapshot = tracks.map { ($0.id, $0.steps) }
        barsValue    = barCount
        stateLock.unlock()
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        #if os(iOS)
        let perm = AVAudioSession.sharedInstance().recordPermission
        if perm == .undetermined {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.startRecording() } }
            }
            return
        }
        guard perm == .granted else { return }
        #endif
        guard tracks.indices.contains(armedTrack) else { return }

        // Tapping record during an active count-in cancels it.
        if isCountingIn {
            cancelCountIn()
            return
        }
        // Count-in only makes sense from a stopped transport — when already playing you can
        // hear the beat, so recording quantizes immediately against the running clock.
        if countInEnabled && !isPlaying {
            beginCountIn()
            return
        }
        performStartRecording()
    }

    // MARK: - Count-in

    func toggleCountIn() {
        countInEnabled.toggle()
        if !countInEnabled, isCountingIn { cancelCountIn() }
    }

    func cancelCountIn() {
        isCountingIn = false
        countInBeat  = 0
        seqQueue.async { [weak self] in
            guard let self else { return }
            self.countActive = false
            self.countTimer?.cancel()
            self.countTimer = nil
            // Count-in aborted — bring the standalone metronome back if it was suppressed.
            self.stateLock.lock()
            let resume = self.metronomeEnabled && !self.seqRunning
            self.stateLock.unlock()
            if resume { self.startStandaloneMetronomeOnSeqQueue() }
        }
    }

    private func beginCountIn() {
        isCountingIn = true
        countInBeat  = 4
        startEngineIfNeeded()
        seqQueue.async { [weak self] in
            guard let self else { return }
            // The count-in IS the metronome for this bar — suppress the standalone clock so
            // they don't run on two different grids.
            self.metroTimer?.cancel()
            self.metroTimer = nil
            self.countActive    = true
            self.countRemaining = 4
            self.countDeadline  = .now()
            self.countTick()
        }
    }

    // One bar of 4/4 at the current tempo, then recording starts for real.
    private func countTick() {
        guard countActive else {
            countTimer?.cancel(); countTimer = nil
            return
        }
        if countRemaining == 0 {
            countActive = false
            countTimer?.cancel(); countTimer = nil
            // The metronome must continue the exact same grid the count-in established: the
            // next beat lands one interval after the last count, as a downbeat.
            let handoffDeadline = countDeadline
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCountingIn else { return }
                self.isCountingIn = false
                self.countInBeat  = 0
                self.performStartRecording()
                self.seqQueue.async {
                    self.stateLock.lock()
                    let resume = self.metronomeEnabled && !self.seqRunning
                    self.stateLock.unlock()
                    guard resume else { return }
                    self.metroTimer?.cancel()
                    self.metroBeatCount = 0
                    self.metroDeadline  = handoffDeadline
                    self.metroTick()
                }
            }
            return
        }

        playClick(downbeat: countRemaining == 4)
        let beat = countRemaining
        DispatchQueue.main.async { [weak self] in self?.countInBeat = beat }
        countRemaining -= 1

        stateLock.lock()
        let interval = 60.0 / bpmValue
        stateLock.unlock()
        countDeadline = countDeadline + interval
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: seqQueue)
        timer.schedule(deadline: countDeadline, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.countTick() }
        timer.resume()
        countTimer = timer
    }

    private func performStartRecording() {
        guard !isRecording, tracks.indices.contains(armedTrack) else { return }
        startEngineIfNeeded()
        recordTrackID = tracks[armedTrack].id

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let capSR   = captureFormat?.sampleRate ?? session.sampleRate
        let inLat   = session.inputLatency
        let outLat  = session.outputLatency
        let ioBuf   = session.ioBufferDuration
        #else
        let capSR   = captureFormat?.sampleRate ?? 48_000
        let inLat:  TimeInterval = 0
        let outLat: TimeInterval = 0
        let ioBuf:  TimeInterval = 0
        #endif

        if isPlaying {
            // Quantize into the grid: snap the start to the nearest 16th step.
            // The user taps in response to audio they heard outputLatency ago, so judge
            // their timing against the perceived tap time, not the wall clock.
            stateLock.lock()
            let stepDate = lastStepDate
            let stepIdx  = lastStepIndex
            let interval = stepInterval
            let total    = Self.stepCount * max(1, barsValue)
            stateLock.unlock()

            let perceived = Date().addingTimeInterval(-outLat)
            let fracPos   = Double(stepIdx) + perceived.timeIntervalSince(stepDate) / interval
            let nearest   = Int(round(fracPos))
            recordStartStep = ((nearest % total) + total) % total   // global step index

            // deltaSec > 0 → tap landed after the boundary: back-date the capture so it
            // begins exactly at the step (the ring buffer holds the past). deltaSec < 0 →
            // boundary is ahead: capture starts in the (near) future.
            // (inLat + ioBuf) shifts ringWritePos to the ring position of "now".
            let deltaSec = (fracPos - Double(nearest)) * interval
            captureStartPos = ringWritePos + Int(((inLat + ioBuf) - deltaSec) * max(capSR, 1.0))
            outCaptureStart = outWritePos - Int(deltaSec * max(outSampleRate, 0))
        } else {
            recordStartStep = nil
            captureStartPos = ringWritePos
            outCaptureStart = outWritePos
        }

        isRecording = true
        updatePlaybackVolume()
        log.info("startRecording: track=\(self.armedTrack) step=\(self.recordStartStep.map(String.init) ?? "-") inLat=\(inLat * 1000)ms outLat=\(outLat * 1000)ms ioBuf=\(ioBuf * 1000)ms capSR=\(capSR) captureStart=\(self.captureStartPos) ringWrite=\(self.ringWritePos)")
    }

    func stopRecording() {
        guard isRecording else { return }
        let endPos    = ringWritePos      // snapshot before any further audio arrives
        let outEndPos = outWritePos
        isRecording = false
        updatePlaybackVolume()

        let trackID   = recordTrackID
        let startStep = recordStartStep
        let start     = captureStartPos
        let outStart  = outCaptureStart
        recordTrackID   = nil
        recordStartStep = nil
        log.info("stopRecording: frames=\(endPos - start) tapInstalled=\(self.inputTapInstalled) captureFmt sr=\(self.captureFormat?.sampleRate ?? 0)")

        guard let trackID, let buf = drainRingBuffer(from: start, to: endPos) else {
            log.error("stopRecording: drainRingBuffer returned nil (frames=\(endPos - start))")
            return
        }

        // Resampling: fold live-triggered playback (track submix) into the take.
        mixOutputIntoBuffer(buf, outStart: outStart, outEnd: outEndPos)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processRecordedBuffer(buf, trackID: trackID, startStep: startStep)
        }
    }

    private func drainRingBuffer(from startPos: Int, to endPos: Int) -> AVAudioPCMBuffer? {
        guard let fmt = captureFormat else { return nil }
        let count = endPos - startPos
        guard count > Int(fmt.sampleRate * 0.05) else { return nil }   // discard < 50 ms

        let safeCount = min(count, ringCapacity)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                          frameCapacity: AVAudioFrameCount(safeCount)),
              let dst  = buf.floatChannelData?[0]
        else { return nil }
        buf.frameLength = AVAudioFrameCount(safeCount)

        ringBuffer.withUnsafeBufferPointer { rb in
            let ptr  = rb.baseAddress!
            let si   = startPos % ringCapacity
            let wrap = ringCapacity - si
            if safeCount <= wrap {
                memcpy(dst, ptr.advanced(by: si), safeCount * MemoryLayout<Float>.size)
            } else {
                memcpy(dst,                    ptr.advanced(by: si), wrap                  * MemoryLayout<Float>.size)
                memcpy(dst.advanced(by: wrap), ptr,                  (safeCount - wrap)    * MemoryLayout<Float>.size)
            }
        }
        return buf
    }

    // MARK: - Sample processing (in-memory, no file round-trip)

    private func processRecordedBuffer(_ rawBuf: AVAudioPCMBuffer, trackID: UUID, startStep: Int?) {
        let buf = trimEndSilence(rawBuf) ?? rawBuf
        let dur = Double(buf.frameLength) / buf.format.sampleRate
        let node = AVAudioPlayerNode()

        DispatchQueue.main.async { [weak self] in
            guard let self, let idx = self.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            self.pushUndo()

            // Recording replaces the track's sample: swap out the old node entirely
            // (the new buffer's format may differ if the route changed mid-session).
            self.stateLock.lock()
            if let old = self.playerNodes[trackID] {
                old.stop()
                self.audioEngine.detach(old)
            }
            self.stateLock.unlock()

            self.audioEngine.attach(node)
            self.audioEngine.connect(node, to: self.trackMixer, format: buf.format)
            self.startEngineIfNeeded()

            self.stateLock.lock()
            self.playerNodes[trackID] = node
            self.sampleBufs[trackID]  = buf
            self.stateLock.unlock()

            self.tracks[idx].hasSample      = true
            self.tracks[idx].sampleDuration = dur

            if let s = startStep {
                // Recorded live: drop the sample into the grid at the quantized step.
                let bar  = (s / Self.stepCount) % max(1, self.barCount)
                let step = s % Self.stepCount
                if self.tracks[idx].steps.indices.contains(bar) {
                    self.tracks[idx].steps[bar][step] = true
                }
            } else if !self.tracks[idx].hasAnySteps {
                // Recorded while paused into an empty row: drop the default trigger on the
                // downbeat of the bar the user is currently viewing (not always bar 0).
                let bar = min(max(0, self.editingBar), self.barCount - 1)
                self.tracks[idx].steps[bar][0] = true
            }
            self.syncGrid()
        }
    }

    private func trimEndSilence(_ buf: AVAudioPCMBuffer, threshold: Float = 0.003) -> AVAudioPCMBuffer? {
        guard let srcCh = buf.floatChannelData else { return nil }
        let total   = Int(buf.frameLength)
        let postPad = Int(buf.format.sampleRate * 0.06)
        let ch0     = srcCh[0]

        var endFrame = total
        for i in stride(from: total - 1, through: 0, by: -1) {
            if abs(ch0[i]) > threshold { endFrame = min(total, i + postPad); break }
        }
        guard endFrame < total, endFrame > 0 else { return buf }

        let channels = Int(buf.format.channelCount)
        guard let out = AVAudioPCMBuffer(pcmFormat: buf.format,
                                          frameCapacity: AVAudioFrameCount(endFrame)),
              let dstCh = out.floatChannelData else { return buf }
        out.frameLength = AVAudioFrameCount(endFrame)
        for c in 0..<channels {
            memcpy(dstCh[c], srcCh[c], endFrame * MemoryLayout<Float>.size)
        }
        return out
    }
}
