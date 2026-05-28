import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Palette

private let trackColors: [Color] = [
    Color(red: 0.97, green: 0.35, blue: 0.30),
    Color(red: 0.27, green: 0.72, blue: 0.98),
    Color(red: 0.99, green: 0.84, blue: 0.22),
    Color(red: 0.75, green: 0.52, blue: 0.98),
    Color(red: 0.28, green: 0.90, blue: 0.60),
    Color(red: 0.99, green: 0.63, blue: 0.42),
]

// MARK: - Ring geometry

private let recordDiam:  CGFloat = 180
private let ringInset:   CGFloat = 22
private let ringWidth:   CGFloat = 8
private let ringSpacing: CGFloat = 7

private func ringCenterRadius(_ i: Int) -> CGFloat {
    recordDiam / 2 + ringInset + ringWidth / 2 + CGFloat(i) * (ringWidth + ringSpacing)
}

private func outerRingRadius(n: Int) -> CGFloat {
    guard n > 0 else { return recordDiam / 2 + ringInset }
    return recordDiam / 2 + ringInset + CGFloat(n) * ringWidth + CGFloat(n - 1) * ringSpacing
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var engine       = JammyEngine()
    @State       private var btnPressed   = false
    @State       private var pressStart   = Date()
    @State       private var isLatchedRec = false
    @State       private var pinchScale:  CGFloat = 1.0
    @State       private var pinchFired   = false

    // Scrub gesture state
    @State private var lastDragAngle:       Double? = nil
    @State private var lastDragTime:        Date    = .now
    @State private var dragAngularVelocity: Double  = 0

    var body: some View {
        ZStack {
            Color(red: 0.09, green: 0.09, blue: 0.12).ignoresSafeArea()

            // Recording color overlay
            if engine.isRecording {
                recordingColor
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // Always-on spectrogram (behind rings)
            SpectrogramView(bins: engine.fftMagnitudes, isRecording: engine.isRecording)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Centered record + rings
            radialCenter

            // Bottom bar
            VStack {
                Spacer()
                bottomBar.padding(.bottom, 52)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: engine.isRecording)
        .onChange(of: engine.isRecording) { _, recording in
            if !recording { isLatchedRec = false }
        }
    }

    // MARK: - Computed colors

    private var recordingColor: Color {
        trackColors[engine.samples.count % trackColors.count]
    }

    // MARK: - Radial center

    private var radialCenter: some View {
        let n         = engine.samples.count
        let outR      = outerRingRadius(n: n)
        let frameSize = outR * 2 + 40

        return ZStack {
            // Rings layer with pinch gesture
            ZStack {
                ForEach(Array(engine.samples.enumerated()), id: \.element.id) { i, sample in
                    let color           = trackColors[i % trackColors.count]
                    let phase           = sample.phaseOffset
                    let loopDur         = engine.loopDuration ?? 1
                    let naturalFraction = CGFloat(min(sample.naturalDuration / loopDur, 1.0))
                    let progressSince   = (engine.loopPosition - phase + 1.0)
                        .truncatingRemainder(dividingBy: 1.0)
                    let wormLength      = CGFloat(min(progressSince, Double(naturalFraction)))
                    let radius          = ringCenterRadius(i) * 2

                    Circle()
                        .trim(from: 0, to: max(0.001, naturalFraction))
                        .stroke(color.opacity(0.18), lineWidth: ringWidth)
                        .frame(width: radius, height: radius)
                        .rotationEffect(.degrees(phase * 360 - 90))

                    Circle()
                        .trim(from: 0, to: max(0.001, wormLength))
                        .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                        .frame(width: radius, height: radius)
                        .rotationEffect(.degrees(phase * 360 - 90))
                }
            }
            .scaleEffect(ringsElasticScale)
            .gesture(pinchGesture)

            // Clock hand with scrub gesture
            if n > 0 {
                clockHand(outerRadius: outR + 14, frameSize: frameSize)
            }

            // Record button
            recordButton
        }
        .coordinateSpace(name: "radial")
        .frame(width: frameSize, height: frameSize)
    }

    // MARK: - Clock hand

    private func clockHand(outerRadius: CGFloat, frameSize: CGFloat) -> some View {
        let innerRadius: CGFloat = recordDiam / 2 + 8
        let angleDeg             = engine.loopPosition * 360

        return ZStack {
            // Dashed stem (non-interactive)
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                var p  = Path()
                p.move(to:    CGPoint(x: cx, y: cy - innerRadius))
                p.addLine(to: CGPoint(x: cx, y: cy - outerRadius))
                ctx.stroke(p, with: .color(.white.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5]))
            }
            .frame(width: frameSize, height: frameSize)
            .allowsHitTesting(false)

            // Grab knob
            Circle()
                .fill(Color.white.opacity(engine.isScrubbing ? 1.0 : 0.80))
                .frame(width: 12, height: 12)
                .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                .scaleEffect(engine.isScrubbing ? 1.6 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.55), value: engine.isScrubbing)
                .contentShape(Circle().scale(3.5))
                .offset(y: -outerRadius)
                .gesture(scrubGesture(frameSize: frameSize))
        }
        .rotationEffect(.degrees(angleDeg))
    }

    // MARK: - Scrub gesture

    private func scrubGesture(frameSize: CGFloat) -> some Gesture {
        let half = frameSize / 2
        return DragGesture(minimumDistance: 0, coordinateSpace: .named("radial"))
            .onChanged { value in
                let dx    = value.location.x - half
                let dy    = value.location.y - half
                let angle = atan2(dy, dx)
                var pos   = (angle + .pi / 2) / (.pi * 2)
                pos = pos.truncatingRemainder(dividingBy: 1.0)
                if pos < 0 { pos += 1 }

                if !engine.isScrubbing {
                    engine.beginScrub()
                    lastDragAngle        = angle
                    lastDragTime         = .now
                    dragAngularVelocity  = 0
                }

                let now = Date.now
                let dt  = now.timeIntervalSince(lastDragTime)
                if dt > 0.001, let prev = lastDragAngle {
                    var delta = angle - prev
                    if delta >  .pi { delta -= 2 * .pi }
                    if delta < -.pi { delta += 2 * .pi }
                    dragAngularVelocity = dragAngularVelocity * 0.6 + (delta / dt) * 0.4
                }
                lastDragAngle = angle
                lastDragTime  = now

                engine.scrubTo(position: pos)
            }
            .onEnded { _ in
                lastDragAngle = nil
                let vel = dragAngularVelocity / (.pi * 2)
                dragAngularVelocity = 0
                engine.endScrub(velocityLoopsPerSec: vel)
            }
    }

    // MARK: - Pinch gesture

    private var ringsElasticScale: CGFloat {
        let delta = pinchScale - 1.0
        return 1.0 + delta * 0.32
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pinchScale = value
                guard !pinchFired, !engine.samples.isEmpty else { return }
                if value > 1.55 {
                    pinchFired = true
                    triggerHaptic()
                    engine.doubleLoopLength()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.52)) { pinchScale = 1.0 }
                } else if value < 0.65 {
                    pinchFired = true
                    triggerHaptic()
                    engine.halveLoopLength()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.52)) { pinchScale = 1.0 }
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.62)) { pinchScale = 1.0 }
                pinchFired = false
            }
    }

    private func triggerHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        #endif
    }

    // MARK: - Record button

    private var recordButton: some View {
        ZStack {
            Circle()
                .fill(
                    engine.isRecording
                        ? Color.white.opacity(0.14)
                        : Color(red: 0.18, green: 0.18, blue: 0.22)
                )
                .frame(width: recordDiam, height: recordDiam)

            if !engine.isRecording {
                Circle()
                    .stroke(recordingColor.opacity(0.45), lineWidth: 2.5)
                    .frame(width: recordDiam, height: recordDiam)
            }

            if engine.isRecording {
                Image(systemName: "stop.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.white.opacity(0.90))
            } else {
                Image(systemName: engine.isPlaying ? "mic.fill" : "mic")
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(engine.isPlaying ? 0.38 : 0.62))
                    .animation(.easeInOut(duration: 0.25), value: engine.isPlaying)
            }
        }
        .frame(width: recordDiam, height: recordDiam)
        .animation(.spring(response: 0.22), value: engine.isRecording)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !btnPressed else { return }
                    btnPressed = true
                    pressStart = Date()
                    if !engine.isRecording { engine.startRecording() }
                }
                .onEnded { _ in
                    defer { btnPressed = false }
                    guard engine.isRecording else { return }
                    if isLatchedRec {
                        engine.stopRecording()
                        isLatchedRec = false
                    } else if Date().timeIntervalSince(pressStart) >= 0.20 {
                        engine.stopRecording()
                    } else {
                        isLatchedRec = true
                    }
                }
        )
    }

    // MARK: - Loop trim button

    private func trimButton(delta: TimeInterval, label: String) -> some View {
        Button { engine.trimLoop(delta: delta) } label: {
            Image(systemName: label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 24) {
            Button { engine.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(engine.samples.isEmpty ? 0.18 : 0.70))
            }
            .buttonStyle(.plain)
            .disabled(engine.samples.isEmpty)

            Button { engine.togglePlayback() } label: {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.18, green: 0.18, blue: 0.22))
                        .frame(width: 64, height: 64)
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(engine.samples.isEmpty ? 0.18 : 0.82))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)
            .disabled(engine.samples.isEmpty)

            ZStack {
                if engine.loopDuration != nil {
                    HStack(spacing: 6) {
                        trimButton(delta: -0.020, label: "minus")
                        if let dur = engine.loopDuration {
                            Text(String(format: "%.2fs", dur))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(minWidth: 46)
                                .monospacedDigit()
                        }
                        trimButton(delta: +0.020, label: "plus")
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else {
                    Color.clear.frame(width: 44, height: 26)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: engine.loopDuration != nil)
        }
    }
}

// MARK: - SpectrogramView

struct SpectrogramView: View {
    let bins:        [Float]
    let isRecording: Bool

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let count    = bins.count
                let barW     = size.width / CGFloat(count)
                let gap: CGFloat = 1.2
                let maxH     = size.height * 0.60
                let baseAlpha = isRecording ? 0.05 : 0.02
                let scale     = isRecording ? 0.60 : 0.38

                for i in 0..<count {
                    let mag  = CGFloat(bins[i])
                    let h    = pow(mag, 0.62) * maxH
                    guard h > 0.5 else { continue }
                    let x    = CGFloat(i) * barW + gap * 0.5
                    let w    = max(1, barW - gap)
                    let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                    let alpha = Double(mag) * scale + baseAlpha
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(.white.opacity(alpha)))
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
