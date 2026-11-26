// The recording's visual stage and shared transport. All pictures stay on this Mac.
import SwiftUI
import AppKit
import AVKit

struct CallVisualStage: View {
    @EnvironmentObject var m: WindowModel
    let d: CallDoc
    let videoURL: URL?
    let second: Double
    let seek: (Double) -> Void
    @State private var lightbox = false

    private var active: Int? { CallStudioRules.activeShotIndex(at: second, shotTimes: d.shots.map(\.t)) }
    private var shot: Shot? { active.map { d.shots[$0] } }
    private func step(_ delta: Int) {
        if let time = CallChapterRules.nextChangedShot(at: second, shots: d.shots.map(\.t), direction: delta) { seek(time) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if videoURL != nil {
                HStack(spacing: 8) {
                    Text("VIDEO").font(NativeFont.text(10, .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3).background(UIInk.selected, in: RoundedRectangle(cornerRadius: Native.corner(1)))
                    Text(m.studioVideoDuration > 0 ? CallTimelineRules.formatOffset(m.studioVideoDuration) : "Loading…")
                        .font(NativeFont.mono(11)).foregroundStyle(UIInk.muted)
                    Spacer()
                }.accessibilityElement(children: .combine)
            }
            ZStack {
                UIInk.well
                if videoURL != nil, let player = m.studioVideo {
                    VideoPlayer(player: player)
                } else if let shot {
                    CallStudioImage(url: d.dir.appendingPathComponent(shot.file), pixels: 1200)
                        .id(shot.file).transition(.opacity)
                } else {
                    VStack(spacing: 8) {
                        Glyph(videoURL == nil ? "image" : "play", size: 32)
                        Text(videoURL == nil ? "No screen frames" : "Loading video…").font(NativeFont.text(13))
                    }.foregroundStyle(UIInk.muted)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Native.radius("card")))
            .overlay(RoundedRectangle(cornerRadius: Native.radius("card")).strokeBorder(UIInk.line, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if videoURL != nil, CallStudioRules.videoEnded(at: second, duration: m.studioVideoDuration) {
                    Text("Video ended at \(CallTimelineRules.formatOffset(m.studioVideoDuration))")
                        .font(NativeFont.text(11)).foregroundStyle(UIInk.muted)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(UIInk.card, in: Capsule()).padding(10).allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: Native.motion("fade")), value: active)
            .accessibilityLabel(videoURL == nil ? "Screen replay" : "Recorded video")

            if let shot, let active {
                VStack(alignment: .leading, spacing: 8) {
                    Text([shot.app, shot.title].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(NativeFont.text(13, .medium)).lineLimit(2).textSelection(.enabled)
                    Text("Frame \(active + 1) of \(d.shots.count) · \(CallTimelineRules.formatOffset(shot.t))")
                        .font(NativeFont.mono(11)).foregroundStyle(UIInk.muted)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { frameSteps; frameActions }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { frameSteps }
                            HStack(spacing: 8) { frameActions }
                        }
                    }
                }
            }
            if !d.shots.isEmpty { filmstrip }
        }
        .font(NativeFont.text(12)).foregroundStyle(UIInk.ink)
        .buttonStyle(.bordered).controlSize(.small)
        .sheet(isPresented: $lightbox) {
            CallStudioLightbox(d: d, second: second, seek: seek).environmentObject(m)
        }
    }
    @ViewBuilder private var frameSteps: some View {
        Button { step(-1) } label: { Label { Text("Prev") } icon: { Glyph("chevron-right", size: 12).rotationEffect(.degrees(180)) } }
            .disabled((active ?? 0) == 0).help("Previous screen frame")
        Button { step(1) } label: { HStack(spacing: 4) { Text("Next"); Glyph("chevron-right", size: 12) } }
            .disabled((active ?? 0) >= d.shots.count - 1).help("Next screen frame")
    }
    @ViewBuilder private var frameActions: some View {
        Button { lightbox = true } label: { Label { Text("Lightbox") } icon: { Glyph("external", size: 12) } }
        Button("Open in Preview") { if let shot { CallStudioImage.open(d.dir.appendingPathComponent(shot.file)) } }
    }
    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(d.shots.enumerated()), id: \.offset) { i, shot in
                        Button { seek(shot.t) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                CallStudioImage(url: d.dir.appendingPathComponent(shot.file), pixels: 300)
                                    .frame(width: 112, height: 70).clipped()
                                Text(CallTimelineRules.formatOffset(shot.t)).font(NativeFont.mono(10))
                                    .padding(.horizontal, 6).padding(.bottom, 4)
                            }
                            .background(active == i ? UIInk.selected : UIInk.well)
                            .clipShape(RoundedRectangle(cornerRadius: Native.corner(1)))
                            .overlay(RoundedRectangle(cornerRadius: Native.corner(1)).strokeBorder(active == i ? UIInk.blue : UIInk.line, lineWidth: active == i ? 2 : 1))
                        }
                        .buttonStyle(.plain).id(i)
                        .accessibilityLabel("Frame \(i + 1), \(CallTimelineRules.formatOffset(shot.t)), \(shot.title)")
                        .accessibilityAddTraits(active == i ? .isSelected : [])
                        .help("Seek to \(CallTimelineRules.formatOffset(shot.t))")
                    }
                }.padding(.vertical, 2)
            }
            .onAppear { if let active { proxy.scrollTo(active, anchor: .center) } }
            .onChange(of: active) { _, i in
                if let i { withAnimation(.easeOut(duration: Native.motion("fold"))) { proxy.scrollTo(i, anchor: .center) } }
            }
        }.frame(height: 96)
    }
}

