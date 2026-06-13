import SwiftUI
#if os(iOS)
import UIKit
import CoreHaptics
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
private let trackRowMax: CGFloat = 40   // portrait cap
private let trackRowMin: CGFloat = 15   // landscape floor
private let pageIndicatorH: CGFloat = 30
private let gridVSpacing:   CGFloat = 12
private let recordDiam: CGFloat = 120

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var engine = LoopEngine()
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var isLandscape: Bool { vSizeClass == .compact }
    #else
    private var isLandscape: Bool { false }
    #endif

    // Record button gesture state (Keezy: hold = record while held, tap = latch)
    @State private var btnPressed   = false
    @State private var pressStart   = Date()
    @State private var isLatchedRec = false
    @State private var micPressStartedRec = false   // this mic-tile press initiated recording

    // BPM drag state
    @State private var bpmDragBase: Double? = nil

    // Tap tempo ZUI
    @Namespace private var zuiNS
    @State private var showTapTempo = false
    @State private var tapTimes: [Date] = []
    @State private var tapPulse: CGFloat = 1.0

    // Bar paging
    @State private var viewedBar = 0
    @State private var pageDragX: CGFloat = 0
    @State private var loopOn = false   // loop just the currently-viewed bar

    // Metronome visual flash (lets you see the tempo)
    @State private var metroFlash: CGFloat = 0
    @State private var metroFlashDownbeat = false

    // Grid resolution zoom (Ableton-style): 16th steps per displayed cell — 1, 2, or 4
    @State private var displayRes = 1

    // Metronome options (ZUI)
    @State private var showMetronomeOptions = false

    // Performance mode (ZUI): fullscreen pads while the sequencer keeps running
    @State private var showPerformance = false
    @State private var pressedPads: Set<UUID> = []
    @State private var padSwipeX: [UUID: CGFloat] = [:]   // interactive swipe-to-delete
    @State private var scaleInSlots: Set<Int> = []        // slots whose mic tile is appearing

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if engine.isRecording {
                armedColor.opacity(0.30).ignoresSafeArea().transition(.opacity)
            }

            VStack(spacing: 0) {
                transportBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                // Grid fills the space between the bars; its rows size to fit so the
                // layout stays friendly in landscape (short) as well as portrait.
                grid
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)

                bottomBar
                    .padding(.bottom, isLandscape ? 12 : 28)
            }

            if showTapTempo {
                tapTempoOverlay
            }

            if showPerformance {
                performanceOverlay
            }

            if showMetronomeOptions {
                metronomeOptionsOverlay
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
            flashMetronome(downbeat: beat == 0)
        }
        .onChange(of: engine.countInBeat) { _, beat in
            guard beat > 0 else { return }
            metronomeBuzz(downbeat: beat == 4)
            flashMetronome(downbeat: beat == 4)
        }
        .onChange(of: engine.barCount) { _, count in
            // Undo can shrink the bar count out from under the pager
            if viewedBar > count - 1 { viewedBar = count - 1 }
        }
        .onChange(of: viewedBar) { _, bar in
            // Loop follows the page you're viewing while engaged
            if loopOn { engine.setLoopedBar(bar) }
            engine.setEditingBar(bar)   // paused recordings land on the viewed bar
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

            // Performance mode: zooms into fullscreen pads
            if showPerformance {
                Color.clear.frame(width: 40, height: 56)
            } else {
                Button {
                    triggerHaptic(.light)
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                        showPerformance = true
                    }
                } label: {
                    KeezyGridIcon()
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 40, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .matchedGeometryEffect(id: "perfZui", in: zuiNS)
            }

            // Loop just the bar you're looking at
            Button {
                loopOn.toggle()
                engine.setLoopedBar(loopOn ? viewedBar : nil)
                triggerHaptic(.light)
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(loopOn ? armedColor : .white.opacity(0.35))
                    .frame(width: 40, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            bpmControl
        }
    }

    private var metronomeIconColor: Color {
        guard engine.metronomeOn else { return .white.opacity(0.35) }
        return armedColor.opacity(0.55 + 0.45 * Double(metroFlash))
    }

    private var metronomeIconScale: CGFloat {
        let amount: CGFloat = metroFlashDownbeat ? 0.4 : 0.24
        return 1 + metroFlash * amount
    }

    private var bpmControl: some View {
        HStack(spacing: 4) {
            // Metronome lives with the tempo controls; long-hold opens its options
            if showMetronomeOptions {
                Color.clear.frame(width: 36, height: 56)
            } else {
                Image(systemName: "metronome.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(metronomeIconColor)
                    .scaleEffect(metronomeIconScale)
                    .brightness(Double(metroFlash) * 0.25)
                    .frame(width: 36, height: 56)
                    .contentShape(Rectangle())
                    .matchedGeometryEffect(id: "metroZui", in: zuiNS)
                    .onTapGesture {
                        engine.toggleMetronome()
                        triggerHaptic(.light)
                    }
                    .onLongPressGesture(minimumDuration: 0.45) {
                        triggerHaptic(.heavy)
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                            showMetronomeOptions = true
                        }
                    }
            }

            HoldRepeatButton(systemName: "minus") { step in nudgeBPM(-step) }

            if showTapTempo {
                // Placeholder keeps the toolbar layout while the label is zoomed out
                Color.clear.frame(width: 58, height: 56)
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
        .frame(width: 58, height: 56)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.16, green: 0.16, blue: 0.20).opacity(0.01)))
        .contentShape(Rectangle())
    }

    // MARK: - Tap tempo (ZUI)

    private var tapTempoOverlay: some View {
        ZStack {
            Color.black.opacity(0.94)
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

    // MARK: - Metronome options (ZUI)

    private var metronomeOptionsOverlay: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture {
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                        showMetronomeOptions = false
                    }
                }

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "metronome.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(engine.metronomeOn ? armedColor : .white.opacity(0.5))
                    Text("METRONOME")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }

                metronomeOptionRow(
                    title: "SILENT MODE",
                    caption: "haptic buzz only — no click",
                    isOn: engine.metronomeSilent
                ) {
                    engine.toggleMetronomeSilent()
                }
            }
            .padding(30)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color(red: 0.13, green: 0.13, blue: 0.16))
            )
            .matchedGeometryEffect(id: "metroZui", in: zuiNS)
            .padding(.horizontal, 36)
        }
    }

    private func metronomeOptionRow(title: String, caption: String,
                                    isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            triggerHaptic(.light)
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isOn ? armedColor : .white.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(caption)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Performance mode (ZUI)

    // Classic Keezy board: always 8 slots (2×4). Slots with samples are playable
    // pads (trigger on touch-down, monophonic); empty slots are mic tiles you can
    // record into right here, while the loop keeps running.
    private var performanceOverlay: some View {
        ZStack {
            Color.black.opacity(0.97)
                .ignoresSafeArea()
                .transition(.opacity)

            performancePadGrid
                .padding(16)
                .padding(.top, 44)
                .matchedGeometryEffect(id: "perfZui", in: zuiNS)

            VStack {
                HStack(spacing: 4) {
                    undoRedoButton(systemName: "arrow.uturn.backward", enabled: engine.canUndo) {
                        engine.undo()
                    }
                    undoRedoButton(systemName: "arrow.uturn.forward", enabled: engine.canRedo) {
                        engine.redo()
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                            showPerformance = false
                        }
                    } label: {
                        Image(systemName: "square.grid.4x3.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 64, height: 64)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                Spacer()
            }
        }
        #if os(iOS)
        .onAppear { Haptics.shared.warmUp() }   // first hit fires without warm-up lag
        #endif
    }

    private var performancePadGrid: some View {
        let cols = 2, rows = 4
        let gap: CGFloat = 12

        return GeometryReader { geo in
            let padW = (geo.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let padH = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<cols, id: \.self) { c in
                            performanceSlot(r * cols + c, w: padW, h: padH)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func performanceSlot(_ i: Int, w: CGFloat, h: CGFloat) -> some View {
        if engine.tracks.indices.contains(i), engine.tracks[i].hasSample {
            performancePad(ti: i, track: engine.tracks[i], w: w, h: h)
        } else {
            performanceMicTile(i, w: w, h: h)
        }
    }

    private func performancePad(ti: Int, track: Track, w: CGFloat, h: CGFloat) -> some View {
        let color      = trackColor(track.colorIndex)
        let pressed    = pressedPads.contains(track.id)
        let triggering = isTriggering(track)
        let swipeX     = padSwipeX[track.id] ?? 0

        return RoundedRectangle(cornerRadius: 26)
            .fill(color.opacity(pressed ? 1.0 : (triggering ? 0.95 : 0.78)))
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(.white.opacity(pressed ? 0.7 : 0), lineWidth: 3)
            )
            .frame(width: w, height: h)
            .scaleEffect(pressed ? 0.86 : (triggering ? 1.03 : 1.0))
            .brightness(pressed ? 0.10 : 0)
            // Press-down snaps instantly; release keeps the springy bounce-back
            .animation(pressed ? nil : .spring(response: 0.30, dampingFraction: 0.5), value: pressed)
            .animation(.spring(response: 0.16, dampingFraction: 0.5), value: triggering)
            .offset(x: swipeX)
            .rotationEffect(.degrees(Double(swipeX) / 30))
            .opacity(1.0 - Double(min(abs(swipeX) / (w * 1.4), 0.5)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !pressedPads.contains(track.id) {
                            pressedPads.insert(track.id)
                            engine.selectTrack(ti)   // audio first — trigger on touch-down
                            Haptics.shared.pulse(intensity: 0.9, sharpness: 0.6)
                        }
                        // Drag sideways to throw the tile away — tracks the finger 1:1
                        if abs(v.translation.width) > 14 {
                            padSwipeX[track.id] = v.translation.width
                        }
                    }
                    .onEnded { _ in
                        pressedPads.remove(track.id)
                        let dx = padSwipeX[track.id] ?? 0
                        if abs(dx) > w * 0.45 {
                            // Off the edge: fly out, then the slot reverts to a mic tile
                            triggerHaptic(.heavy)
                            withAnimation(.easeIn(duration: 0.18)) {
                                padSwipeX[track.id] = dx > 0 ? w * 2.4 : -w * 2.4
                            }
                            // Once the old tile has fully left, swap to the mic tile and
                            // let it scale in (handled in performanceMicTile.onAppear) so
                            // the replacement doesn't pop in harshly.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                scaleInSlots.insert(ti)
                                engine.clearTrack(ti)
                                padSwipeX[track.id] = nil
                            }
                        } else if dx != 0 {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.66)) {
                                padSwipeX[track.id] = 0
                            }
                        }
                    }
            )
    }

    // Empty slot: a mic tile with the full Keezy record gesture — hold to record
    // while held, quick tap to latch, tap again to stop.
    private func performanceMicTile(_ i: Int, w: CGFloat, h: CGFloat) -> some View {
        let isRecTarget = engine.armedTrack == i && engine.tracks.indices.contains(i)
        let recording   = engine.isRecording && isRecTarget
        let countingIn  = engine.isCountingIn && isRecTarget
        let slotColor   = engine.tracks.indices.contains(i)
            ? trackColor(engine.tracks[i].colorIndex) : trackColor(i)
        let scaleIn     = scaleInSlots.contains(i)

        return RoundedRectangle(cornerRadius: 26)
            .fill(recording ? slotColor.opacity(0.85) : Color(red: 0.12, green: 0.12, blue: 0.14))
            .overlay(
                Group {
                    if recording {
                        // Live mic waveform — shows the tile is listening
                        MicTileWaveform(bins: engine.fftMagnitudes)
                            .padding(.horizontal, 18)
                            .transition(.opacity)
                    } else if countingIn {
                        Text("\(engine.countInBeat)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .contentTransition(.numericText(countsDown: true))
                    } else {
                        // Mic icon tinted to the slot's track color — visual link to the pad it becomes
                        Image(systemName: "mic")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(slotColor.opacity(0.85))
                    }
                }
            )
            .frame(width: w, height: h)
            .scaleEffect(scaleIn ? 0.45 : 1.0)
            .opacity(scaleIn ? 0 : 1)
            .animation(.easeInOut(duration: 0.15), value: recording)
            .onAppear {
                guard scaleInSlots.contains(i) else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.66)) {
                    _ = scaleInSlots.remove(i)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !btnPressed else { return }
                        btnPressed = true
                        pressStart = Date()
                        micTouchDown(slot: i)
                    }
                    .onEnded { _ in
                        // A tap quick enough can deliver onEnded with no prior onChanged —
                        // run the touch-down here so a fast tap still starts recording.
                        if !btnPressed {
                            pressStart = Date()
                            micTouchDown(slot: i)
                        }
                        btnPressed = false
                        micTouchUp(slot: i)
                    }
            )
    }

    // Keezy mic-tile press handling. Uses fresh engine state (not values captured at
    // view-build time) so a tap on an un-armed slot latches correctly.
    private func micTouchDown(slot i: Int) {
        if engine.isRecording {
            // Pressing the tile that's recording stops it; other tiles do nothing.
            if engine.armedTrack == i && isLatchedRec {
                engine.stopRecording()
                isLatchedRec = false
            }
            micPressStartedRec = false
        } else if engine.isCountingIn {
            engine.cancelCountIn()
            micPressStartedRec = false
        } else {
            engine.armTrack(i)
            engine.startRecording()   // begins recording, or a count-in
            micPressStartedRec = true
        }
    }

    private func micTouchUp(slot i: Int) {
        guard micPressStartedRec else { return }
        micPressStartedRec = false
        if engine.isCountingIn { return }   // count-in latches via onChange(isRecording)
        guard engine.isRecording, engine.armedTrack == i else { return }
        if Date().timeIntervalSince(pressStart) >= 0.35 {
            engine.stopRecording()   // held → stop on release
        } else {
            isLatchedRec = true       // quick tap → latch on
        }
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
            Haptics.shared.pulse(intensity: 0.4, sharpness: 0.6)
            #endif
        }
    }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { geo in
            let W = geo.size.width
            // Size rows to the available height so 8 rows + the page indicator always fit
            // (capped at trackRowMax so portrait rows don't get huge). No ScrollView —
            // its pan recognizer steals the horizontal pager drag.
            let rows = CGFloat(LoopEngine.maxTracks)
            let avail = geo.size.height - pageIndicatorH - gridVSpacing - 12
            let rowH = min(trackRowMax, max(trackRowMin, (avail - rowGap * (rows - 1)) / rows))

            VStack(spacing: gridVSpacing) {
                Spacer(minLength: 0)
                barPager(W: W, rowH: rowH)
                pageIndicator
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Bar pager

    private func barPager(W: CGFloat, rowH: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<engine.barCount, id: \.self) { bar in
                barPage(bar: bar, W: W, rowH: rowH)
                    .frame(width: W)
            }
        }
        .frame(width: W, alignment: .leading)
        .offset(x: -CGFloat(viewedBar) * W + pageDragX)
        .contentShape(Rectangle())
        .simultaneousGesture(pageDragGesture(W: W))
    }

    private func barPage(bar: Int, W: CGFloat, rowH: CGFloat) -> some View {
        let cells        = LoopEngine.stepCount / displayRes
        let cellsPerBeat = max(1, 4 / displayRes)
        let cellW        = (W - padWidth - padGap - cellGap * CGFloat(cells - 1)
                            - (beatGap - cellGap) * 3) / CGFloat(cells)

        return VStack(spacing: rowGap) {
            ForEach(Array(engine.tracks.enumerated()), id: \.element.id) { ti, track in
                trackRow(ti: ti, track: track, bar: bar,
                         cells: cells, cellsPerBeat: cellsPerBeat, cellW: cellW, rowH: rowH)
            }
        }
    }

    private func pageDragGesture(W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                // Mostly-vertical drags are ignored so sloppy swipes don't page
                guard abs(v.translation.width) > abs(v.translation.height) || pageDragX != 0 else { return }
                var dx = v.translation.width
                if viewedBar == 0 && dx > 0 { dx *= 0.35 }                          // rubber band
                if viewedBar == engine.barCount - 1 && dx < 0 { dx *= 0.35 }
                pageDragX = dx
            }
            .onEnded { v in
                let dx        = v.translation.width
                let threshold = W * 0.22
                var target    = viewedBar
                if dx < -threshold && viewedBar < engine.barCount - 1 { target += 1 }
                if dx >  threshold && viewedBar > 0                   { target -= 1 }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    viewedBar = target
                    pageDragX = 0
                }
            }
    }

    // Dots centered; grid-resolution zoom on the left, delete-viewed-bar on the right.
    private var pageIndicator: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<engine.barCount, id: \.self) { bar in
                    let isLooped = loopOn && engine.loopedBar == bar
                    ZStack {
                        Circle()
                            .fill(isLooped ? armedColor : .white.opacity(bar == viewedBar ? 0.9 : 0.25))
                            .frame(width: 7, height: 7)
                        if engine.isPlaying && engine.currentBar == bar {
                            Circle()
                                .stroke(armedColor, lineWidth: 1.5)
                                .frame(width: 13, height: 13)
                        }
                        if isLooped {
                            Circle()
                                .stroke(armedColor.opacity(0.5), lineWidth: 1)
                                .frame(width: 16, height: 16)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .contentShape(Circle().scale(2.4))
                    .onTapGesture {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { viewedBar = bar }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                zoomControl
                Spacer()
                deleteBarButton
                addBarButton
            }
        }
    }

    private var addBarButton: some View {
        let canAdd = engine.barCount < LoopEngine.maxBars
        return Button {
            triggerHaptic(.heavy)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                engine.addBar()
                viewedBar = engine.barCount - 1   // jump to the new bar
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(canAdd ? 0.55 : 0.18))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            zoomButton(systemName: "minus.magnifyingglass", enabled: displayRes < 4) {
                displayRes *= 2
            }
            Text("1/\(LoopEngine.stepCount / displayRes)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 32)
                .monospacedDigit()
            zoomButton(systemName: "plus.magnifyingglass", enabled: displayRes > 1) {
                displayRes /= 2
            }
        }
    }

    private func zoomButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            triggerHaptic(.light)
            withAnimation(.spring(response: 0.30, dampingFraction: 0.8)) { action() }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.65 : 0.18))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var deleteBarButton: some View {
        Button {
            triggerHaptic(.heavy)
            let bar = viewedBar
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                if viewedBar > 0 { viewedBar -= 1 }
                engine.removeBar(bar)
            }
        } label: {
            Image(systemName: "minus.circle")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(engine.barCount > 1 ? 0.55 : 0.18))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(engine.barCount <= 1)
    }

    private func trackRow(ti: Int, track: Track, bar: Int,
                          cells: Int, cellsPerBeat: Int, cellW: CGFloat, rowH: CGFloat) -> some View {
        let isArmed    = engine.armedTrack == ti
        let triggering = isTriggering(track)

        return HStack(spacing: padGap) {
            trackPad(ti: ti, track: track, rowH: rowH)
            HStack(spacing: cellGap) {
                ForEach(0..<cells, id: \.self) { cell in
                    stepCell(ti: ti, track: track, bar: bar, cell: cell, cellW: cellW, rowH: rowH)
                        .padding(.trailing, (cell + 1) % cellsPerBeat == 0 && cell != cells - 1 ? beatGap - cellGap : 0)
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
            && track.steps.indices.contains(engine.currentBar)
            && track.steps[engine.currentBar].indices.contains(engine.currentStep)
            && track.steps[engine.currentBar][engine.currentStep]
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
                engine.armTrack(ti)   // select the row without auditioning the sample
            }
    }

    // One displayed cell covers `displayRes` 16th steps; finer-grained steps survive
    // resolution changes and show as mini dots along the cell's bottom edge.
    private func stepCell(ti: Int, track: Track, bar: Int, cell: Int, cellW: CGFloat, rowH: CGFloat) -> some View {
        let color    = trackColor(track.colorIndex)
        let range    = (cell * displayRes)..<((cell + 1) * displayRes)
        let stepsRow = track.steps.indices.contains(bar) ? track.steps[bar] : []
        let on       = !stepsRow.isEmpty && stepsRow[range].contains(true)
        let isPlayhead = engine.isPlaying && engine.currentBar == bar
            && range.contains(engine.currentStep)
        let isBeat   = (cell * displayRes) % 4 == 0

        let fill: Color = on
            ? color.opacity(isPlayhead ? 1.0 : 0.82)
            : .white.opacity(isPlayhead ? 0.22 : (isBeat ? 0.10 : 0.06))

        return RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .frame(width: cellW, height: rowH)
            .overlay(alignment: .bottom) {
                if displayRes > 1 && on {
                    HStack(spacing: 2.5) {
                        ForEach(Array(range), id: \.self) { s in
                            Circle()
                                .fill(.white.opacity(stepsRow[s] ? 0.95 : 0.22))
                                .frame(width: 3.5, height: 3.5)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                triggerHaptic(.light)
                engine.toggleSteps(track: ti, bar: bar, range: range)
            }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        ZStack {
            recordButton

            HStack(spacing: 0) {
                deleteTrackButton
                shuffleButton
                undoRedoButton(systemName: "arrow.uturn.backward", enabled: engine.canUndo) {
                    engine.undo()
                }
                Spacer()
                undoRedoButton(systemName: "arrow.uturn.forward", enabled: engine.canRedo) {
                    engine.redo()
                }
                countInToggle
            }
            .padding(.horizontal, 12)
        }
    }

    // Shuffles the armed track's pattern on the bar you're viewing.
    private var shuffleButton: some View {
        Button {
            triggerHaptic(.heavy)
            engine.shufflePattern(track: engine.armedTrack, bar: viewedBar)
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(armedColor.opacity(0.9))
                .frame(width: 44, height: 56)
        }
        .buttonStyle(.plain)
    }

    // Clears the armed track (sample + steps). Rows are permanent — always 8.
    private var deleteTrackButton: some View {
        let armed = engine.tracks.indices.contains(engine.armedTrack)
            ? engine.tracks[engine.armedTrack] : nil
        let canDelete = armed.map { $0.hasSample || $0.hasAnySteps } ?? false

        return Button {
            triggerHaptic(.heavy)
            engine.clearTrack(engine.armedTrack)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(canDelete ? armedColor.opacity(0.9) : .white.opacity(0.18))
                .frame(width: 44, height: 56)
        }
        .buttonStyle(.plain)
        .disabled(!canDelete)
    }

    private func undoRedoButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            triggerHaptic(.light)
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.7 : 0.18))
                .frame(width: 44, height: 56)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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
            // Radial input meter: bars bloom outward around the mic
            RadialMeterView(bins: engine.fftMagnitudes,
                            isRecording: engine.isRecording,
                            tint: armedColor)
                .frame(width: recordDiam + 64, height: recordDiam + 64)
                .allowsHitTesting(false)

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
                    // A tap quick enough can deliver onEnded with no prior onChanged —
                    // start recording here so a fast tap still works.
                    if !btnPressed && !engine.isRecording && !engine.isCountingIn {
                        engine.startRecording()
                        isLatchedRec = true
                    }
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
        case .light: Haptics.shared.pulse(intensity: 0.6, sharpness: 0.45)
        case .heavy: Haptics.shared.pulse(intensity: 1.0, sharpness: 0.7)
        }
        #endif
    }

    private func metronomeBuzz(downbeat: Bool) {
        #if os(iOS)
        if downbeat {
            Haptics.shared.pulse(intensity: 1.0, sharpness: 0.9)
        } else {
            Haptics.shared.pulse(intensity: 0.65, sharpness: 0.55)
        }
        #endif
    }

    // Visual beat flash on the metronome icon so the tempo is readable at a glance.
    private func flashMetronome(downbeat: Bool) {
        metroFlashDownbeat = downbeat
        metroFlash = 1
        withAnimation(.easeOut(duration: downbeat ? 0.30 : 0.22)) { metroFlash = 0 }
    }
}

