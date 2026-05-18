import AVFoundation
import Combine

final class MetronomeEngine: ObservableObject, @unchecked Sendable {
    @Published private(set) var bpm: Double = 120
    @Published private(set) var currentBeat: Int = -1
    @Published private(set) var isPlaying: Bool = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var accentBuffer: AVAudioPCMBuffer?
    private var tickBuffer: AVAudioPCMBuffer?
    private let timerQueue = DispatchQueue(label: "com.catar.metronome", qos: .userInteractive)
    private var metronomeTimer: DispatchSourceTimer?
    private var beatCount: Int = 0

    init() {
        setupAudio()
    }

    private func setupAudio() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        #endif

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: nil)

        let sampleRate = audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let rate = sampleRate > 0 ? sampleRate : 44100.0

        accentBuffer = synthesizeClick(sampleRate: rate, frequency: 1800, duration: 0.07, amplitude: 0.85)
        tickBuffer = synthesizeClick(sampleRate: rate, frequency: 1000, duration: 0.055, amplitude: 0.65)

        do {
            try audioEngine.start()
            playerNode.play()
        } catch {
            print("Audio engine failed: \(error)")
        }
    }

    private func synthesizeClick(sampleRate: Double, frequency: Double, duration: Double, amplitude: Float) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        for ch in 0..<2 {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                data[i] = Float(sin(2 * .pi * frequency * t) * exp(-t * 40.0) * Double(amplitude))
            }
        }
        return buffer
    }

    func toggle() {
        if isPlaying { stopEngine() } else { startEngine() }
    }

    func setBPM(_ newBPM: Double) {
        let clamped = max(40, min(240, newBPM))
        bpm = clamped
        if isPlaying {
            stopEngine()
            startEngine()
        }
    }

    private func startEngine() {
        isPlaying = true
        beatCount = 0
        scheduleTimer()
    }

    private func stopEngine() {
        metronomeTimer?.cancel()
        metronomeTimer = nil
        isPlaying = false
        currentBeat = -1
    }

    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        let intervalNs = Int(60_000_000_000.0 / bpm)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(intervalNs), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let beat = self.beatCount % 4
            let buffer = beat == 0 ? self.accentBuffer : self.tickBuffer
            if let buffer {
                self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
            }
            let capturedBeat = beat
            DispatchQueue.main.async { [weak self] in
                self?.currentBeat = capturedBeat
            }
            self.beatCount += 1
        }
        timer.resume()
        metronomeTimer = timer
    }
}
