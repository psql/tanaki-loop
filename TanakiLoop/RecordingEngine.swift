import AVFoundation
import Accelerate
import OSLog

private let log = Logger(subsystem: "com.altbizney.jammy", category: "audio")

final class JammyEngine: ObservableObject, @unchecked Sendable {

    // MARK: - Published state

    @Published private(set) var isPlaying:     Bool          = false
    @Published private(set) var isRecording:   Bool          = false
    @Published private(set) var isScrubbing:   Bool          = false
    @Published private(set) var samples:       [Sample]      = []
    @Published private(set) var fftMagnitudes: [Float]       = [Float](repeating: 0, count: 64)
    @Published private(set) var loopDuration:  TimeInterval? = nil
    @Published private(set) var loopPosition:  Double        = 0

    // MARK: - Audio engine

    private let audioEngine  = AVAudioEngine()
    private var playerNodes: [UUID: AVAudioPlayerNode] = [:]
    private var sampleBufs:  [UUID: AVAudioPCMBuffer]  = [:]
    private var inputTapInstalled = false

    // MARK: - Loop clock

    private var positionTimer:  Timer?
    private var loopStartDate:  Date?
    private var pausedPosition: Double = 0

    // MARK: - Ring buffer (always-on mic capture, ~60 s at 48 kHz)

    private let ringCapacity = 48_000 * 60
    private var ringBuffer   = [Float](repeating: 0, count: 48_000 * 60)
    private var ringWritePos: Int = 0      // audio thread writes; Int is word-atomic on arm64
    private var captureStartPos: Int = 0
    private var captureFormat:   AVAudioFormat?

    // MARK: - FFT

    private let fftN         = 1024
    private let fftBinCount  = 64
    private var fftSetup:    FFTSetup?
    private var fftWindow    = [Float](repeating: 0, count: 1024)
    private var fftInput     = [Float](repeating: 0, count: 1024)
    private var fftSmooth    = [Float](repeating: 0, count: 64)
    private var fftNextFire: Date = .distantPast

    // MARK: - Recording

    private var recordingPhase: Double = 0
    private var hasAnyLoop:     Bool   = false

    // MARK: - Scrub

    private var wasPlayingBeforeScrub = false
    private var throwTimer:           Timer?
    private var lastScrubChunkPos:    Double = -1
    private var lastScrubChunkDate:   Date   = .distantPast

    // MARK: - Init

    private var routeObserver:  NSObjectProtocol?
    private var engineObserver: NSObjectProtocol?

    init() {
        setupAudioSession()
        fftSetup = vDSP_create_fftsetup(vDSP_Length(10), FFTRadix(kFFTRadix2))
        vDSP_hann_window(&fftWindow, vDSP_Length(fftN), Int32(vDSP_HANN_DENORM))
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { _ in }
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
        if inputTapInstalled { audioEngine.inputNode.removeTap(onBus: 0) }
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
        // Hint preferred format so inputNode.outputFormat has a valid value even
        // when iOS can't identify the USB device's port type string ("Other").
        try? s.setPreferredSampleRate(48_000)
        try? s.setPreferredInputNumberOfChannels(2)
        try? s.setActive(true)
        log.info("setupAudioSession: external=\(self.externalOutputConnected) sr=\(s.sampleRate) inputs=\(s.inputNumberOfChannels)")
        #endif
    }

    // True when any external audio output (wired, BT, or USB interface) is active.
    private var externalOutputConnected: Bool {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains {
            $0.portType == .headphones    ||
            $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothHFP  ||
            $0.portType == .bluetoothLE   ||
            $0.portType == .usbAudio
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
        setupAudioSession()
        updatePlaybackVolume()
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        // Delay reinstall: USB hardware needs ~100 ms to negotiate a valid format
        // after the route-change notification fires.
        guard audioEngine.isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.installInputTap()
        }
    }

    // AVAudioEngine posts this when hardware configuration changes and stops the engine.
    // Reconnect all player nodes (their graph connections are invalidated) and restart.
    private func handleEngineConfigChange() {
        for (id, node) in playerNodes {
            guard let buf = sampleBufs[id] else { continue }
            audioEngine.attach(node)
            audioEngine.connect(node, to: audioEngine.mainMixerNode, format: buf.format)
        }
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if isPlaying || isRecording { startEngineIfNeeded() }
    }

    // MARK: - Engine lifecycle

