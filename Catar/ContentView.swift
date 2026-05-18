import SwiftUI

private let beatColors: [Color] = [
    Color(red: 1.0,  green: 0.38, blue: 0.38),  // coral red  — accent
    Color(red: 0.25, green: 0.82, blue: 0.78),  // turquoise
    Color(red: 1.0,  green: 0.88, blue: 0.30),  // golden
    Color(red: 0.78, green: 0.48, blue: 1.0),   // lavender
]

struct ContentView: View {
    @StateObject private var engine = MetronomeEngine()

    @State private var isDragging = false
    @State private var gestureStarted = false
    @State private var dragStartBPM: Double = 120

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.0

    private var activeBeatColor: Color {
        engine.currentBeat >= 0 ? beatColors[engine.currentBeat] : Color(white: 0.3)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                VStack(spacing: 0) {
                    Spacer()
                    beatDotsRow
                        .padding(.bottom, geo.size.height * 0.07)
                    centralZone
                        .frame(height: geo.size.height * 0.38)
                    Spacer()
                    hints
                        .padding(.bottom, geo.size.height * 0.06)
                }
            }
            .ignoresSafeArea()
        }
        .gesture(mainGesture)
        .onChange(of: engine.currentBeat) { _, _ in
            triggerPulse()
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Background

    private var background: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.04, blue: 0.10),
                        engine.isPlaying
                            ? activeBeatColor.opacity(0.22)
                            : Color(red: 0.07, green: 0.07, blue: 0.17),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .animation(.easeInOut(duration: 0.12), value: engine.currentBeat)
    }

    // MARK: - Beat dots

    private var beatDotsRow: some View {
        HStack(spacing: 22) {
            ForEach(0..<4, id: \.self) { beat in
                BeatDot(
                    color: beatColors[beat],
                    isActive: engine.currentBeat == beat,
                    isAccent: beat == 0
                )
                .accessibilityLabel(beat == 0 ? "Accent beat" : "Beat \(beat + 1)")
                .accessibilityAddTraits(engine.currentBeat == beat ? .isSelected : [])
            }
        }
    }

    // MARK: - Central zone

    private var centralZone: some View {
        ZStack {
            // Expanding pulse ring
            Circle()
                .stroke(activeBeatColor, lineWidth: 2.5)
                .frame(width: 180, height: 180)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)

            // Glow disc when playing
            if engine.isPlaying {
                Circle()
                    .fill(activeBeatColor.opacity(0.12))
                    .frame(width: 180, height: 180)
                    .animation(.easeInOut(duration: 0.12), value: engine.currentBeat)
            }

            // BPM number + label
            VStack(spacing: 2) {
                Text("\(Int(engine.bpm.rounded()))")
                    .font(.system(size: isDragging ? 128 : 96, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, activeBeatColor],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
                    .accessibilityLabel("\(Int(engine.bpm.rounded())) BPM")

                Text("BPM")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Hints

    private var hints: some View {
        VStack(spacing: 6) {
            Text(engine.isPlaying ? "tap to stop" : "tap to start")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .accessibilityLabel(engine.isPlaying ? "Stop metronome" : "Start metronome")

            Text("drag up · faster   drag down · slower")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.22))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Gesture

    private var mainGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !gestureStarted {
                    gestureStarted = true
                    dragStartBPM = engine.bpm
                }
                if abs(value.translation.height) > 8 {
                    if !isDragging { isDragging = true }
                    let delta = -value.translation.height / 2.5
                    engine.setBPM(dragStartBPM + delta)
                }
            }
            .onEnded { value in
                if !isDragging {
                    engine.toggle()
                }
                isDragging = false
                gestureStarted = false
            }
    }

    // MARK: - Pulse animation

    private func triggerPulse() {
        pulseScale = 1.0
        pulseOpacity = 0.85
        withAnimation(.easeOut(duration: 0.55)) {
            pulseScale = 2.6
            pulseOpacity = 0
        }
    }
}

// MARK: - Beat dot

struct BeatDot: View {
    let color: Color
    let isActive: Bool
    let isAccent: Bool

    private var size: CGFloat {
        isActive ? (isAccent ? 24 : 20) : (isAccent ? 16 : 13)
    }

    var body: some View {
        Circle()
            .fill(isActive ? color : color.opacity(0.22))
            .frame(width: size, height: size)
            .shadow(color: isActive ? color.opacity(0.9) : .clear, radius: 12, x: 0, y: 0)
            .animation(.spring(response: 0.12, dampingFraction: 0.55), value: isActive)
    }
}

#Preview {
    ContentView()
}
