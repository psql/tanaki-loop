import AVFoundation

final class JammyEngine: ObservableObject, @unchecked Sendable {

    // MARK: - Published state

    @Published private(set) var isPlaying:       Bool          = false
    @Published private(set) var isRecording:     Bool          = false
    @Published private(set) var isScrubbing:     Bool          = false
    @Published private(set) var samples:         [Sample]      = []
    @Published private(set) var waveformSamples: [Float]       = Array(repeating: 0, count: 60)
    @Published private(set) var loopDuration:    TimeInterval? = nil
    @Published private(set) var loopPosition:    Double        = 0   // 0–1

    // MARK: - Audio engine

    private let audioEngine       = AVAudioEngine()
    private var playerNodes:       [UUID: AVAudioPlayerNode] = [:]
    private var sampleBufs:        [UUID: AVAudioPCMBuffer]  = [:]
    private var mixerTapInstalled  = false
    private var lastTapUpdate:     Date = .distantPast

    // MARK: - Loop clock

    private var positionTimer:  Timer?
    private var loopStartDate:  Date?
    private var pausedPosition: Double = 0

    // MARK: - Recording

    private var audioRecorder:   AVAudioRecorder?
    private var meterTimer:      Timer?
    private var recordingURL:    URL?
    private var recordingStart:  Date?
    private var recordingPhase:  Double = 0
    private var hasAnyLoop:      Bool   = false   // main-thread flag; set before background dispatch

    // MARK: - Scrub

    private var wasPlayingBeforeScrub  = false
    private var throwTimer:            Timer?
    private var lastScrubChunkPos:     Double = -1
    private var lastScrubChunkDate:    Date   = .distantPast

    // MARK: - Init

    private var routeObserver: NSObjectProtocol?

    init() {
        setupAudioSession()
        prewarmRecorder()
        #if os(iOS)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in self?.updatePlaybackVolume() }
        #endif
    }

    deinit {
        if mixerTapInstalled { audioEngine.mainMixerNode.removeTap(onBus: 0) }
        if let obs = routeObserver { NotificationCenter.default.removeObserver(obs) }
    }