#if os(iOS)
// All haptics route through one Core Haptics engine. UIFeedbackGenerator is silenced by
// the system whenever the app's AVAudioSession is `.playAndRecord` and active (which is
// always, here) — that's why nothing was buzzing. Core Haptics with playsHapticsOnly=true
// does NOT touch the audio session, so it fires regardless of recording state.
final class Haptics {
    static let shared = Haptics()

    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private init() {
        guard supported else { return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true          // don't fight the recording audio session
            e.isAutoShutdownEnabled = false     // stay warm so beats land on time
            e.resetHandler = { [weak self] in try? self?.engine?.start() }
            e.stoppedHandler = { [weak self] _ in try? self?.engine?.start() }
            try e.start()
            engine = e
        } catch {
            engine = nil
        }
    }

    func warmUp() {
        guard supported, let engine else { return }
        try? engine.start()
    }

    func pulse(intensity: Float, sharpness: Float) {
        guard supported, let engine else {
            // No Core Haptics hardware — best-effort UIKit fallback.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }
        let params = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ]
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: 0)
        do {
            try engine.start()   // no-op if already running
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player  = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}
#endif

// MARK: - KeezyGridIcon

// Literal 2×4 grid of 8 tiles — the performance board in miniature.
private struct KeezyGridIcon: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1.5).frame(width: 8, height: 5)
                    RoundedRectangle(cornerRadius: 1.5).frame(width: 8, height: 5)
                }
            }
        }
    }
}

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
        .frame(width: 52, height: 52)
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