/// A fixed frame while a bounded thumbnail decode is in flight; stale callbacks cannot replace a newer frame.
struct CallStudioImage: View {
    let url: URL
    let pixels: Int
    @State private var loaded: NSImage?
    @State private var requested: URL?
    var body: some View {
        ZStack {
            UIInk.well
            if let loaded {
                Image(nsImage: loaded).resizable().interpolation(.high).scaledToFit()
            } else {
                VStack(spacing: 6) {
                    Glyph("image", size: 24)
                    if pixels > 300 { Text("Loading frame or file unavailable").font(NativeFont.text(12)) }
                }.foregroundStyle(UIInk.muted)
            }
        }.onAppear(perform: load).onChange(of: url) { _, _ in load() }
    }
    private func load() {
        requested = url; loaded = nil
        let target = url
        loaded = TapeDraw.thumbAsync(target, px: pixels) {
            guard requested == target else { return }
            loaded = TapeDraw.thumbAsync(target, px: pixels, onReady: {})
        }
    }
    static func open(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url); return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct CallStudioLightbox: View {
    @EnvironmentObject var m: WindowModel
    @Environment(\.dismiss) private var dismiss
    let d: CallDoc
    let second: Double
    let seek: (Double) -> Void
    @State private var zoom = 1.0
    @State private var image: NSImage?
    @State private var requested: URL?
    private var active: Int { CallStudioRules.activeShotIndex(at: second, shotTimes: d.shots.map(\.t)) ?? 0 }
    private var shot: Shot { d.shots[active] }
    private var url: URL { d.dir.appendingPathComponent(shot.file) }
    private func step(_ delta: Int) {
        if let i = CallStudioRules.stepShot(current: active, delta: delta, count: d.shots.count) { seek(d.shots[i].t) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Frame \(active + 1) of \(d.shots.count)").font(NativeFont.text(14, .medium))
                Text(CallTimelineRules.formatOffset(shot.t)).font(NativeFont.mono(12)).foregroundStyle(UIInk.muted)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            GeometryReader { g in
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        let scale = min(g.size.width / max(1, image.size.width), g.size.height / max(1, image.size.height)) * zoom
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .frame(minWidth: g.size.width, minHeight: g.size.height)
                    } else {
                        Text("Loading full-resolution frame…").foregroundStyle(UIInk.muted).frame(width: g.size.width, height: g.size.height)
                    }
                }
            }.background(UIInk.well)
            Divider()
            Text([shot.app, shot.title].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(NativeFont.text(13)).lineLimit(1).padding(.top, 12)
            HStack(spacing: 12) {
                Button("Prev") { step(-1) }.disabled(active == 0).keyboardShortcut(.leftArrow, modifiers: [])
                Button(m.playing == d.id ? "Pause" : "Play") { m.playing == d.id ? m.stopPlaying() : m.play(d, from: second) }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Next") { step(1) }.disabled(active == d.shots.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
                Spacer()
                Slider(value: $zoom, in: 1...4).frame(width: 120).accessibilityLabel("Frame zoom")
                Button("Fit") { zoom = 1 }
                Button("Open in Preview") { CallStudioImage.open(url) }
            }.padding(16)
        }
        .font(NativeFont.text(13)).foregroundStyle(UIInk.ink).background(UIInk.paper)
        .frame(minWidth: 720, idealWidth: 1000, minHeight: 520, idealHeight: 720)
        .onAppear(perform: load).onChange(of: url) { _, _ in load() }
    }
    private func load() {
        let target = url
        requested = target; image = nil; zoom = 1
        DispatchQueue.global(qos: .userInitiated).async {
            let full = NSImage(contentsOf: target)
            DispatchQueue.main.async { if requested == target { image = full } }
        }
    }
}

