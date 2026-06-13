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

    // Bar paging
    @State private var viewedBar = 0
    @State private var pageDragX: CGFloat = 0

    // Grid resolution zoom (Ableton-style): 16th steps per displayed cell — 1, 2, or 4
    @State private var displayRes = 1

    // Performance mode (ZUI): fullscreen pads while the sequencer keeps running
    @State private var showPerformance = false
    @State private var pressedPads: Set<UUID> = []

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

            if showPerformance {
                performanceOverlay
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
        .onChange(of: engine.barCount) { _, count in
            // Undo can shrink the bar count out from under the pager
            if viewedBar > count - 1 { viewedBar = count - 1 }
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
        HStack(spacing: 4) {
            // Metronome lives with the tempo controls
            Button {
                engine.toggleMetronome()
                triggerHaptic(.light)
            } label: {
                Image(systemName: "metronome.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(engine.metronomeOn ? armedColor : .white.opacity(0.35))
                    .frame(width: 36, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
                HStack {
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
                    .padding(.trailing, 8)
                }
                Spacer()
            }
        }
        #if os(iOS)
        .onAppear { padHitHaptic.prepare() }   // first hit fires without warm-up lag
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
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressedPads.contains(track.id) else { return }
                        pressedPads.insert(track.id)
                        engine.selectTrack(ti)   // audio first — trigger on touch-down
                        padHitHaptic.impactOccurred(intensity: 0.9)
                        padHitHaptic.prepare()
                    }
                    .onEnded { _ in pressedPads.remove(track.id) }
            )
    }

    // Empty slot: a mic tile with the full Keezy record gesture — hold to record
    // while held, quick tap to latch, tap again to stop.
    private func performanceMicTile(_ i: Int, w: CGFloat, h: CGFloat) -> some View {
        let isRecTarget = engine.armedTrack == i && engine.tracks.indices.contains(i)
        let recording   = engine.isRecording && isRecTarget
        let countingIn  = engine.isCountingIn && isRecTarget

        return RoundedRectangle(cornerRadius: 26)
            .fill(recording ? armedColor.opacity(0.85) : Color(red: 0.12, green: 0.12, blue: 0.14))
            .overlay(
                Group {
                    if recording {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    } else if countingIn {
                        Text("\(engine.countInBeat)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .contentTransition(.numericText(countsDown: true))
                    } else {
                        Image(systemName: "mic")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            )
            .frame(width: w, height: h)
            .animation(.easeInOut(duration: 0.15), value: recording)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !btnPressed else { return }
                        btnPressed = true
                        pressStart = Date()
                        if engine.isRecording && isLatchedRec && isRecTarget {
                            engine.stopRecording()
                            isLatchedRec = false
                        } else if !engine.isRecording {
                            while engine.tracks.count <= i,
                                  engine.tracks.count < LoopEngine.maxTracks {
                                engine.addTrack()
                            }
                            engine.armTrack(i)
                            engine.startRecording()
                        }
                    }
                    .onEnded { _ in
                        defer { btnPressed = false }
                        guard engine.isRecording, !isLatchedRec, isRecTarget else { return }
                        if Date().timeIntervalSince(pressStart) >= 0.35 {
                            engine.stopRecording()
                        } else {
                            isLatchedRec = true
                        }
                    }
            )
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
            let W = geo.size.width

            // No ScrollView here on purpose: its pan recognizer steals the horizontal
            // pager drag. All 8 rows + controls fit on screen without scrolling.
            VStack(spacing: 14) {
                VStack(spacing: rowGap) {
                    barPager(W: W)
                    if engine.tracks.count < LoopEngine.maxTracks {
                        addTrackButton(rowH: trackRowH)
                    }
                }
                .padding(.vertical, 6)

                pageIndicator
            }
        }
        .frame(maxHeight: gridMaxHeight)
    }

    private var gridMaxHeight: CGFloat {
        let rows = CGFloat(engine.tracks.count) + (engine.tracks.count < LoopEngine.maxTracks ? 1 : 0)
        return rows * trackRowH + (rows - 1) * rowGap + 12 + 58
    }

    // MARK: - Bar pager

    private func barPager(W: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<engine.barCount, id: \.self) { bar in
                barPage(bar: bar, W: W)
                    .frame(width: W)
            }
        }
        .frame(width: W, alignment: .leading)
        .offset(x: -CGFloat(viewedBar) * W + pageDragX)
        .contentShape(Rectangle())
        .simultaneousGesture(pageDragGesture(W: W))
    }

    private func barPage(bar: Int, W: CGFloat) -> some View {
        let cells        = LoopEngine.stepCount / displayRes
        let cellsPerBeat = max(1, 4 / displayRes)
        let cellW        = (W - padWidth - padGap - cellGap * CGFloat(cells - 1)
                            - (beatGap - cellGap) * 3) / CGFloat(cells)

        return VStack(spacing: rowGap) {
            ForEach(Array(engine.tracks.enumerated()), id: \.element.id) { ti, track in
                trackRow(ti: ti, track: track, bar: bar,
                         cells: cells, cellsPerBeat: cellsPerBeat, cellW: cellW, rowH: trackRowH)
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
                    ZStack {
                        Circle()
                            .fill(.white.opacity(bar == viewedBar ? 0.9 : 0.25))
                            .frame(width: 7, height: 7)
                        if engine.isPlaying && engine.currentBar == bar {
                            Circle()
                                .stroke(armedColor, lineWidth: 1.5)
                                .frame(width: 13, height: 13)
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
                engine.selectTrack(ti)
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

            HStack(spacing: 0) {
                deleteTrackButton
                undoRedoButton(systemName: "arrow.uturn.backward", enabled: engine.canUndo) {
                    engine.undo()
                }
                Spacer()
                undoRedoButton(systemName: "arrow.uturn.forward", enabled: engine.canRedo) {
                    engine.redo()
                }
                countInToggle
            }
            .padding(.horizontal, 16)
        }
    }

    // Two-stage delete: a track with a sample is cleared first (row stays);
    // pressing again on the now-empty track removes the whole row.
    private var deleteTrackButton: some View {
        let armedHasSample = engine.tracks.indices.contains(engine.armedTrack)
            && engine.tracks[engine.armedTrack].hasSample
        let canDelete = engine.tracks.count > 1 || armedHasSample

        return Button {
            triggerHaptic(.heavy)
            if armedHasSample {
                engine.clearTrack(engine.armedTrack)
            } else {
                engine.removeTrack(engine.armedTrack)
            }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(canDelete ? armedColor.opacity(0.9) : .white.opacity(0.18))
                .frame(width: 50, height: 56)
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
private let padHitHaptic            = UIImpactFeedbackGenerator(style: .rigid)
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
