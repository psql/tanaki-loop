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
    Color(red: 0.45, green: 0.95, blue: 0.95),
    Color(red: 0.99, green: 0.50, blue: 0.75),
]

private func trackColor(_ i: Int) -> Color { trackColors[i % trackColors.count] }

// MARK: - Grid metrics

private let padWidth:   CGFloat = 30
private let padGap:     CGFloat = 8
private let cellGap:    CGFloat = 2.5
private let beatGap:    CGFloat = 5
private let rowGap:     CGFloat = 7
private let trackRowH:  CGFloat = 40
private let recordDiam: CGFloat = 120

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var engine = LoopEngine()

    // Record button gesture state (Keezy: hold = record while held, tap = latch)
    @State private var btnPressed   = false
    @State private var pressStart   = Date()
    @State private var isLatchedRec = false

    // BPM drag state
    @State private var bpmDragBase: Double? = nil

    // Tap tempo ZUI
    @Namespace private var zuiNS
    @State private var showTapTempo = false
    @State private var tapTimes: [Date] = []
    @State private var tapPulse: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color(red: 0.09, green: 0.09, blue: 0.12).ignoresSafeArea()

            if engine.isRecording {
                armedColor.opacity(0.30).ignoresSafeArea().transition(.opacity)
            }

            VStack(spacing: 0) {
                transportBar
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                Spacer(minLength: 16)

                grid
                    .padding(.horizontal, 12)

                Spacer(minLength: 16)

                bottomBar
                    .padding(.bottom, 28)
            }

            if showTapTempo {
                tapTempoOverlay
            }
        }
        .animation(.easeInOut(duration: 0.20), value: engine.isRecording)
        .onChange(of: engine.isRecording) { _, recording in
            if !recording {
                isLatchedRec = false
            } else if !btnPressed {
                // Recording began while no finger was down (count-in finished) — latch
                // so the next tap stops it.
                isLatchedRec = true
            }
        }
        .onChange(of: engine.metronomeBeat) { _, beat in
            guard engine.metronomeOn, beat >= 0 else { return }
            metronomeBuzz(downbeat: beat == 0)
        }
        .onChange(of: engine.countInBeat) { _, beat in
            guard beat > 0 else { return }
            metronomeBuzz(downbeat: beat == 4)
        }
    }

    private var armedColor: Color {
        guard engine.tracks.indices.contains(engine.armedTrack) else { return trackColors[0] }
        return trackColor(engine.tracks[engine.armedTrack].colorIndex)
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button { engine.togglePlayback() } label: {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.18, green: 0.18, blue: 0.22))
                        .frame(width: 56, height: 56)
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)

            Button {
                engine.toggleMetronome()
                triggerHaptic(.light)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.18, green: 0.18, blue: 0.22)
                            .opacity(engine.metronomeOn ? 1.0 : 0.55))
                    Image(systemName: "metronome.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(engine.metronomeOn ? armedColor : .white.opacity(0.35))
                }
                .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)

            // Live input meter, toolbar-sized
            SpectrogramView(bins: engine.fftMagnitudes, isRecording: engine.isRecording)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)

            bpmControl
        }
    }

    private var bpmControl: some View {
        HStack(spacing: 8) {
            HoldRepeatButton(systemName: "minus") { step in nudgeBPM(-step) }

            if showTapTempo {
                // Placeholder keeps the toolbar layout while the label is zoomed out
                Color.clear.frame(width: 62, height: 56)
            } else {
                bpmLabel
                    .matchedGeometryEffect(id: "bpmZui", in: zuiNS)
                    .onTapGesture {
                        triggerHaptic(.light)
                        tapTimes.removeAll()
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                            showTapTempo = true
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                if bpmDragBase == nil { bpmDragBase = engine.bpm }
                                // Drag up to speed up: 1 BPM per 4 pt
                                setBPMTicking((bpmDragBase ?? 120) - Double(v.translation.height) / 4)
                            }
                            .onEnded { _ in bpmDragBase = nil }
                    )
            }

            HoldRepeatButton(systemName: "plus") { step in nudgeBPM(step) }
        }
    }

    private var bpmLabel: some View {
        VStack(spacing: 1) {
            Text("\(Int(engine.bpm))")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .monospacedDigit()
            Text("BPM")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.40))
        }
        .frame(width: 62, height: 56)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.16, green: 0.16, blue: 0.20).opacity(0.01)))
        .contentShape(Rectangle())
    }

    // MARK: - Tap tempo (ZUI)

    private var tapTempoOverlay: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.09).opacity(0.94)
                .ignoresSafeArea()
                .transition(.opacity)

            // The BPM label, zoomed up into a tap surface
            ZStack {
                RoundedRectangle(cornerRadius: 36)
                    .fill(Color(red: 0.16, green: 0.16, blue: 0.20))

                Circle()
                    .stroke(armedColor.opacity(0.8), lineWidth: 3)
                    .frame(width: 210, height: 210)
                    .scaleEffect(tapPulse)

                VStack(spacing: 4) {
                    Text("\(Int(engine.bpm))")
                        .font(.system(size: 88, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.18), value: Int(engine.bpm))
                    Text("BPM")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .matchedGeometryEffect(id: "bpmZui", in: zuiNS)
            .frame(width: 320, height: 340)

            VStack {
                Spacer()
                Text("TAP TO THE BEAT")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 90)
            }
            .allowsHitTesting(false)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                            showTapTempo = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 64, height: 64)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { registerTempoTap() }
    }

    // Classic tap tempo: average the recent tap intervals; a long pause starts over.
    private func registerTempoTap() {
        let now = Date()
        if let last = tapTimes.last, now.timeIntervalSince(last) > 2.5 {
            tapTimes.removeAll()
        }
        tapTimes.append(now)
        if tapTimes.count > 9 { tapTimes.removeFirst() }

        triggerHaptic(.light)
        tapPulse = 1.16
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { tapPulse = 1.0 }

        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0.0.timeIntervalSince($0.1) }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        guard avg > 0 else { return }
        engine.setBPM((60.0 / avg).rounded())
    }

    private func nudgeBPM(_ delta: Double) {
        setBPMTicking(engine.bpm + delta)
    }

    // Set BPM with a selection-tick haptic whenever the displayed integer changes.
    private func setBPMTicking(_ target: Double) {
        let before = Int(engine.bpm)
        engine.setBPM(target)
        if Int(engine.bpm) != before {
            #if os(iOS)
            bpmTickHaptic.selectionChanged()
            bpmTickHaptic.prepare()
            #endif
        }
    }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { geo in
            let steps    = LoopEngine.stepCount
            let beatGaps = CGFloat(steps / 4 - 1)
            let cellW    = (geo.size.width - padWidth - padGap
                            - cellGap * CGFloat(steps - 1) - beatGap * beatGaps) / CGFloat(steps)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: rowGap) {
                        ForEach(Array(engine.tracks.enumerated()), id: \.element.id) { ti, track in
                            trackRow(ti: ti, track: track, cellW: cellW, rowH: trackRowH)
                                .id(track.id)
                        }
                        if engine.tracks.count < LoopEngine.maxTracks {
                            addTrackButton(rowH: trackRowH)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: engine.tracks.count) { old, new in
                    guard new > old, let last = engine.tracks.last else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxHeight: gridMaxHeight)
    }

    private var gridMaxHeight: CGFloat {
        let rows = CGFloat(engine.tracks.count) + (engine.tracks.count < LoopEngine.maxTracks ? 1 : 0)
        return rows * trackRowH + (rows - 1) * rowGap + 12
    }

    private func trackRow(ti: Int, track: Track, cellW: CGFloat, rowH: CGFloat) -> some View {
        let isArmed    = engine.armedTrack == ti
        let triggering = isTriggering(track)

        return HStack(spacing: padGap) {
            trackPad(ti: ti, track: track, rowH: rowH)
            HStack(spacing: cellGap) {
                ForEach(0..<LoopEngine.stepCount, id: \.self) { step in
                    stepCell(ti: ti, track: track, step: step, cellW: cellW, rowH: rowH)
                        .padding(.trailing, step % 4 == 3 && step != LoopEngine.stepCount - 1 ? beatGap - cellGap : 0)
                }
            }
        }
        .frame(height: rowH)
        .background(
            // Armed-row highlight: expands past the row bounds (negative padding) so it
            // doesn't disturb the grid layout math.
            RoundedRectangle(cornerRadius: 10)
                .fill(trackColor(track.colorIndex).opacity(isArmed ? 0.16 : 0))
                .padding(-4)
        )
        .scaleEffect(triggering ? 1.05 : 1.0)
        .zIndex(triggering ? 1 : 0)
        .animation(.spring(response: 0.16, dampingFraction: 0.45), value: triggering)
        .animation(.easeOut(duration: 0.18), value: engine.armedTrack)
        .onLongPressGesture(minimumDuration: 0.45) {
            triggerHaptic(.heavy)
            engine.armTrack(ti)
        }
    }

    private func isTriggering(_ track: Track) -> Bool {
        engine.isPlaying && track.hasSample
            && track.steps.indices.contains(engine.currentStep)
            && track.steps[engine.currentStep]
    }

    // Track pad: tap = arm + audition, long-press = delete track.
    private func trackPad(ti: Int, track: Track, rowH: CGFloat) -> some View {
        let color      = trackColor(track.colorIndex)
        let isArmed    = engine.armedTrack == ti
        let triggering = isTriggering(track)

        return RoundedRectangle(cornerRadius: 8)
            .fill(color.opacity(track.hasSample ? 0.95 : 0.28))
            .frame(width: padWidth, height: rowH)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(isArmed ? 0.9 : 0), lineWidth: 2)
            )
            .scaleEffect(triggering ? 1.55 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.42), value: triggering)
            .contentShape(Rectangle())
            .onTapGesture {
                triggerHaptic(.light)
                engine.selectTrack(ti)
            }
    }

    private func stepCell(ti: Int, track: Track, step: Int, cellW: CGFloat, rowH: CGFloat) -> some View {
        let color      = trackColor(track.colorIndex)
        let on         = track.steps[step]
        let isPlayhead = engine.isPlaying && engine.currentStep == step
        let isBeat     = step % 4 == 0

        let fill: Color = on
            ? color.opacity(isPlayhead ? 1.0 : 0.82)
            : .white.opacity(isPlayhead ? 0.22 : (isBeat ? 0.10 : 0.06))

        return RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .frame(width: cellW, height: rowH)
            .contentShape(Rectangle())
            .onTapGesture {
                triggerHaptic(.light)
                engine.toggleStep(track: ti, step: step)
            }
    }

    private func addTrackButton(rowH: CGFloat) -> some View {
        HStack(spacing: padGap) {
            Button {
                triggerHaptic(.light)
                engine.addTrack()
            } label: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: padWidth, height: rowH)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(height: rowH)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        ZStack {
            recordButton

            HStack {
                deleteTrackButton
                Spacer()
                countInToggle
            }
            .padding(.horizontal, 32)
        }
    }

    // Deletes the armed track entirely (sample + row). Long-press on a track pad does the same.
    private var deleteTrackButton: some View {
        let armedHasSample = engine.tracks.indices.contains(engine.armedTrack)
            && engine.tracks[engine.armedTrack].hasSample
        let canDelete = engine.tracks.count > 1 || armedHasSample

        return Button {
            triggerHaptic(.heavy)
            engine.removeTrack(engine.armedTrack)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(canDelete ? armedColor.opacity(0.9) : .white.opacity(0.18))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .disabled(!canDelete)
    }

    // Count-in checkbox: when on, record gives a one-bar click count before capturing.
    private var countInToggle: some View {
        Button {
            triggerHaptic(.light)
            engine.toggleCountIn()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: engine.countInEnabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(engine.countInEnabled ? armedColor : .white.opacity(0.40))
                    .contentTransition(.symbolEffect(.replace))
                Text("COUNT-IN")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(engine.countInEnabled ? 0.6 : 0.35))
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
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
                    .stroke(armedColor.opacity(0.55), lineWidth: 2.5)
                    .frame(width: recordDiam, height: recordDiam)
            }

            if engine.isRecording {
                Image(systemName: "stop.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.90))
            } else if engine.isCountingIn {
                Text("\(engine.countInBeat)")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(armedColor)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.15), value: engine.countInBeat)
            } else {
                Image(systemName: engine.isPlaying ? "mic.fill" : "mic")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(engine.isPlaying ? 0.45 : 0.62))
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
                    if engine.isRecording && isLatchedRec {
                        // Second tap while latched → stop immediately on touch-down
                        engine.stopRecording()
                        isLatchedRec = false
                    } else if !engine.isRecording {
                        engine.startRecording()
                    }
                    // If recording but not latched: wait for touch-up to decide hold vs tap
                }
                .onEnded { _ in
                    defer { btnPressed = false }
                    guard engine.isRecording, !isLatchedRec else { return }
                    if Date().timeIntervalSince(pressStart) >= 0.35 {
                        // Held long enough → stop on release (hold-to-record)
                        engine.stopRecording()
                    } else {
                        // Short tap → latch; next tap stops
                        isLatchedRec = true
                    }
                }
        )
    }

    // MARK: - Haptics

    private enum HapticWeight { case light, heavy }

    private func triggerHaptic(_ weight: HapticWeight) {
        #if os(iOS)
        switch weight {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
        #endif
    }

    private func metronomeBuzz(downbeat: Bool) {
        #if os(iOS)
        if downbeat {
            metronomeDownbeatHaptic.impactOccurred(intensity: 1.0)
        } else {
            metronomeBeatHaptic.impactOccurred(intensity: 0.7)
        }
        // Keep the Taptic Engine warm so the next beat fires with minimal latency
        metronomeDownbeatHaptic.prepare()
        metronomeBeatHaptic.prepare()
        #endif
    }
}

