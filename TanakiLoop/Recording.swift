import AVFoundation

struct Sample: Identifiable, Equatable {
    let id:              UUID = UUID()
    let url:             URL
    var duration:        TimeInterval   // padded buffer duration (= loopDuration)
    var naturalDuration: TimeInterval   // actual recorded audio length before padding
    var phaseOffset:     Double         // 0–1: where in the loop this sample was born

    // MARK: - Silence trim (synchronous, writes CAF)

    static func trimSilence(inputURL: URL, threshold: Float = 0.006) -> URL? {
        guard let file = try? AVAudioFile(forReading: inputURL),
              let fmt  = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: file.fileFormat.sampleRate,
                                       channels: file.fileFormat.channelCount,
                                       interleaved: false),
              let buf  = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let ch0  = buf.floatChannelData?[0]
        else { return nil }

        let sr    = file.fileFormat.sampleRate
        let total = Int(buf.frameLength)
        let pre   = max(0, Int(sr * 0.005))
        let post  = Int(sr * 0.06)

        var startFrame = total
        for i in 0..<total {
            if abs(ch0[i]) > threshold { startFrame = max(0, i - pre); break }
        }
        var endFrame = 0
        for i in stride(from: total - 1, through: 0, by: -1) {
            if abs(ch0[i]) > threshold { endFrame = min(total, i + post); break }
        }
        guard endFrame > startFrame else { return nil }

        let trimLen = endFrame - startFrame
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sr,
                                          channels: file.fileFormat.channelCount,
                                          interleaved: false),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt,
                                             frameCapacity: AVAudioFrameCount(trimLen))
        else { return nil }
        outBuf.frameLength = AVAudioFrameCount(trimLen)

        if let srcCh = buf.floatChannelData, let dstCh = outBuf.floatChannelData {
            for c in 0..<Int(file.fileFormat.channelCount) {
                memcpy(dstCh[c], srcCh[c].advanced(by: startFrame),
                       trimLen * MemoryLayout<Float>.size)
            }
        }

        let outURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("s-\(UUID().uuidString.prefix(8)).caf")
        guard let outFile = try? AVAudioFile(forWriting: outURL, settings: outFmt.settings) else { return nil }
        try? outFile.write(from: outBuf)
        try? FileManager.default.removeItem(at: inputURL)
        return outURL
    }

    // MARK: - Load decoded PCM buffer

    static func loadBuffer(url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let fmt  = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: file.fileFormat.sampleRate,
                                       channels: file.fileFormat.channelCount,
                                       interleaved: false),
              let buf  = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil
        else { return nil }
        return buf
    }
}