struct CallMasterTimeline: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var live: LiveLine
    let d: CallDoc
    let second: Double
    let totalSecs: Double
    let chapters: [CallChapter]
    let turns: [CallChapterTurn]
    @Binding var scrubTime: Double?
    let seek: (Double) -> Void
    let togglePlay: (Double) -> Void
    @State private var hoverTime: Double?
    @State private var wasPlayingVideo = false
    @State private var skipSilence = false
    @State private var pendingSkip: Double?
    private var displayedSecond: Double {
        if let scrubTime { return scrubTime }
        return m.playing == d.id ? live.playhead : second
    }
    private var active: Int? { CallStudioRules.activeShotIndex(at: displayedSecond, shotTimes: d.shots.map(\.t)) }
    private var bars: [SpeakerBar] { CallStudioRules.speakerSegments(turns: d.turns.map { ($0.id, $0.who, $0.start) }, totalSecs: totalSecs) }
    var body: some View {
        VStack(spacing: 10) {
            if chapters.count >= 2 { chapterRow }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { transport; Spacer(minLength: 8); skimControls; rates }
                VStack(spacing: 8) {
                    HStack(spacing: 10) { transport; Spacer(minLength: 0) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) { skimControls; rates; Spacer(minLength: 0) }
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You"); Text("Them")
                }.font(NativeFont.text(11)).foregroundStyle(UIInk.muted).frame(width: 34, alignment: .leading).padding(.top, 26)
                scrubber
            }
        }
        .font(NativeFont.text(12)).foregroundStyle(UIInk.ink).controlSize(.small)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(UIInk.card).overlay(alignment: .top) { Rectangle().fill(UIInk.line).frame(height: 1) }
        .onChange(of: d.id) { _, _ in skipSilence = false; pendingSkip = nil }
        .onReceive(live.$playhead) { time in
            guard skipSilence, m.playing == d.id, scrubTime == nil, pendingSkip == nil,
                  let target = CallChapterRules.nextPlayableTime(at: time, turns: turns), target < totalSecs else { return }
            pendingSkip = target
            // Leave the clock publisher before seeking; discard ticks superseded by a manual seek or pause.
            let id = d.id
            DispatchQueue.main.async {
                defer { pendingSkip = nil }
                guard skipSilence, m.playing == id, d.id == id, scrubTime == nil,
                      pendingSkip == target, abs(live.playhead - time) < 1 else { return }
                seek(target)
            }
        }
    }
    private var chapterRow: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chapters) { chapter in
                        let selected = displayedSecond >= chapter.start && displayedSecond < chapter.end
                        Button { seek(chapter.start) } label: {
                            HStack(spacing: 6) {
                                Text(CallTimelineRules.formatOffset(chapter.start)).font(NativeFont.mono(10))
                                Text(chapter.title).font(NativeFont.text(12)).lineLimit(1)
                            }.padding(.horizontal, 10).frame(height: 28)
                                .background(selected ? UIInk.selected : UIInk.well, in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            Button {
                History.copy(CallChapterRules.formatChaptersForCopy(chapters)); m.status = "Chapters copied"
            } label: { Label { Text("Copy chapters") } icon: { Glyph("copy", size: 12) } }
                .buttonStyle(.bordered).fixedSize()
        }
    }
    private var skimControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $skipSilence) {
                HStack(spacing: 6) {
                    Glyph("check", size: 12).opacity(skipSilence ? 1 : 0).accessibilityHidden(true)
                    Text("Skip silence")
                }
            }.toggleStyle(.button)
                .background(skipSilence ? UIInk.selected : UIInk.well, in: Capsule())
                .disabled(!turns.contains { t in
                    guard let start = t.start, let end = t.end else { return false }
                    return start.isFinite && end.isFinite && end >= start
                })
                .help("Skip gaps of at least 3 seconds with saved speech timings")
            if !d.shots.isEmpty {
                Button {
                    if let next = CallChapterRules.nextChangedShot(at: displayedSecond, shots: d.shots.map(\.t)) { seek(next) }
                } label: { Label { Text("Next screen") } icon: { Glyph("image", size: 12) } }
                    .buttonStyle(.bordered)
                    .disabled(CallChapterRules.nextChangedShot(at: displayedSecond, shots: d.shots.map(\.t)) == nil)
            }
        }.fixedSize()
    }
    @ViewBuilder private var transport: some View {
        HStack(spacing: 6) {
            Button { seek(max(0, displayedSecond - 15)) } label: {
                Text("−15s").font(NativeFont.mono(11.5)).foregroundStyle(UIInk.muted)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(UIInk.well)).contentShape(Capsule())
            }.buttonStyle(.plain).help("Back 15 seconds")
            Button { togglePlay(displayedSecond >= totalSecs ? 0 : displayedSecond) } label: {
                HStack(spacing: 6) { Glyph(m.playing == d.id ? "pause" : "play", size: 14); Text(m.playing == d.id ? "Pause" : "Play") }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .foregroundStyle(UIInk.onPrimary).background(Capsule().fill(UIInk.primary))
            }.buttonStyle(.plain).accessibilityLabel(m.playing == d.id ? "Pause recording" : "Play recording")
            Button { seek(min(totalSecs, displayedSecond + 15)) } label: {
                Text("+15s").font(NativeFont.mono(11.5)).foregroundStyle(UIInk.muted)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(UIInk.well)).contentShape(Capsule())
            }.buttonStyle(.plain).help("Forward 15 seconds")
        }
        Rectangle().fill(UIInk.line).frame(width: 1, height: 16)
        Text("\(CallTimelineRules.formatOffset(displayedSecond)) / \(CallTimelineRules.formatOffset(totalSecs))")
            .font(NativeFont.mono(12)).monospacedDigit().foregroundStyle(UIInk.muted).fixedSize()
    }
    private var rates: some View {
        HStack(spacing: 0) {
            ForEach(CallStudioRules.playbackRates, id: \.self) { rate in
                Button { m.playbackRate = rate } label: {
                    Text(CallStudioRules.formatRate(rate)).font(NativeFont.mono(11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Capsule().fill(m.playbackRate == rate ? UIInk.selected : .clear))
                }.buttonStyle(.plain).accessibilityLabel("Playback speed \(CallStudioRules.formatRate(rate))")
                    .accessibilityAddTraits(m.playbackRate == rate ? .isSelected : [])
            }
        }.background(Capsule().fill(UIInk.well)).accessibilityElement(children: .contain)
    }
    private var scrubber: some View {
        GeometryReader { g in
            let width = max(1, g.size.width - 16)
            let x = 8 + width * CallTimelineRules.progress(at: displayedSecond, total: totalSecs)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for y in [CGFloat(26), 48] {
                        ctx.fill(Path(roundedRect: CGRect(x: 8, y: y, width: width, height: 12), cornerRadius: 3), with: .color(UIInk.well))
                    }
                    for bar in bars {
                        let rect = CGRect(x: 8 + width * bar.startFrac, y: bar.isMe ? 26 : 48,
                                          width: max(1, width * (bar.endFrac - bar.startFrac)), height: 12)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(bar.isMe ? UIInk.blue : UIInk.coral))
                    }
                    if !m.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        for turn in d.hits(CallDoc.terms(m.query)) {
                            guard let t = turn.start, t.isFinite else { continue }
                            let hitX = 8 + width * CallTimelineRules.progress(at: t, total: totalSecs)
                            ctx.fill(Path(CGRect(x: hitX - 2, y: 64, width: 4, height: 5)), with: .color(UIInk.warn))
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if scrubTime == nil { wasPlayingVideo = m.beginStudioScrub() }
                    let time = CallStudioRules.seekTime(fraction: (value.location.x - 8) / width, totalSecs: totalSecs)
                    scrubTime = time; m.previewStudioSeek(time)
                }.onEnded { value in
                    let time = CallStudioRules.seekTime(fraction: (value.location.x - 8) / width, totalSecs: totalSecs)
                    m.endStudioScrub()
                    let resumeNativeVideo = wasPlayingVideo && m.playing != d.id
                    seek(time); scrubTime = nil
                    if resumeNativeVideo { m.play(d, from: time) }
                    wasPlayingVideo = false
                })
                Rectangle().fill(UIInk.ink).frame(width: 2, height: 52).offset(x: x - 1, y: 18)
                    .animation(scrubTime == nil ? .linear(duration: 0.25) : nil, value: displayedSecond).allowsHitTesting(false)
                if let preview = scrubTime ?? hoverTime {
                    Text(CallTimelineRules.formatOffset(preview)).font(NativeFont.mono(10))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(UIInk.key))
                        .offset(x: min(max(0, 8 + width * CallTimelineRules.progress(at: preview, total: totalSecs) - 28), max(0, g.size.width - 64)), y: 0)
                        .allowsHitTesting(false)
                }
                // Buttons retain native keyboard and accessibility support; the rest of the track handles drags.
                ForEach(Array(d.shots.enumerated()), id: \.offset) { i, shot in
                    Button { seek(shot.t) } label: {
                        Text("◆").font(NativeFont.text(12)).foregroundStyle(active == i ? UIInk.blue : UIInk.muted).frame(width: 20, height: 24)
                    }.buttonStyle(.plain)
                        .offset(x: 8 + width * CallTimelineRules.progress(at: shot.t, total: totalSecs) - 10, y: 10)
                        .accessibilityLabel("Frame \(i + 1) at \(CallTimelineRules.formatOffset(shot.t))")
                }
                ForEach(chapters) { chapter in
                    Button { seek(chapter.start) } label: {
                        Rectangle().fill(UIInk.muted).frame(width: 1, height: 8)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .offset(x: 8 + width * CallTimelineRules.progress(at: chapter.start, total: totalSecs) - 12, y: 66)
                        .help("\(chapter.title) [\(CallTimelineRules.formatOffset(chapter.start))]")
                        .accessibilityLabel("\(chapter.title), \(CallTimelineRules.formatOffset(chapter.start))")
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverTime = CallStudioRules.seekTime(fraction: (p.x - 8) / width, totalSecs: totalSecs)
                case .ended: hoverTime = nil
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recording timeline")
            .accessibilityValue(CallTimelineRules.formatOffset(displayedSecond))
            .accessibilityAdjustableAction { direction in seek(direction == .increment ? min(totalSecs, displayedSecond + 5) : max(0, displayedSecond - 5)) }
            .focusable()
            .onKeyPress(.leftArrow) { seek(max(0, displayedSecond - 5)); return .handled }
            .onKeyPress(.rightArrow) { seek(min(totalSecs, displayedSecond + 5)); return .handled }
        }.frame(height: 90)
    }
}