// MARK: - MicTileWaveform

// Compact symmetric level meter drawn inside a recording mic tile.
struct MicTileWaveform: View {
    let bins: [Float]

    var body: some View {
        Canvas { ctx, size in
            // Downsample the 64 FFT bins to a handful of fat bars for a chunky, legible look
            let barCount = 13
            let mid      = size.height / 2
            let slot     = size.width / CGFloat(barCount)
            let barW     = slot * 0.55
            let src      = bins.count

            for i in 0..<barCount {
                let s0  = i * src / barCount
                let s1  = max(s0 + 1, (i + 1) * src / barCount)
                var m: CGFloat = 0
                for s in s0..<min(s1, src) { m = max(m, CGFloat(bins[s])) }
                let h = max(barW, pow(m, 0.6) * size.height * 0.9)
                let x = slot * CGFloat(i) + (slot - barW) / 2
                let rect = CGRect(x: x, y: mid - h / 2, width: barW, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                         with: .color(.white.opacity(0.85)))
            }
        }
    }
}

// MARK: - RadialMeterView

// Compact input meter: frequency bars radiate outward from the record button's rim.
struct RadialMeterView: View {
    let bins:        [Float]
    let isRecording: Bool
    let tint:        Color

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let n  = bins.count
            let r0 = recordDiam / 2 + 5
            let maxLen = size.width / 2 - r0 - 2
            let alphaScale = isRecording ? 0.85 : 0.45

            for i in 0..<n {
                let mag = CGFloat(bins[i])
                let len = pow(mag, 0.62) * maxLen
                guard len > 0.8 else { continue }
                let a  = Double(i) / Double(n) * 2 * .pi - .pi / 2
                let p0 = CGPoint(x: cx + Foundation.cos(a) * r0, y: cy + Foundation.sin(a) * r0)
                let p1 = CGPoint(x: cx + Foundation.cos(a) * (r0 + len), y: cy + Foundation.sin(a) * (r0 + len))
                var p  = Path()
                p.move(to: p0)
                p.addLine(to: p1)
                let color = isRecording ? Color.white : tint
                ctx.stroke(p, with: .color(color.opacity(Double(mag) * alphaScale + 0.04)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