    private func startEngineIfNeeded() {
        guard !audioEngine.isRunning else { return }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            installInputTap()
        } catch { print("Engine error: \(error)") }
    }

    private func installInputTap() {
        guard !inputTapInstalled else { return }
        let inputNode = audioEngine.inputNode
        let hwFmt     = inputNode.outputFormat(forBus: 0)

        // iOS 26 may report sampleRate=0/channelCount=0 for USB devices with an
        // unrecognised port type string ("Other"). We must NOT pass a zero-SR
        // format to installTap (crashes). Instead, build a valid format ourselves
        // and let AVAudioEngine convert. Fallback: 48 kHz mono (RODE default).
        let sr: Double            = hwFmt.sampleRate   > 0 ? hwFmt.sampleRate   : 48_000
        let ch: AVAudioChannelCount = hwFmt.channelCount > 0 ? min(hwFmt.channelCount, 2) : 1
        guard let tapFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: ch) else {
            log.error("installInputTap: could not construct format sr=\(sr) ch=\(ch)")
            return
        }
        captureFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)

        log.info("installInputTap: hwFmt sr=\(hwFmt.sampleRate) ch=\(hwFmt.channelCount) → tapFmt sr=\(sr) ch=\(ch)")

        inputNode.installTap(onBus: 0, bufferSize: 512, format: tapFmt) { [weak self] buffer, _ in
            guard let self, let chData = buffer.floatChannelData else { return }
            let n       = Int(buffer.frameLength)
            let cap     = self.ringCapacity
            let chCount = Int(buffer.format.channelCount)
            let ch0     = chData[0]
            let ch1     = chCount > 1 ? chData[1] : nil

            // Update captureFormat from the first real buffer in case the engine
            // negotiated a different sample rate than what hwFmt reported.
            if let cf = self.captureFormat, cf.sampleRate != buffer.format.sampleRate {
                self.captureFormat = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1)
                log.info("captureFormat updated to \(buffer.format.sampleRate) Hz from first buffer")
            }

            for i in 0..<n {
                let s = ch1 != nil ? (ch0[i] + ch1![i]) * 0.5 : ch0[i]
                self.ringBuffer[self.ringWritePos % cap] = s
                self.ringWritePos += 1
            }

            let now = Date()
            guard now > self.fftNextFire else { return }
            self.fftNextFire = now.addingTimeInterval(1.0 / 30.0)
            if let ch1 {
                var mixed = [Float](repeating: 0, count: n)
                mixed.withUnsafeMutableBufferPointer { buf in
                    for i in 0..<n { buf[i] = (ch0[i] + ch1[i]) * 0.5 }
                }
                mixed.withUnsafeBufferPointer { self.computeFFT(samples: $0.baseAddress!, count: n) }
            } else {
                self.computeFFT(samples: ch0, count: n)
            }
        }
        inputTapInstalled = true
        log.info("installInputTap: tap installed ✓")
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

    // MARK: - Playback

    func togglePlayback() {
        guard !isScrubbing else { return }
        if isPlaying { pausePlayback() } else { resumePlayback() }
    }

    private func pausePlayback() {
        guard isPlaying else { return }
        pausedPosition = loopPosition
        positionTimer?.invalidate(); positionTimer = nil
        loopStartDate = nil
        playerNodes.values.forEach { $0.pause() }
        isPlaying = false
    }

    private func resumePlayback() {
        guard !isPlaying, !samples.isEmpty else { return }
        if let dur = loopDuration {
            loopStartDate = Date().addingTimeInterval(-pausedPosition * dur)
        }
        playerNodes.values.forEach { $0.play() }
        isPlaying = true
        startPositionTimer()
    }

    private func beginLoop() {
        if loopStartDate == nil { loopStartDate = Date() }
        guard !isPlaying else { return }
        isPlaying = true
        startPositionTimer()
    }

    private func stopLoop() {
        positionTimer?.invalidate(); positionTimer = nil
        loopStartDate  = nil
        playerNodes.values.forEach { $0.stop() }
        isPlaying      = false
        loopPosition   = 0
        pausedPosition = 0
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let dur = self.loopDuration,
                  let start = self.loopStartDate, dur > 0 else { return }
            self.loopPosition = Date().timeIntervalSince(start)
                .truncatingRemainder(dividingBy: dur) / dur
        }
    }

    // MARK: - Scrub

    func beginScrub() {
        guard !samples.isEmpty, !isRecording else { return }
        wasPlayingBeforeScrub = isPlaying
        isScrubbing           = true
        positionTimer?.invalidate(); positionTimer = nil
        loopStartDate         = nil
        lastScrubChunkPos     = -1
        lastScrubChunkDate    = .distantPast
    }

    func scrubTo(position: Double) {
        var pos = position.truncatingRemainder(dividingBy: 1.0)
        if pos < 0 { pos += 1 }
        loopPosition   = pos
        pausedPosition = pos
        updateScrubChunks(at: pos)
    }

    func endScrub(velocityLoopsPerSec: Double) {
        throwTimer?.invalidate()
        if abs(velocityLoopsPerSec) > 0.05 {
            var vel = velocityLoopsPerSec
            throwTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                vel *= 0.96
                if abs(vel) < 0.003 { timer.invalidate(); self.finishScrub(); return }
                var p = self.loopPosition + vel / 60
                p = p.truncatingRemainder(dividingBy: 1.0)
                if p < 0 { p += 1 }
                self.loopPosition   = p
                self.pausedPosition = p
                self.updateScrubChunks(at: p)
            }
        } else {
            finishScrub()
        }
    }

    private func finishScrub() {
        isScrubbing       = false
        throwTimer?.invalidate(); throwTimer = nil
        lastScrubChunkPos = -1
        let pos           = pausedPosition

        for sample in samples {
            guard let node = playerNodes[sample.id],
                  let buf  = sampleBufs[sample.id] else { continue }
            node.stop()
            let distance    = (pos - sample.phaseOffset + 1.0).truncatingRemainder(dividingBy: 1.0)
            let frameOffset = AVAudioFrameCount(distance * Double(buf.frameLength))
            let tailFrames  = buf.frameLength > frameOffset ? buf.frameLength - frameOffset : 0
            scheduleFromOffset(node: node, buf: buf, frameOffset: frameOffset, tailFrames: tailFrames)
            if wasPlayingBeforeScrub { node.play() }
        }

        if wasPlayingBeforeScrub, let dur = loopDuration {
            loopStartDate = Date().addingTimeInterval(-pos * dur)
            isPlaying     = true
            startPositionTimer()
        }
    }

    private func updateScrubChunks(at pos: Double) {
        let now = Date()
        guard abs(pos - lastScrubChunkPos) > 0.008 ||
              now.timeIntervalSince(lastScrubChunkDate) > 0.07 else { return }
        lastScrubChunkPos  = pos
        lastScrubChunkDate = now
        let chunkSecs: Double = 0.07
        for sample in samples {
            guard let node = playerNodes[sample.id],
                  let buf  = sampleBufs[sample.id] else { continue }
            let dist   = (pos - sample.phaseOffset + 1.0).truncatingRemainder(dividingBy: 1.0)
            let start  = AVAudioFrameCount(dist * Double(buf.frameLength))
            let cap    = AVAudioFrameCount(chunkSecs * buf.format.sampleRate)
            let avail  = buf.frameLength > start ? buf.frameLength - start : 0
            let frames = min(cap, avail)
            guard frames > 100,
                  let chunk = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: frames),
                  let src = buf.floatChannelData, let dst = chunk.floatChannelData else { continue }
            chunk.frameLength = frames
            for c in 0..<Int(buf.format.channelCount) {
                memcpy(dst[c], src[c].advanced(by: Int(start)),
                       Int(frames) * MemoryLayout<Float>.size)
            }
            node.stop()
            node.scheduleBuffer(chunk, at: nil, options: .loops, completionHandler: nil)
            node.play()
        }
    }

    // MARK: - Loop length scaling

    func doubleLoopLength() {
        guard let dur = loopDuration, !samples.isEmpty, !isRecording, !isScrubbing else { return }
        let newDur     = dur * 2
        let rawElapsed = currentRawElapsed(within: dur)
        let wasPlaying = isPlaying
        playerNodes.values.forEach { $0.stop() }
        isPlaying = false
        positionTimer?.invalidate(); positionTimer = nil

        for i in 0..<samples.count {
            let id = samples[i].id
            guard let buf = sampleBufs[id], let node = playerNodes[id] else { continue }
            let nFrames = buf.frameLength * 2
            guard let newBuf = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: nFrames),
                  let src = buf.floatChannelData, let dst = newBuf.floatChannelData else { continue }
            newBuf.frameLength = nFrames
            let ch         = Int(buf.format.channelCount)
            let frameBytes = Int(buf.frameLength) * MemoryLayout<Float>.size
            for c in 0..<ch {
                memcpy(dst[c], src[c], frameBytes)
                memcpy(dst[c].advanced(by: Int(buf.frameLength)), src[c], frameBytes)
            }
            sampleBufs[id]         = newBuf
            let newPhase           = samples[i].phaseOffset / 2.0
            samples[i].phaseOffset = newPhase
            samples[i].duration    = newDur
            let distance   = (rawElapsed / newDur - newPhase + 1.0).truncatingRemainder(dividingBy: 1.0)
            let frameOff   = AVAudioFrameCount(distance * Double(nFrames))
            let tailFrames = nFrames > frameOff ? nFrames - frameOff : 0
            scheduleFromOffset(node: node, buf: newBuf, frameOffset: frameOff, tailFrames: tailFrames)
        }

        loopDuration   = newDur
        loopStartDate  = Date().addingTimeInterval(-rawElapsed)
        pausedPosition = rawElapsed / newDur
        if wasPlaying {
            playerNodes.values.forEach { $0.play() }
            isPlaying = true
            startPositionTimer()
        }
    }

    func halveLoopLength() {
        guard let dur = loopDuration, dur > 0.4, !samples.isEmpty, !isRecording, !isScrubbing else { return }
        let newDur     = dur / 2
        let rawElapsed = currentRawElapsed(within: newDur)
        let wasPlaying = isPlaying
        playerNodes.values.forEach { $0.stop() }
        isPlaying = false
        positionTimer?.invalidate(); positionTimer = nil

        for i in 0..<samples.count {
            let id = samples[i].id
            guard let buf = sampleBufs[id], let node = playerNodes[id] else { continue }
            buf.frameLength    = buf.frameLength / 2
            let nFrames        = buf.frameLength
            let newPhase       = (samples[i].phaseOffset * 2.0).truncatingRemainder(dividingBy: 1.0)
            samples[i].phaseOffset = newPhase
            samples[i].duration    = newDur
            let distance   = (rawElapsed / newDur - newPhase + 1.0).truncatingRemainder(dividingBy: 1.0)
            let frameOff   = AVAudioFrameCount(distance * Double(nFrames))
            let tailFrames = nFrames > frameOff ? nFrames - frameOff : 0
            scheduleFromOffset(node: node, buf: buf, frameOffset: frameOff, tailFrames: tailFrames)
        }

        loopDuration   = newDur
        loopStartDate  = Date().addingTimeInterval(-rawElapsed)
        pausedPosition = rawElapsed / newDur
        if wasPlaying {
            playerNodes.values.forEach { $0.play() }
            isPlaying = true
            startPositionTimer()
        }
    }

    private func currentRawElapsed(within period: TimeInterval) -> TimeInterval {
        if let start = loopStartDate {
            return Date().timeIntervalSince(start).truncatingRemainder(dividingBy: period)
        }
        return (pausedPosition * (loopDuration ?? period)).truncatingRemainder(dividingBy: period)
    }

    private func scheduleFromOffset(node: AVAudioPlayerNode, buf: AVAudioPCMBuffer,
                                    frameOffset: AVAudioFrameCount, tailFrames: AVAudioFrameCount) {
        guard tailFrames > 0, frameOffset > 0,
              let tailBuf = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: tailFrames),
              let srcCh   = buf.floatChannelData,
              let dstCh   = tailBuf.floatChannelData
        else {
            node.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
            return
        }
        tailBuf.frameLength = tailFrames
        let ch = Int(buf.format.channelCount)
        for c in 0..<ch {
            memcpy(dstCh[c], srcCh[c].advanced(by: Int(frameOffset)),
                   Int(tailFrames) * MemoryLayout<Float>.size)
        }
        node.scheduleBuffer(tailBuf, at: nil, completionHandler: nil)
        node.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
    }

    // MARK: - Undo / Clear

    func undo() {
        guard !samples.isEmpty else { return }
        let removed = samples.removeLast()
        if let node = playerNodes[removed.id] { node.stop(); audioEngine.detach(node) }
        playerNodes.removeValue(forKey: removed.id)
        sampleBufs.removeValue(forKey: removed.id)
        try? FileManager.default.removeItem(at: removed.url)
        if samples.isEmpty { loopDuration = nil; hasAnyLoop = false; stopLoop() }
    }

    func clearAll() {
        throwTimer?.invalidate(); throwTimer = nil
        isScrubbing  = false
        stopLoop()
        loopDuration = nil
        hasAnyLoop   = false
        for node in playerNodes.values { node.stop(); audioEngine.detach(node) }
        playerNodes.removeAll(); sampleBufs.removeAll()
        samples.forEach { try? FileManager.default.removeItem(at: $0.url) }
        samples.removeAll()
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording, !isScrubbing else { return }
        #if os(iOS)
        let perm = AVAudioSession.sharedInstance().recordPermission
        if perm == .undetermined {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.startRecording() } }
            }
            return
        }
        guard perm == .granted else { return }
        #endif

        if !isPlaying && !samples.isEmpty { resumePlayback() }
        startEngineIfNeeded()
        captureStartPos = ringWritePos    // mark start position after engine is up
        recordingPhase  = loopPosition
        isRecording     = true
        updatePlaybackVolume()
        log.info("startRecording: tapInstalled=\(self.inputTapInstalled) captureStart=\(self.captureStartPos) ringWrite=\(self.ringWritePos)")
    }

    func stopRecording() {
        guard isRecording else { return }
        let endPos = ringWritePos         // snapshot before any further audio arrives
        isRecording = false
        updatePlaybackVolume()

        let isFirst       = !hasAnyLoop
        if isFirst { hasAnyLoop = true }
        let capturedPhase = isFirst ? 0.0 : recordingPhase
        let start         = captureStartPos
        log.info("stopRecording: frames=\(endPos - start) tapInstalled=\(self.inputTapInstalled) captureFmt sr=\(self.captureFormat?.sampleRate ?? 0)")

        guard let buf = drainRingBuffer(from: start, to: endPos) else {
            log.error("stopRecording: drainRingBuffer returned nil (frames=\(endPos - start), captureFormat=\(String(describing: self.captureFormat)))")
            if isFirst { hasAnyLoop = false }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processSampleBuffer(buf, capturedPhase: capturedPhase, isFirst: isFirst)
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

    // MARK: - Sample processing (in-memory, no file read)

    private func processSampleBuffer(_ rawBuf: AVAudioPCMBuffer, capturedPhase: Double, isFirst: Bool) {
        let buf    = trimEndSilence(rawBuf) ?? rawBuf
        let rawDur = Double(buf.frameLength) / buf.format.sampleRate

        // Write CAF for cleanup reference (undo/clear); not on the critical path
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("s-\(UUID().uuidString.prefix(8)).caf")
        if let f = try? AVAudioFile(forWriting: url, settings: buf.format.settings) {
            try? f.write(from: buf)
        }

        var finalBuf = buf
        var finalDur = rawDur

        if !isFirst, let current = loopDuration {
            let targetFrames = AVAudioFrameCount(current * buf.format.sampleRate)
            if targetFrames <= buf.frameLength {
                buf.frameLength = targetFrames
                finalDur = current
            } else {
                finalBuf = padBuffer(buf, toDuration: current) ?? buf
                finalDur = current
            }
        }

        let sample = Sample(url: url, duration: finalDur, naturalDuration: rawDur, phaseOffset: capturedPhase)
        let node   = AVAudioPlayerNode()
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: finalBuf.format)
        startEngineIfNeeded()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isFirst {
                self.loopDuration   = finalDur
                self.loopStartDate  = Date()
                self.pausedPosition = 0
            }

            self.playerNodes[sample.id] = node
            self.sampleBufs[sample.id]  = finalBuf
            self.samples.append(sample)

            let currentPos: Double
            if let start = self.loopStartDate, let dur = self.loopDuration, dur > 0 {
                currentPos = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: dur) / dur
            } else {
                currentPos = self.pausedPosition
            }

            let distance    = (currentPos - capturedPhase + 1.0).truncatingRemainder(dividingBy: 1.0)
            let totalFrames = finalBuf.frameLength
            let frameOffset = AVAudioFrameCount(distance * Double(totalFrames))
            let tailFrames  = totalFrames > frameOffset ? totalFrames - frameOffset : 0

            self.scheduleFromOffset(node: node, buf: finalBuf,
                                    frameOffset: frameOffset, tailFrames: tailFrames)
            node.play()
            self.beginLoop()
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

    private func padBuffer(_ buf: AVAudioPCMBuffer, toDuration dur: TimeInterval) -> AVAudioPCMBuffer? {
        let targetFrames = AVAudioFrameCount(dur * buf.format.sampleRate)
        guard targetFrames > buf.frameLength,
              let padded = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: targetFrames),
              let src    = buf.floatChannelData,
              let dst    = padded.floatChannelData
        else { return buf }
        padded.frameLength = targetFrames
        let channels  = Int(buf.format.channelCount)
        let srcFrames = Int(buf.frameLength)
        let dstFrames = Int(targetFrames)
        for c in 0..<channels {
            memcpy(dst[c], src[c], srcFrames * MemoryLayout<Float>.size)
            memset(dst[c].advanced(by: srcFrames), 0,
                   (dstFrames - srcFrames) * MemoryLayout<Float>.size)
        }
        return padded
    }
}