/// Human notes retain their exact text; generated notes keep their quieter ink and local source matches.
/// The notes beside a recording (meeting notes round, 26 November 2026): each line the user wrote is a point that folds
/// open to what the call added, with the moment it was said; then what else came up and the to-dos. "My notes" edits the lines.
struct CallStudioNotes: View {
    @EnvironmentObject var m: WindowModel
    let d: CallDoc
    let turns: [CallChapterTurn]
    @ObservedObject var draft: CallStudioNoteDraft
    let seek: (Double) -> Void
    @State private var filled: Bool
    @State private var notes = FoldedNotes(points: [], also: [], todos: [])
    @State private var open: Set<Int> = [0]

    private struct Source: Hashable {
        let mine: String
        let points: [String]
        let todos: [String]
        let turns: [CallChapterTurn]
    }
    private var source: Source { Source(mine: draft.text, points: d.points, todos: d.todos, turns: turns) }

    init(d: CallDoc, turns: [CallChapterTurn], draft: CallStudioNoteDraft, seek: @escaping (Double) -> Void) {
        self.d = d; self.turns = turns; self.draft = draft; self.seek = seek
        _filled = State(initialValue: !d.points.isEmpty || !d.todos.isEmpty || !d.mine.isEmpty || d.live)
    }
    private var allOpen: Bool { !notes.points.isEmpty && open.count >= notes.points.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("Notes").font(NativeFont.text(14, .semibold))
                Spacer(minLength: 0)
                if filled, notes.points.count > 1 {
                    Button(allOpen ? "Close all" : "Open all") {
                        open = allOpen ? [] : Set(notes.points.indices)
                    }.buttonStyle(.borderless).font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                }
                SwiftUI.Picker("Notes view", selection: $filled) {
                    Text("Filled out").tag(true)
                    Text("My notes").tag(false)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            if filled { filledOut } else { editor }
            if !draft.notice.isEmpty { Text(draft.notice).font(NativeFont.text(12)).foregroundStyle(UIInk.muted).textSelection(.enabled) }
        }.font(NativeFont.text(13))
            .onAppear { draft.refresh(d) }
            .onChange(of: d.mine) { _, _ in draft.refresh(d) }
            .task(id: source) {
                let input = source
                let result = await Task.detached(priority: .userInitiated) {
                    CallChapterRules.foldedNotes(myNotes: input.mine, summary: input.points, todos: input.todos, turns: input.turns)
                }.value
                if !Task.isCancelled { notes = result }
            }
    }