    private func prewarmRecorder() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prewarm.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          44100,
            AVNumberOfChannelsKey:    1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try? AVAudioRecorder(url: url, settings: settings)
        rec?.prepareToRecord()
        try? FileManager.default.removeItem(at: url)
    }

    private func setupAudioSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default,
                           options: [.defaultToSpeaker, .mixWithOthers])
        try? s.setActive(true)
        #endif
    }

    // MARK: - Headphone-aware volume ducking

    private var headphonesConnected: Bool {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains {
            $0.portType == .headphones    ||
            $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothHFP  ||
            $0.portType == .bluetoothLE
        }
        #else
        return true
        #endif
    }

    private func updatePlaybackVolume() {
        let vol: Float = (isRecording && !headphonesConnected) ? 0.25 : 1.0
        audioEngine.mainMixerNode.outputVolume = vol
    }

    private func startEngineIfNeeded() {
        guard !audioEngine.isRunning else { return }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            installMixerTap()
        } catch { print("Engine error: \(error)") }
    }

    private func installMixerTap() {
        guard !mixerTapInstalled else { return }
        let mixer = audioEngine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            guard let self, !self.isRecording else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastTapUpdate) > 1 / 30 else { return }
            self.lastTapUpdate = now
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(n))
            let v   = Float(min(1.0, Double(rms) * 18))
            var next = self.waveformSamples
            next.removeFirst(); next.append(v)
            DispatchQueue.main.async { self.waveformSamples = next }
        }
        mixerTapInstalled = true
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
            guard let self, let dur = self.loopDuration, let start = self.loopStartDate, dur > 0 else { return }
            self.loopPosition = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: dur) / dur
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
        isScrubbing        = false
        throwTimer?.invalidate(); throwTimer = nil
        lastScrubChunkPos  = -1
        let pos            = pausedPosition

        for sample in samples {
            guard let node = playerNodes[sample.id],
                  let buf  = sampleBufs[sample.id] else { continue }
            node.stop()
            let distance   = (pos - sample.phaseOffset + 1.0).truncatingRemainder(dividingBy: 1.0)
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
            let dist  = (pos - sample.phaseOffset + 1.0).truncatingRemainder(dividingBy: 1.0)
            let start = AVAudioFrameCount(dist * Double(buf.frameLength))
            let cap   = AVAudioFrameCount(chunkSecs * buf.format.sampleRate)
            let avail = buf.frameLength > start ? buf.frameLength - start : 0
            let frames = min(cap, avail)
            guard frames > 100,
                  let chunk = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: frames),
                  let src = buf.floatChannelData, let dst = chunk.floatChannelData else { continue }
            chunk.frameLength = frames
            let ch = Int(buf.format.channelCount)
            for c in 0..<ch {
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
            let ch = Int(buf.format.channelCount)
            let frameBytes = Int(buf.frameLength) * MemoryLayout<Float>.size
            for c in 0..<ch {
                memcpy(dst[c], src[c], frameBytes)
                memcpy(dst[c].advanced(by: Int(buf.frameLength)), src[c], frameBytes)
            }
            sampleBufs[id] = newBuf
            let newPhase = samples[i].phaseOffset / 2.0
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
            buf.frameLength = buf.frameLength / 2
            let nFrames     = buf.frameLength
            let newPhase    = (samples[i].phaseOffset * 2.0).truncatingRemainder(dividingBy: 1.0)
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

    // MARK: - Undo

    func undo() {
        guard !samples.isEmpty else { return }
        let removed = samples.removeLast()
        if let node = playerNodes[removed.id] { node.stop(); audioEngine.detach(node) }
        playerNodes.removeValue(forKey: removed.id)
        sampleBufs.removeValue(forKey: removed.id)
        try? FileManager.default.removeItem(at: removed.url)
        if samples.isEmpty { loopDuration = nil; hasAnyLoop = false; stopLoop() }
    }

    // MARK: - Clear

    func clearAll() {
        throwTimer?.invalidate(); throwTimer = nil
        isScrubbing   = false
        stopLoop()
        loopDuration  = nil
        hasAnyLoop    = false
        for node in playerNodes.values { node.stop(); audioEngine.detach(node) }
        playerNodes.removeAll(); sampleBufs.removeAll()
        samples.forEach { try? FileManager.default.removeItem(at: $0.url) }
        samples.removeAll()
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording, !isScrubbing else { return }
        AVAudioApplication.requestRecordPermission { _ in
            DispatchQueue.main.async { self.beginCapture() }
        }
    }

    private func beginCapture() {
        if !isPlaying && !samples.isEmpty { resumePlayback() }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("raw-\(Int(Date().timeIntervalSince1970)).m4a")
        recordingURL = url
        let settings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          44100,
            AVNumberOfChannelsKey:    1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        rec.isMeteringEnabled = true
        rec.record()
        audioRecorder  = rec
        recordingStart = Date()
        recordingPhase = loopPosition
        isRecording    = true
        updatePlaybackVolume()
        startMeterTimer()
    }

    func stopRecording() {
        guard isRecording else { return }
        meterTimer?.invalidate(); meterTimer = nil
        audioRecorder?.stop(); audioRecorder = nil
        isRecording = false
        updatePlaybackVolume()
        waveformSamples = Array(repeating: 0, count: 60)

        guard let url = recordingURL, let start = recordingStart else { return }
        recordingURL = nil; recordingStart = nil
        guard Date().timeIntervalSince(start) > 0.05 else {
            try? FileManager.default.removeItem(at: url); return
        }

        // Determine isFirst on the main thread before background dispatch
        let isFirst       = !hasAnyLoop
        if isFirst { hasAnyLoop = true }
        let capturedPhase = isFirst ? 0.0 : recordingPhase

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processSample(rawURL: url, capturedPhase: capturedPhase, isFirst: isFirst)
        }
    }

    // MARK: - Buffer helpers

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
            memset(dst[c].advanced(by: srcFrames), 0, (dstFrames - srcFrames) * MemoryLayout<Float>.size)
        }
        return padded
    }

    // MARK: - Sample processing

    private func processSample(rawURL: URL, capturedPhase: Double, isFirst: Bool) {
        let url    = Sample.trimSilence(inputURL: rawURL) ?? rawURL
        guard let buf = Sample.loadBuffer(url: url) else { return }
        let rawDur = Double(buf.frameLength) / buf.format.sampleRate
        let phaseOffset = capturedPhase

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

        let sample = Sample(url: url, duration: finalDur, naturalDuration: rawDur, phaseOffset: phaseOffset)
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

            // Compute where in the sample's content the loop is right now
            let currentPos: Double
            if let start = self.loopStartDate, let dur = self.loopDuration, dur > 0 {
                currentPos = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: dur) / dur
            } else {
                currentPos = self.pausedPosition
            }

            let distance    = (currentPos - phaseOffset + 1.0).truncatingRemainder(dividingBy: 1.0)
            let totalFrames = finalBuf.frameLength
            let frameOffset = AVAudioFrameCount(distance * Double(totalFrames))
            let tailFrames  = totalFrames > frameOffset ? totalFrames - frameOffset : 0

            self.scheduleFromOffset(node: node, buf: finalBuf,
                                    frameOffset: frameOffset, tailFrames: tailFrames)
            node.play()
            self.beginLoop()
        }
    }

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let rec = self.audioRecorder, rec.isRecording else { return }
            rec.updateMeters()
            let v = Float(max(0, min(1, (Double(rec.averagePower(forChannel: 0)) + 60) / 60)))
            var next = self.waveformSamples; next.removeFirst(); next.append(v)
            DispatchQueue.main.async { self.waveformSamples = next }
        }
    }
}
