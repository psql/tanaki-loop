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
    private let timerQueue = DispatchQueue(label: "com.tanakiloop.metronome", qos: .userInteractive)
    private var metronomeTimer: DispatchSourceTimer?
    private var beatCount: Int = 0

    init() {
        setupAudio()
    }

    private func setupAudio() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // playAndRecord + mixWithOthers lets the metronome keep playing while recording
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
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
        // Just update the value — the running timer reads bpm fresh each beat,
        // so the new tempo takes effect at the next natural beat with no restart.
        bpm = max(40, min(240, newBPM))
    }

    private func startEngine() {
        isPlaying = true
        beatCount = 0
        fireBeatAndReschedule()
    }

    private func stopEngine() {
        metronomeTimer?.cancel()
        metronomeTimer = nil
        isPlaying = false
        currentBeat = -1
    }

    private func fireBeatAndReschedule() {
        guard isPlaying else { return }

        // Play the click for this beat
        let beat = beatCount % 4
        let buffer = beat == 0 ? accentBuffer : tickBuffer
        if let buffer { playerNode.scheduleBuffer(buffer, completionHandler: nil) }

        let capturedBeat = beat
        DispatchQueue.main.async { [weak self] in self?.currentBeat = capturedBeat }
        beatCount += 1

        // Schedule next beat using bpm as it stands right now
        let intervalNs = Int(60_000_000_000.0 / bpm)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now() + .nanoseconds(intervalNs), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in self?.fireBeatAndReschedule() }
        timer.resume()
        metronomeTimer = timer
    }
}