    @ViewBuilder private var filledOut: some View {
        if notes.isEmpty {
            Text(d.live ? "Write your points in the recording window. Drafter fills them in after the call." : "No notes yet. Switch to My notes to write your points.")
                .foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
        }
        if !notes.points.isEmpty {
            group("Your points") {
                ForEach(Array(notes.points.enumerated()), id: \.offset) { i, p in point(i, p) }
            }
        }
        if !notes.also.isEmpty {
            group(notes.points.isEmpty ? "Summary" : "Also in the call") {
                ForEach(Array(notes.also.enumerated()), id: \.offset) { _, n in detail(n) }
            }
        }
        if !notes.todos.isEmpty {
            group("To do") {
                ForEach(Array(notes.todos.enumerated()), id: \.offset) { _, n in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(UIInk.muted).accessibilityHidden(true)
                        Text(n.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        if let t = n.time { timeLink(t) }
                    }
                }
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(NativeFont.text(12, .semibold)).foregroundStyle(UIInk.muted)
            content()
        }
    }

    private func point(_ i: Int, _ p: FoldedPoint) -> some View {
        let isOpen = open.contains(i)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: Native.motion("fade"))) { if isOpen { open.remove(i) } else { open.insert(i) } }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(UIInk.muted)
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 10).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).font(NativeFont.text(13, .semibold)).foregroundStyle(UIInk.ink)
                        if !isOpen { Text(p.gist).foregroundStyle(UIInk.muted).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let t = p.time { Text(CallTimelineRules.formatOffset(t)).font(NativeFont.mono(11)).foregroundStyle(UIInk.muted) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityLabel(p.title).accessibilityValue(isOpen ? "open" : "closed").accessibilityHint("Shows what the call added")
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if p.details.isEmpty { Text(p.gist).foregroundStyle(UIInk.muted) }
                    ForEach(Array(p.details.enumerated()), id: \.offset) { _, n in detail(n) }
                    if let s = p.said, !p.details.contains(where: { $0.time == s }) {
                        HStack(spacing: 6) { Text("Said at").foregroundStyle(UIInk.muted); timeLink(s) }
                    }
                }
                .padding(.leading, 10).padding(.vertical, 2)
                .overlay(alignment: .leading) { Rectangle().fill(UIInk.line).frame(width: 2) }
                .padding(.leading, 4).padding(.bottom, 6)
            }
        }
    }

    private func detail(_ n: NoteDetail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(n.text).foregroundStyle(UIInk.ink.opacity(0.85)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if let t = n.time { timeLink(t) }
        }
    }

    private func timeLink(_ t: Double) -> some View {
        Button { seek(t) } label: { Text(CallTimelineRules.formatOffset(t)).font(NativeFont.mono(11)) }
            .buttonStyle(.link).help("Play from here")
            .accessibilityLabel("Play from \(CallTimelineRules.formatOffset(t))")
    }

    @ViewBuilder private var editor: some View {
        Text("One point a line. After the call each line fills in with what was said.").font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
        TextEditor(text: $draft.text).font(NativeFont.text(14)).foregroundStyle(UIInk.ink)
            .scrollContentBackground(.hidden).padding(8).frame(minHeight: 180)
            .background(UIInk.well, in: RoundedRectangle(cornerRadius: Native.corner(2)))
            .overlay(RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.line, lineWidth: 1))
            .accessibilityLabel("Your meeting notes").disabled(d.live)
        HStack(spacing: 12) {
            Button("Save notes") { if draft.save() { m.loadDocs() } }.disabled(!draft.changed || d.live)
                .keyboardShortcut(.return, modifiers: .command)
            if draft.changed { Text("Draft kept").foregroundStyle(UIInk.muted) }
            if d.live { Text("Edit in the recording window").foregroundStyle(UIInk.muted) }
        }.buttonStyle(.bordered).controlSize(.small)
    }
}
