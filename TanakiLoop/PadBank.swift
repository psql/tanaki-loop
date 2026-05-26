import AVFoundation

final class PadBank: ObservableObject, @unchecked Sendable {

    struct Pad: Identifiable {
        let id: UUID
        var url: URL?         = nil
        var duration: Double  = 0
        var status: Status    = .empty
        var waveform: [Float] = Array(repeating: 0, count: 36)

        enum Status: Equatable { case empty, recording, filled, playing }
        var hasContent: Bool { url != nil }
    }

    @Published var pads: [Pad] = (0..<3).map { _ in Pad(id: UUID()) }

    private var recorders:   [UUID: AVAudioRecorder] = [:]
    private var recStarts:   [UUID: Date]            = [:]
    private var players:     [UUID: AVAudioPlayer]   = [:]
    private var meterTimers: [UUID: Timer]           = [:]

    // MARK: - Record

    func startRecording(id: UUID) {
        guard let idx = index(id), pads[idx].status != .recording else { return }
        stopPlaying(id: id)

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("pad-\(Int(Date().timeIntervalSince1970))-\(id.uuidString.prefix(4)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          44100,
            AVNumberOfChannelsKey:    1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        rec.isMeteringEnabled = true
        rec.record()
        recorders[id] = rec
        recStarts[id] = Date()
        pads[idx].status = .recording

        meterTimers[id] = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let rec = self.recorders[id], rec.isRecording else { return }
            rec.updateMeters()
            let v = Float(max(0, min(1, (Double(rec.averagePower(forChannel: 0)) + 60) / 60)))
            if let i = self.index(id) {
                var wf = self.pads[i].waveform; wf.removeFirst(); wf.append(v)
                self.pads[i].waveform = wf
            }
        }
    }

    func stopRecording(id: UUID) {
        guard let idx = index(id), pads[idx].status == .recording,
              let rec = recorders[id] else { return }
        meterTimers[id]?.invalidate(); meterTimers.removeValue(forKey: id)
        let url   = rec.url
        let start = recStarts.removeValue(forKey: id) ?? Date()
        rec.stop(); recorders.removeValue(forKey: id)

        let dur = Date().timeIntervalSince(start)
        guard dur > 0.05 else {
            try? FileManager.default.removeItem(at: url)
            pads[idx].status = .empty; return
        }
        if let old = pads[idx].url { try? FileManager.default.removeItem(at: old) }
        pads[idx].url      = url
        pads[idx].duration = dur
        pads[idx].status   = .filled
        pads[idx].waveform = Array(repeating: 0, count: 36)
    }

    // MARK: - Play (interruptible — each call restarts from beginning)

    func play(id: UUID) {
        guard let idx = index(id), let url = pads[idx].url else { return }
        players[id]?.stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.play()
        players[id]     = player
        pads[idx].status = .playing

        let dur = pads[idx].duration
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.05) { [weak self] in
            guard let self, let i = self.index(id) else { return }
            if self.players[id] === player, !player.isPlaying {
                self.players.removeValue(forKey: id)
                self.pads[i].status = .filled
            }
        }
    }

    func stopPlaying(id: UUID) {
        guard let idx = index(id), pads[idx].status == .playing else { return }
        players[id]?.stop(); players.removeValue(forKey: id)
        pads[idx].status = .filled
    }

    // MARK: - Clear (throw away)

    func clearPad(id: UUID) {
        guard let idx = index(id) else { return }
        meterTimers[id]?.invalidate(); meterTimers.removeValue(forKey: id)
        recorders[id]?.stop(); recorders.removeValue(forKey: id)
        players[id]?.stop(); players.removeValue(forKey: id)
        if let url = pads[idx].url { try? FileManager.default.removeItem(at: url) }
        pads[idx] = Pad(id: id)
    }

    private func index(_ id: UUID) -> Int? { pads.firstIndex { $0.id == id } }
}