#if os(iOS)
// Long-lived, prepared generators — beat timing is too tight to recreate them per buzz.
private let metronomeDownbeatHaptic = UIImpactFeedbackGenerator(style: .heavy)
private let metronomeBeatHaptic     = UIImpactFeedbackGenerator(style: .rigid)
private let bpmTickHaptic           = UISelectionFeedbackGenerator()
#endif

// MARK: - HoldRepeatButton

// Classic stepper button: tap = one step, hold = auto-repeat after a short delay,
// accelerating the longer it's held (±1 → ±2 → ±4 per tick).
private struct HoldRepeatButton: View {
    let systemName: String
    let action: (Double) -> Void

    @State private var pressed = false
    @State private var repeatTimer: Timer? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.18, green: 0.18, blue: 0.22)
                    .opacity(pressed ? 1.0 : 0.55))
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white.opacity(pressed ? 0.95 : 0.65))
        }
        .frame(width: 56, height: 56)
        .scaleEffect(pressed ? 0.90 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
        .contentShape(Circle().scale(1.35))   // hit area generously larger than the visual
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    action(1)
                    let pressDate = Date()
                    repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                        let held = Date().timeIntervalSince(pressDate)
                        guard held > 0.45 else { return }   // initial delay before repeating
                        let step: Double = held > 3.0 ? 4 : (held > 1.5 ? 2 : 1)
                        action(step)
                    }
                }
                .onEnded { _ in
                    pressed = false
                    repeatTimer?.invalidate()
                    repeatTimer = nil
                }
        )
        .onDisappear {
            repeatTimer?.invalidate()
            repeatTimer = nil
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
