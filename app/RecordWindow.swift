// The recording window and the small notch (17 November 2026, the user: the big orange strip "gets in the way of the rest
// of the screen" while a long note or call records; the user wants a window like Granola's with the live notes, and the
// notch small up top). Setting `recordWindow`, on by default.
//   RecordLive    what the window and the notch show, fed by Talk (TalkRecord.swift) and Pill on the main thread
//   RecordWindow  a small native window: time, both sides' level, the live outline (`callNotes`), the live words, the user's
//                 own notes (saved as my-notes.md in the recording folder), Pause, Stop and a pin to keep it on top.
//                 Closing it never stops the recording; the notch opens it again. After Stop it gives way to the
//                 recording's page in the journal.
//   RecordNotch   a dot and the time beside the camera housing, inside the menu-bar band: it covers no window.
// Push-to-talk keeps the strip (Pill). The window is an ordinary activating window: when the user clicks into it Drafter is
// the front app, so Focus's off-main guard (Focus.offLimits, the calls round) covers it as it covers the main window.
// It is opened without taking focus from the call. It and the notch carry OwnChrome.strip, so screenshots leave them out.
import AppKit
import SwiftUI

/// The values that change many times a minute, each in its own small model so only the view showing it is drawn again
/// (17 November 2026: one model for everything rebuilt the whole window, its segmented control included, 12 times a
/// second for the level meters: Drafter at 116% CPU during a call). RecordPaceRules sets the pace.
/// The levels skip SwiftUI altogether (speed plan item 5, step 3): each value goes straight to its bar's layer.
final class RecordMeter {
    var me: CGFloat = 0 { didSet { meBar?.level = me } }
    var them: CGFloat = 0 { didSet { themBar?.level = them } }
    weak var meBar: MeterBarView?, themBar: MeterBarView?
}
final class RecordClock: ObservableObject { @Published var seconds = 0 }
final class RecordWords: ObservableObject { @Published var text = "" }
/// The user's own notes, in their own model (18 November 2026, the user: typing there was "jumpy": each key rebuilt the whole
/// window, its segmented control included).
final class RecordNotes: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { RecordLive.shared.notesChanged() } } }
}
/// Pre-meeting "5-second brief" (Wave 8B), isolated in its own model so async /prep + /promises updates,
/// collapse/expand, and the 120 s / live-outline auto-collapse never rebuild the rest of RecordView.
final class RecordBrief: ObservableObject {
    @Published var brief = PreMeetingBrief()
    @Published var isCall = false
    @Published var autoExpired = false
    @Published var hasLiveOutline = false
    @Published var dismissed = false
    @Published var userOverride: Bool? = nil   // nil = automatic, true = user expanded, false = user collapsed

    var visibility: PreMeetingBriefRules.BriefVisibility {
        PreMeetingBriefRules.visibility(
            isCall: isCall,
            secondsRecorded: autoExpired ? PreMeetingBriefRules.autoHideAfterSeconds : 0,
            hasLiveOutline: hasLiveOutline,
            dismissed: dismissed,
            brief: brief,
            userOverride: userOverride
        )
    }

    func reset(isCall c: Bool) {
        if brief != PreMeetingBrief() { brief = PreMeetingBrief() }
        if isCall != c { isCall = c }
        if autoExpired { autoExpired = false }
        if hasLiveOutline { hasLiveOutline = false }
        if dismissed { dismissed = false }
        if userOverride != nil { userOverride = nil }
    }

    /// Syncs call/time/outline flags once a second from RecordLive.update; publishes only on boundary flips.
    func sync(isCall c: Bool, seconds s: Int, hasLiveOutline outlined: Bool) {
        if isCall != c { isCall = c }
        let expired = s >= PreMeetingBriefRules.autoHideAfterSeconds
        if autoExpired != expired { autoExpired = expired }
        if hasLiveOutline != outlined { hasLiveOutline = outlined }
    }

    func expand() { userOverride = true }
    func collapse() { userOverride = false }
    func dismiss() { dismissed = true }
}

final class RecordLive: ObservableObject {
    static let shared = RecordLive()
    enum Pane: Hashable { case notes, words }

    @Published var active = false
    @Published var call = false
    @Published var paused = false
    @Published var title = ""
    @Published var outline: [String] = []
    @Published var warning: String?
    let meter = RecordMeter(), clock = RecordClock(), live = RecordWords()
    /// The window shows: live values are drawn only then (the record bench sets its own).
    static var shows: () -> Bool = { RecordWindow.shared.isOpen || AppWindow.shared.isVisible }   // the journal stream's Record control too
    /// The latest values; they reach the models above only while the window shows (flush), at RecordPaceRules' pace.
    private(set) var secondsNow = 0
    private var wordsNow = "", wordsAt = Date.distantPast
    private var peakMe: Float = 0, peakThem: Float = 0, hasThem = false
    private var meterTimer: Timer?
    var seconds: Int {
        get { secondsNow }
        set { secondsNow = newValue; if clock.seconds != newValue { clock.seconds = newValue } }
    }
    var words: String {
        get { wordsNow }
        set { wordsNow = newValue; if live.text != newValue { live.text = newValue } }
    }
    var me: CGFloat { get { meter.me } set { meter.me = newValue } }
    var them: CGFloat { get { meter.them } set { meter.them = newValue } }
    @Published var pane = Pane.notes
    @Published var stopArmed = false
    let mine = RecordNotes()
    let brief = RecordBrief()
    var notes: String { get { mine.text } set { mine.text = newValue } }
    func notesChanged() { saveSoon() }
    @Published var pinned = UserDefaults.standard.bool(forKey: "record.pinned") {
        didSet { if !preview { UserDefaults.standard.set(pinned, forKey: "record.pinned"); RecordWindow.shared.pin(pinned) } }
    }
    private(set) var dir: URL?
    var preview = false
    private var saveGen = 0
    private var briefGen = 0
    static let notesFile = "my-notes.md"

    /// A long note or call began (TalkRecord.startRecordingBar).
    func start(dir d: URL, call c: Bool, participants: [String] = [], eventTitle: String = "") {
        dir = d; call = c; active = true
        seconds = 0; paused = false; title = !eventTitle.isEmpty ? eventTitle : (c ? "Call" : "Note"); outline = []; words = ""; me = 0; them = 0; warning = nil
        peakMe = 0; peakThem = 0; hasThem = false; wordsAt = .distantPast
        pane = .notes; stopArmed = false; notes = ""
        briefGen += 1; let gen = briefGen
        brief.reset(isCall: c)
        RecordNotch.shared.show()
        RecordWindow.shared.open(activate: false)
        log("record window: opened for a \(c ? "call" : "long note")")
        if c && !preview {
            fetchPreMeetingBrief(gen: gen, participants: participants, eventTitle: eventTitle)
        }
    }

    /// Each second, from Pill.recording.
    func update(call c: Bool, seconds s: Int, title t: String, outline o: [String], event: String, warning w: String?) {
        guard active else { return }
        if c != call { call = c }
        secondsNow = s
        if RecordLive.shows(), clock.seconds != s { clock.seconds = s }   // once a second, only while it shows
        let p = Talk.shared.paused
        if p != paused { paused = p }
        let name = !event.isEmpty ? event : !t.isEmpty ? t : (c ? "Call" : "Note")
        if name != title { title = name }
        if o != outline { outline = o }
        if w != warning { warning = w }
        brief.sync(isCall: c, seconds: s, hasLiveOutline: !o.isEmpty)
        RecordNotch.shared.update()
    }

    /// The user's and the other side's level, per audio buffer: only kept (the loudest since the last frame); the meter timer
    /// draws it at 15 frames a second while the window shows, and nothing runs while it is hidden.
    func level(_ pk: Float, them t: Float?) {
        guard active else { return }
        peakMe = max(peakMe, pk)
        if let t { peakThem = max(peakThem, t); hasThem = true }
    }

    /// The live words so far (the mix of both sides in a call), the last part only; drawn at most 4 times a second,
    /// only when they changed and the window shows.
    func heard(_ text: String) {
        guard active else { return }
        let t = text.count > 6000 ? "…" + String(text.suffix(6000)) : text
        wordsNow = t
        guard RecordLive.shows(),
              RecordPaceRules.wordsDue(changed: t != live.text, since: Date().timeIntervalSince(wordsAt)) else { return }
        wordsAt = Date(); live.text = t
    }

    /// The window shows (again): the latest time and words at once, and the meters' timer runs until it hides.
    func flush() {
        guard active else { return }
        if clock.seconds != secondsNow { clock.seconds = secondsNow }
        if live.text != wordsNow { live.text = wordsNow; wordsAt = Date() }
        guard meterTimer == nil, !preview else { return }
        let t = Timer(timeInterval: RecordPaceRules.levelInterval, repeats: true) { [weak self] t in
            guard let self, self.active, RecordLive.shows() else {
                t.invalidate(); self?.meterTimer = nil
                if let s = self { s.meter.me = 0; s.meter.them = 0 }
                return
            }
            let me = CGFloat(Pill.share(self.peakMe)), them = self.hasThem ? CGFloat(Pill.share(self.peakThem)) : 0
            self.peakMe = 0; self.peakThem = 0
            if RecordPaceRules.levelMoved(Double(self.meter.me), Double(me)) { self.meter.me = me }
            if RecordPaceRules.levelMoved(Double(self.meter.them), Double(them)) { self.meter.them = them }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    func togglePause() {
        guard active, !preview else { return }
        Talk.shared.setPaused(!Talk.shared.paused)
        paused = Talk.shared.paused
        RecordNotch.shared.update()
    }

    /// Stop needs a second click within 3 s: a stray click never ends a call.
    func stopClicked() {
        guard active else { return }
        if !stopArmed {
            stopArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.stopArmed = false }
            return
        }
        stopArmed = false
        if !preview { Talk.shared.stopRecording("the recording window") }
    }

    /// The recording ended (or never really began): the notch goes, and an open window gives way to the journal page.
    func stopped() {
        guard active else { return }
        active = false
        briefGen += 1
        brief.reset(isCall: false)
        meterTimer?.invalidate(); meterTimer = nil
        saveNow()
        RecordNotch.shared.hide()
        let wasOpen = RecordWindow.shared.isOpen
        RecordWindow.shared.close()
        guard let d = dir, FileManager.default.fileExists(atPath: d.path) else { return }
        log("record window: recording ended, \(wasOpen ? "its page opens in the journal" : "the window was closed")")
        guard wasOpen else { return }
        DispatchQueue.main.async {
            AppWindow.shared.show()
            let doc = CallDoc.load(d, notes: CallDoc.notesIndex(Home.data.appendingPathComponent("notes")))
            AppWindow.shared.model.openDoc(doc)
            AppWindow.shared.model.loadDocs()
        }
    }

    private func fetchPreMeetingBrief(gen: Int, participants: [String], eventTitle: String) {
        let query = PreMeetingBriefRules.queryText(eventTitle: eventTitle, participants: participants)
        guard !query.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let group = DispatchGroup()
            let lock = NSLock()
            var prepJSON: [String: Any]?
            var promiseRows: [[String: Any]]?

            group.enter()
            Engine.shared.post("/prep", ["text": query], timeout: 4) { j in
                lock.lock(); prepJSON = j; lock.unlock()
                group.leave()
            }

            group.enter()
            Engine.shared.get("/promises", timeout: 4) { j in
                lock.lock(); promiseRows = j?["promises"] as? [[String: Any]]; lock.unlock()
                group.leave()
            }

            group.notify(queue: DispatchQueue.global(qos: .utility)) {
                lock.lock()
                let prep = prepJSON
                let rows = promiseRows
                lock.unlock()
                let parsed = PreMeetingBriefRules.parsePrepResponse(prep, promises: rows, participants: participants)
                guard !parsed.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self, self.active, self.call, self.briefGen == gen else { return }
                    self.brief.brief = parsed
                }
            }
        }
    }

    // MARK: the user's own notes, in the recording folder

    private func saveSoon() {
        guard !preview, active else { return }
        saveGen += 1; let g = saveGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in if self?.saveGen == g { self?.saveNow() } }
    }
    private func saveNow() {
        guard !preview, let d = dir, FileManager.default.fileExists(atPath: d.path) else { return }
        let url = d.appendingPathComponent(RecordLive.notesFile)
        let t = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { try? FileManager.default.removeItem(at: url) } else { try? (t + "\n").write(to: url, atomically: true, encoding: .utf8) }
    }

    static func clock(_ s: Int) -> String { s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
}

// MARK: the window

final class RecordWindow: NSObject, NSWindowDelegate {
    static let shared = RecordWindow()
    private var window: NSWindow?
    static let size = NSSize(width: 360, height: 560)
    var isOpen: Bool { window?.isVisible == true }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: RecordWindow.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Recording"; w.isReleasedWhenClosed = false; w.delegate = self
        w.backgroundColor = Native.paper
        w.minSize = NSSize(width: 300, height: 400)
        w.identifier = OwnChrome.strip   // left out of the recording's own screenshots and of captures
        w.contentViewController = NSHostingController(rootView: RecordView(m: RecordLive.shared))
        w.setContentSize(RecordWindow.size)
        // it keeps its place; the first time it sits at the top right of the screen, under the menu bar
        if !w.setFrameUsingName("DrafterRecordWindow"), let v = NSScreen.main?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: v.maxX - w.frame.width - 16, y: v.maxY - w.frame.height - 12))
        }
        w.setFrameAutosaveName("DrafterRecordWindow")
        return w
    }

    /// activate: false at the start (the call app keeps the keyboard); true from the notch.
    func open(activate: Bool) {
        if window == nil { window = make() }
        guard let w = window else { return }
        pin(RecordLive.shared.pinned)
        if activate { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
        RecordLive.shared.flush()
    }

    func pin(_ on: Bool) {
        window?.level = on ? .floating : .normal
        window?.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
    }

    func close() { window?.orderOut(nil) }

    func windowDidDeminiaturize(_ n: Notification) { RecordLive.shared.flush() }

    func windowWillClose(_ n: Notification) {
        if RecordLive.shared.active { log("record window: closed, the recording goes on") }
    }
}

struct RecordView: View {
    @ObservedObject var m: RecordLive
    @State private var pinHover = false

    private var hairline: some View { Rectangle().fill(UIInk.line).frame(height: 0.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
                .background(UIInk.card)
            hairline
            RecordBriefCard(b: m.brief)
            // the switch shows once there are notes to switch to; until then the live words (18 November 2026: an
            // empty Notes tab that "doesn't really work")
            if !m.outline.isEmpty {
                paneToggle
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            }
            Group { if m.pane == .notes, !m.outline.isEmpty { outline } else { transcript } }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            hairline
            mine
            hairline
            controls
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(UIInk.card)
        }
        .background(UIInk.paper)
        .foregroundStyle(UIInk.ink)
        .frame(minWidth: 300, minHeight: 400)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    if !m.paused {
                        Circle().fill(UIInk.critBg).frame(width: 14, height: 14)
                    }
                    Circle().fill(m.paused ? UIInk.faint : UIInk.crit).frame(width: 8, height: 8)
                }
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)

                Text(m.title)
                    .font(NativeFont.text(14, .semibold))
                    .foregroundStyle(UIInk.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityLabel(m.title + (m.paused ? ", paused" : ", recording"))

                Spacer(minLength: 8)

                RecordTime(c: m.clock, paused: m.paused)

                Button { m.pinned.toggle() } label: {
                    Glyph("pinned", size: 14)
                        .foregroundStyle(m.pinned ? UIInk.blue : (pinHover ? UIInk.ink : UIInk.muted))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: Native.corner(2))
                                .fill(m.pinned ? UIInk.selected : (pinHover ? UIInk.hover : Color.clear))
                        )
                        .overlay {
                            if m.pinned {
                                RoundedRectangle(cornerRadius: Native.corner(2))
                                    .strokeBorder(UIInk.blue.opacity(0.5), lineWidth: 0.5)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Native.corner(2)))
                }
                .buttonStyle(.plain)
                .onHover { pinHover = $0 }
                .help(m.pinned ? "Kept on top · click to let it go behind" : "Keep on top")
                .accessibilityLabel(m.pinned ? "Unpin the window" : "Keep the window on top")
            }

            RecordMeters(v: m.meter, call: m.call, paused: m.paused)

            if let w = m.warning {
                HStack(alignment: .center, spacing: 8) {
                    Circle().fill(UIInk.warn).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(w)
                        .font(NativeFont.text(12, .medium))
                        .foregroundStyle(UIInk.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.warnBg))
                .overlay(RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.warn.opacity(0.45), lineWidth: 0.5))
            }
        }
    }

    /// Native segmented control, as everywhere else (cohesion round, 26 November 2026).
    private var paneToggle: some View {
        SwiftUI.Picker("Recording pane", selection: $m.pane) {
            Text("Notes").tag(RecordLive.Pane.notes)
            Text("Transcript").tag(RecordLive.Pane.words)
        }.pickerStyle(.segmented).labelsHidden()
    }

    private var outline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if m.outline.isEmpty {
                    Text("Notes appear here about every minute while you talk.")
                        .font(NativeFont.text(13))
                        .foregroundStyle(UIInk.faint)
                }
                ForEach(Array(m.outline.enumerated()), id: \.offset) { _, p in
                    let todo = p.hasPrefix("→ ")
                    HStack(alignment: .top, spacing: 9) {
                        if todo {
                            RoundedRectangle(cornerRadius: 2.5)
                                .strokeBorder(UIInk.blue, lineWidth: 1.25)
                                .frame(width: 10, height: 10)
                                .padding(.top, 4)
                                .accessibilityHidden(true)
                        } else {
                            Circle()
                                .fill(UIInk.faint)
                                .frame(width: 4.5, height: 4.5)
                                .padding(.top, 7)
                                .accessibilityHidden(true)
                        }
                        Text(todo ? String(p.dropFirst(2)) : p)
                            .font(NativeFont.text(13.5))
                            .foregroundStyle(UIInk.ink)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    private var transcript: some View { RecordTranscript(w: m.live) }

    private var mine: some View { RecordMine(n: m.mine) }

    /// Native buttons: Pause bordered, Stop the main one in red (cohesion round, 26 November 2026).
    private var controls: some View {
        HStack(spacing: 10) {
            Button { m.togglePause() } label: {
                Label(m.paused ? "Resume" : "Pause", systemImage: m.paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered).controlSize(.large)
            .accessibilityLabel(m.paused ? "Resume recording" : "Pause recording")
            Spacer()
            Button(role: .destructive) { m.stopClicked() } label: {
                Label(m.stopArmed ? "Click again to stop" : "Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent).tint(Color(nsColor: .systemRed)).controlSize(.large)
            .help("Stop and save · also ⇧ Right Option")
            .accessibilityLabel(m.stopArmed ? "Click again to stop recording" : "Stop recording")
        }
    }
}

/// Pre-meeting "5-second brief" card (Wave 8B), drawn independently of meters, clock, words and notes.
struct RecordBriefCard: View {
    @ObservedObject var b: RecordBrief
    @State private var toggleHover = false
    @State private var dismissHover = false

    var body: some View {
        switch b.visibility {
        case .hidden:
            EmptyView()
        case .collapsed:
            HStack(spacing: 6) {
                Button { b.expand() } label: {
                    HStack(spacing: 5) {
                        Glyph("chevron-right", size: 10)
                            .foregroundStyle(toggleHover ? UIInk.ink : UIInk.muted)
                        Text("Show brief")
                            .font(NativeFont.text(11.5, .medium))
                            .foregroundStyle(toggleHover ? UIInk.ink : UIInk.muted)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(toggleHover ? UIInk.hover : UIInk.well))
                    .overlay(Capsule().strokeBorder(UIInk.line, lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { toggleHover = $0 }
                .help("Show pre-meeting brief")
                .accessibilityLabel("Show pre-meeting brief")

                Button { b.dismiss() } label: {
                    Glyph("close", size: 10)
                        .foregroundStyle(dismissHover ? UIInk.ink : UIInk.faint)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(dismissHover ? UIInk.hover : Color.clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { dismissHover = $0 }
                .help("Dismiss brief")
                .accessibilityLabel("Dismiss pre-meeting brief")

                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
        case .expanded:
            let items = PreMeetingBriefRules.displayItems(for: b.brief)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Glyph("calendar", size: 11)
                        .foregroundStyle(UIInk.blue)
                    Text(PreMeetingBriefRules.headerTitle(for: b.brief))
                        .font(NativeFont.text(11.5, .semibold))
                        .foregroundStyle(UIInk.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button { b.collapse() } label: {
                        Glyph("chevron-down", size: 11)
                            .foregroundStyle(toggleHover ? UIInk.ink : UIInk.muted)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: Native.corner(1)).fill(toggleHover ? UIInk.hover : Color.clear))
                            .contentShape(RoundedRectangle(cornerRadius: Native.corner(1)))
                    }
                    .buttonStyle(.plain)
                    .onHover { toggleHover = $0 }
                    .help("Collapse brief")
                    .accessibilityLabel("Collapse pre-meeting brief")

                    Button { b.dismiss() } label: {
                        Glyph("close", size: 10.5)
                            .foregroundStyle(dismissHover ? UIInk.ink : UIInk.muted)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: Native.corner(1)).fill(dismissHover ? UIInk.hover : Color.clear))
                            .contentShape(RoundedRectangle(cornerRadius: Native.corner(1)))
                    }
                    .buttonStyle(.plain)
                    .onHover { dismissHover = $0 }
                    .help("Dismiss brief")
                    .accessibilityLabel("Dismiss pre-meeting brief")
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 7) {
                            if item.kind == .promise {
                                RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(UIInk.blue, lineWidth: 1.1)
                                    .frame(width: 8.5, height: 8.5)
                                    .padding(.top, 3.5)
                                    .accessibilityHidden(true)
                            } else {
                                Circle()
                                    .fill(item.isPrimary ? UIInk.muted : UIInk.faint)
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 6)
                                    .accessibilityHidden(true)
                            }
                            Text(item.text)
                                .font(NativeFont.text(12, item.kind == .promise ? .medium : .regular))
                                .foregroundStyle(item.isPrimary ? UIInk.ink : UIInk.muted)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.card))
            .overlay(RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.line, lineWidth: 0.5))
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        }
    }
}

/// The user's own notes box, drawn alone as the user types; the hint sits over the box and never moves it.
struct RecordMine: View {
    @ObservedObject var n: RecordNotes
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Glyph("edit", size: 11).foregroundStyle(UIInk.faint)
                Text("Your notes")
                    .font(NativeFont.text(11, .medium))
                    .foregroundStyle(UIInk.faint)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityHidden(true)

            TextEditor(text: $n.text)
                .font(NativeFont.text(13))
                .foregroundStyle(UIInk.ink)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Your notes")
                .overlay(alignment: .topLeading) {
                    Text("Type your own notes here")
                        .font(NativeFont.text(13))
                        .foregroundStyle(UIInk.faint)
                        .padding(.leading, 5)
                        .opacity(n.text.isEmpty ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .frame(height: 92)
                .padding(.horizontal, 11)
                .padding(.bottom, 8)
        }
        .background(UIInk.card)
    }
}

/// The time, drawn alone once a second.
struct RecordTime: View {
    @ObservedObject var c: RecordClock
    let paused: Bool
    var body: some View {
        Text(RecordLive.clock(c.seconds))
            .font(NativeFont.mono(18, .medium))
            .foregroundStyle(paused ? UIInk.muted : UIInk.ink)
            .accessibilityLabel("Time recorded \(RecordLive.clock(c.seconds))")
    }
}

/// Both sides' level: SwiftUI lays the row out once; the bars' layers move at up to 15 frames a second (MeterBarView).
struct RecordMeters: View {
    let v: RecordMeter
    let call: Bool, paused: Bool
    var body: some View {
        HStack(spacing: 14) {
            meter("You", "microphone", v.me)
            if call { meter("Them", "waves", v.them) }
        }
    }
    private func meter(_ who: String, _ glyph: String, _ level: CGFloat) -> some View {
        HStack(spacing: 6) {
            Glyph(glyph, size: 13)
                .foregroundStyle(paused ? UIInk.faint : UIInk.muted)
            Text(who)
                .font(NativeFont.text(11, .medium))
                .foregroundStyle(UIInk.muted)
            MeterBar(meter: v, them: who == "Them", paused: paused, who: who).frame(height: 5)
        }
    }
}

/// One level bar as a layer-backed view: a track and a fill whose width is set without SwiftUI and without animation.
struct MeterBar: NSViewRepresentable {
    let meter: RecordMeter, them: Bool, paused: Bool, who: String
    func makeNSView(context: Context) -> MeterBarView {
        let b = MeterBarView(); b.who = who
        if them { meter.themBar = b } else { meter.meBar = b }
        return b
    }
    func updateNSView(_ b: MeterBarView, context: Context) {
        if them { meter.themBar = b } else { meter.meBar = b }
        b.paused = paused; b.level = them ? meter.them : meter.me
    }
}

final class MeterBarView: NSView {
    private let track = CALayer(), fill = CALayer()
    var who = ""
    var level: CGFloat = 0 { didSet { if level != oldValue { place() } } }
    var paused = false { didSet { if paused != oldValue { tint() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track); layer?.addSublayer(fill)
        for l in [track, fill] { l.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()] }
        setAccessibilityElement(true); setAccessibilityRole(.levelIndicator)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { tint() }
    override func layout() { super.layout(); place() }
    override func viewDidChangeEffectiveAppearance() { tint() }
    override func accessibilityLabel() -> String? { "\(who) level" }
    override func accessibilityValue() -> Any? { "\(Int(level * 100)) percent" }

    private func place() {
        let b = bounds, r = b.height / 2
        track.frame = b; track.cornerRadius = r
        fill.frame = CGRect(x: 0, y: 0, width: min(b.width, max(4, b.width * level)), height: b.height); fill.cornerRadius = r
    }
    private func tint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = Native.line.cgColor
            fill.backgroundColor = (paused ? Native.muted : Native.ok).cgColor
        }
    }
}

/// The live words, drawn alone when they change (at most 4 times a second).
struct RecordTranscript: View {
    @ObservedObject var w: RecordWords
    var body: some View {
        ScrollViewReader { r in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(w.text.isEmpty ? "Words show here as they are heard." : w.text)
                        .font(NativeFont.text(13.5))
                        .foregroundStyle(w.text.isEmpty ? UIInk.faint : UIInk.ink)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: w.text) { _, _ in r.scrollTo("end", anchor: .bottom) }
            .onAppear { r.scrollTo("end", anchor: .bottom) }
        }
    }
}

// MARK: the notch

/// Where the small notch sits (pure): beside the camera housing with a wing each side for the dot and the time, all
/// inside the menu-bar band; without a housing a small capsule in the middle of the menu bar.
enum NotchPlace {
    static let wing: CGFloat = 46
    static let offerWidth: CGFloat = 400, offerRow: CGFloat = 48
    /// The record offer: the housing's band plus one row under it (on a screen without a housing, the row alone,
    /// just under the menu bar), centred.
    static func offer(screen: NSRect, notch: CGFloat, bar: CGFloat) -> NSRect {
        let w = max(offerWidth, notch + 2 * wing)
        if notch > 0 { return NSRect(x: screen.midX - w / 2, y: screen.maxY - bar - offerRow, width: w, height: bar + offerRow) }
        return NSRect(x: screen.midX - w / 2, y: screen.maxY - bar - offerRow - 4, width: w, height: offerRow)
    }
    static func frame(screen: NSRect, notch: CGFloat, bar: CGFloat) -> NSRect {
        if notch > 0 {
            let w = notch + 2 * wing
            return NSRect(x: screen.midX - w / 2, y: screen.maxY - bar, width: w, height: bar)
        }
        let h = min(22, max(16, bar - 2)), w: CGFloat = 86
        return NSRect(x: screen.midX - w / 2, y: screen.maxY - bar + (bar - h) / 2, width: w, height: h)
    }
}

final class RecordNotch {
    static let shared = RecordNotch()
    private var panel: NSPanel?
    let view = NotchView()

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.identifier = OwnChrome.strip
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = view
        return p
    }

    func show() {
        if panel == nil { panel = make() }
        offering = false; panel?.contentView = view
        view.progress = nil; spin?.invalidate(); spin = nil   // a recording takes the notch from a file's progress
        place(); update()
        panel?.orderFrontRegardless()
    }
    func hide() { offering = false; panel?.orderOut(nil) }

    // MARK: the record offer from the notch (17 November 2026: a call start offers to record at once, small)

    let offerView = NotchOfferView()
    private(set) var offering = false
    private var offerGen = 0

    /// The call offer hangs from the notch: the question, who, Record (⇧ Right Option or a click) and ✕ (Esc). Offer holds the action.
    func offer(_ question: String, _ detail: String, seconds: Double) {
        if panel == nil { panel = make() }
        guard !RecordLive.shared.active else { return }   // a recording shows its time there; no offer over it
        offering = true
        offerView.question = question; offerView.detail = detail; offerView.ends = Date().addingTimeInterval(seconds)
        panel?.contentView = offerView
        guard let s = NSScreen.main ?? NSScreen.screens.first else { return }
        let (notch, bar) = RecordNotch.housing(s)
        offerView.notch = notch; offerView.bar = bar
        let f = NotchPlace.offer(screen: s.frame, notch: notch, bar: bar)
        panel?.setFrame(f, display: true)
        offerView.frame = NSRect(origin: .zero, size: f.size)
        offerView.needsDisplay = true
        let key = KeyRules.callOfferKey(voice: Drafter.shared.settings.voice)   // keys round three: never Tab
        offerView.setAccessibilityLabel(question + ". " + detail + ". Record" + (key.isEmpty ? "" : ", shift right option") + ". Dismiss, escape.")
        panel?.orderFrontRegardless()
        NSAccessibility.post(element: offerView, notification: .announcementRequested,
                             userInfo: [.announcement: question, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        offerGen += 1; let g = offerGen
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in if self?.offerGen == g { self?.endOffer() } }
    }
    func offerDetail(_ text: String) { guard offering else { return }; offerView.detail = text; offerView.needsDisplay = true }
    func endOffer() {
        guard offering else { return }
        offering = false
        if RecordLive.shared.active { show() } else { panel?.orderOut(nil) }
    }

    // MARK: a file being transcribed (FileTranscribe): a ring with the percent while it converts, a turning arc while
    // it is read. A recording going on keeps the notch; the strip then says it instead.

    private var spin: Timer?
    func progress(_ name: String, _ f: Double?, more: Int) {
        if panel == nil { panel = make() }
        let tip = (f.map { String(format: "Converting %@: %.0f%%", name, $0 * 100) } ?? "Reading \(name)…") + (more > 0 ? " · \(more) more waiting" : "") + " · click to open Drafter"
        guard !RecordLive.shared.active, !offering else { Pill.shared.show(tip, seconds: 4); return }
        view.progress = f ?? -1; view.toolTip = tip
        view.time = f.map { String(format: "%.0f%%", $0 * 100) } ?? "…"
        view.setAccessibilityLabel(tip)
        if panel?.contentView !== view || panel?.isVisible != true { panel?.contentView = view; place(); panel?.orderFrontRegardless() }
        if f == nil, spin == nil {
            spin = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let v = self?.view, v.progress != nil else { return }
                v.turn += 0.12; v.needsDisplay = true
            }
        } else if f != nil { spin?.invalidate(); spin = nil }
        view.needsDisplay = true
    }
    func endProgress() {
        spin?.invalidate(); spin = nil
        guard view.progress != nil else { return }
        view.progress = nil
        if RecordLive.shared.active { update() } else if !offering { panel?.orderOut(nil) }
    }

    static func housing(_ s: NSScreen) -> (notch: CGFloat, bar: CGFloat) {
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return (max(120, s.frame.width - l.width - r.width), s.safeAreaInsets.top)
        }
        return (0, max(22, s.frame.maxY - s.visibleFrame.maxY))
    }

    private func place() {
        guard let s = NSScreen.main ?? NSScreen.screens.first else { return }
        var notch: CGFloat = 0, bar = s.frame.maxY - s.visibleFrame.maxY
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notch = max(120, s.frame.width - l.width - r.width); bar = s.safeAreaInsets.top
        }
        view.notch = notch
        let f = NotchPlace.frame(screen: s.frame, notch: notch, bar: max(bar, 22))
        panel?.setFrame(f, display: true)
        view.frame = NSRect(origin: .zero, size: f.size)
    }

    func update() {
        let m = RecordLive.shared
        view.time = RecordLive.clock(m.seconds); view.paused = m.paused; view.warn = m.warning != nil
        view.toolTip = "\(m.title) · \(view.time)\(m.paused ? " · paused" : "") · click to open"
        view.setAccessibilityLabel("Recording \(view.time), open the recording window")
        view.needsDisplay = true
    }
}

final class NotchView: NSView {
    var notch: CGFloat = 0
    var time = "0:00", paused = false, warn = false
    var progress: Double?      // a file being transcribed: 0...1 converting, -1 reading (turning arc)
    var turn: CGFloat = 0
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { if progress != nil { AppWindow.shared.show() } else { RecordWindow.shared.open(activate: true) } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { RecordWindow.shared.open(activate: true); return true }

    override func draw(_ r: NSRect) {
        let b = bounds
        NSColor.black.setFill()
        if notch > 0 {   // the housing's black, with its rounded lower corners
            let k: CGFloat = 8
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: b.maxY)); p.line(to: NSPoint(x: b.maxX, y: b.maxY))
            p.line(to: NSPoint(x: b.maxX, y: k))
            p.appendArc(withCenter: NSPoint(x: b.maxX - k, y: k), radius: k, startAngle: 0, endAngle: 270, clockwise: true)
            p.line(to: NSPoint(x: k, y: 0))
            p.appendArc(withCenter: NSPoint(x: k, y: k), radius: k, startAngle: 270, endAngle: 180, clockwise: true)
            p.close(); p.fill()
        } else {
            NSBezierPath(roundedRect: b, xRadius: b.height / 2, yRadius: b.height / 2).fill()
        }
        let wing = notch > 0 ? NotchPlace.wing : b.width
        // the dot (left wing, or left in the capsule): red recording, orange a side not heard, grey bars paused
        let cx = notch > 0 ? wing / 2 + 4 : 14, cy = b.midY
        if let f = progress {   // a ring: the track, then the done part (or a turning quarter while it is read)
            let track = NSBezierPath(); track.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: 5.5, startAngle: 0, endAngle: 360)
            track.lineWidth = 2; NSColor.white.withAlphaComponent(0.25).setStroke(); track.stroke()
            let arc = NSBezierPath()
            let from: CGFloat = f < 0 ? 90 - turn * 57.3 : 90, to: CGFloat = f < 0 ? from - 100 : 90 - CGFloat(max(0.02, f)) * 360
            arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: 5.5, startAngle: from, endAngle: to, clockwise: true)
            arc.lineWidth = 2; arc.lineCapStyle = .round; NSColor.white.withAlphaComponent(0.9).setStroke(); arc.stroke()
        } else if paused {
            NSColor.white.withAlphaComponent(0.6).setFill()
            NSRect(x: cx - 4, y: cy - 4.5, width: 3, height: 9).fill(); NSRect(x: cx + 1, y: cy - 4.5, width: 3, height: 9).fill()
        } else {
            (warn ? NSColor.systemOrange : NSColor.systemRed).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 4, y: cy - 4, width: 8, height: 8)).fill()
        }
        let t = NSAttributedString(string: time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                                              .foregroundColor: NSColor.white.withAlphaComponent(paused ? 0.6 : 0.92)])
        let s = t.size()
        let x = notch > 0 ? b.maxX - wing / 2 - s.width / 2 - 4 : b.maxX - 10 - s.width
        t.draw(at: NSPoint(x: x, y: cy - s.height / 2))
    }
}

/// The record offer under the notch: dot, question and who on the left; Record ⇥ and ✕ on the right.
final class NotchOfferView: NSView {
    var notch: CGFloat = 0, bar: CGFloat = 32
    var question = "", detail = ""
    var ends = Date()
    private var recordRect = NSRect.zero, closeRect = NSRect.zero
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if recordRect.insetBy(dx: -4, dy: -4).contains(p) { Offer.accept() }
        else if closeRect.insetBy(dx: -4, dy: -4).contains(p) { Offer.dismiss("click") }
    }

    override func draw(_ r: NSRect) {
        let b = bounds, row = NotchPlace.offerRow
        NSColor.black.setFill()
        let k: CGFloat = 14
        NSBezierPath(roundedRect: b, xRadius: k, yRadius: k).fill()
        if notch > 0 { NSRect(x: 0, y: b.maxY - k, width: b.width, height: k).fill() }   // flat top against the menu bar
        // the row
        let y0: CGFloat = 0
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: y0 + row / 2 - 4, width: 8, height: 8)).fill()
        // buttons, right to left
        let close = NSAttributedString(string: "✕", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
        closeRect = NSRect(x: b.maxX - 34, y: y0 + row / 2 - 12, width: 24, height: 24)
        close.draw(at: NSPoint(x: closeRect.midX - close.size().width / 2, y: closeRect.midY - close.size().height / 2))
        let rec = NSMutableAttributedString(string: "Record", attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.black])
        let key = KeyRules.callOfferKey(voice: Drafter.shared.settings.voice)   // keys round three: Tab never records
        if !key.isEmpty { rec.append(NSAttributedString(string: "  " + key, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black.withAlphaComponent(0.55)])) }
        let rw = ceil(rec.size().width) + 22
        recordRect = NSRect(x: closeRect.minX - 6 - rw, y: y0 + row / 2 - 13, width: rw, height: 26)
        NSColor.white.setFill(); NSBezierPath(roundedRect: recordRect, xRadius: 13, yRadius: 13).fill()
        rec.draw(at: NSPoint(x: recordRect.minX + 11, y: recordRect.midY - rec.size().height / 2))
        // text
        let tx: CGFloat = 32, tw = recordRect.minX - 10 - tx
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let q = NSAttributedString(string: question, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para])
        let d = NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.6), .paragraphStyle: para])
        q.draw(in: NSRect(x: tx, y: y0 + row / 2 + 1, width: tw, height: 17))
        d.draw(in: NSRect(x: tx, y: y0 + row / 2 - 15, width: tw, height: 15))
    }
}

// MARK: preview (made-up text only)

enum RecordPreview {
    static func run(_ folder: String, dark: Bool, windowOnly: Bool = false) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let tag = dark ? "dark" : "light"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let m = RecordLive.shared
        m.preview = true; m.active = true; m.call = true; m.seconds = 754; m.title = "Design review: recording window"
        m.outline = ["The notch shrinks to a dot and the time while recording", "Live notes sit in a small window beside the call",
                     "→ Check both themes before the release"]
        m.words = "So the strip should stay small at the top. The window keeps the notes, and you can still type your own beside them. Closing it never stops the call."
        m.me = 0.62; m.them = 0.41; m.notes = "Ask about the pin\nSend the render"
        m.paused = false; m.pinned = false; m.stopArmed = false; m.warning = nil
        m.brief.reset(isCall: true)
        func shot(_ name: String) throws {
            let host = NSHostingView(rootView: RecordView(m: m).environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = appearance
            host.frame = NSRect(origin: .zero, size: RecordWindow.size)
            let bg = NSView(frame: host.frame); bg.wantsLayer = true; bg.appearance = appearance
            appearance?.performAsCurrentDrawingAppearance {
                bg.layer?.backgroundColor = Native.paper.cgColor
            }
            bg.addSubview(host)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            try UIShots.save(bg, folder + "/" + name + "-" + tag + ".png")
        }
        m.pane = .notes; try shot("record-notes")
        if windowOnly { try shot("record-window") }
        m.pane = .words; m.warning = "Not hearing the other side yet"; m.paused = false; try shot("record-transcript")
        m.warning = nil; m.paused = true; m.pane = .notes; m.pinned = true; m.stopArmed = true; try shot("record-paused")
        // synthetic pre-meeting brief (early in the call, before live outline notes arrive)
        m.paused = false; m.pinned = false; m.stopArmed = false; m.warning = nil
        m.seconds = 24; m.outline = []; m.pane = .words; m.title = "Weekly sync"
        m.brief.reset(isCall: true)
        m.brief.brief = PreMeetingBrief(
            participants: ["Mila Synthetic", "Sava"],
            lines: [
                "Mila Synthetic — Product Lead · Atlas · last met 18 Nov",
                "Last call: agreed on two-column layout for onboarding",
                "Sava — Engineering · reviewing release checklist"
            ],
            promises: ["Send updated rollout timeline · Mila Synthetic"],
            recentTopics: ["Atlas onboarding layout"]
        )
        try shot("record-brief")
        m.brief.reset(isCall: false)
        if windowOnly { m.active = false; m.preview = false; return }
        // the notch: a made-up housing 200 wide in a 32 tall menu bar, and the capsule on a screen without one
        // the notch: recording, then a file converting (42%) and being read (turning arc)
        for (name, notch, prog) in [("notch", CGFloat(200), Double?.none), ("notch-none", 0, nil),
                                    ("notch-file", 200, 0.42), ("notch-file-reading", 200, -1)] {
            let screen = NSRect(x: 0, y: 0, width: 520, height: 60), bar: CGFloat = 32
            let scene = NSView(frame: screen); scene.wantsLayer = true
            scene.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)).cgColor
            let menu = NSView(frame: NSRect(x: 0, y: screen.maxY - bar, width: screen.width, height: bar)); menu.wantsLayer = true
            menu.layer?.backgroundColor = (dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.85, alpha: 1)).cgColor
            scene.addSubview(menu)
            let v = NotchView(frame: NotchPlace.frame(screen: screen, notch: notch, bar: bar))
            v.notch = notch; v.time = prog.map { $0 < 0 ? "…" : String(format: "%.0f%%", $0 * 100) } ?? "12:34"; v.paused = false
            v.progress = prog; v.turn = 1.2
            scene.addSubview(v)
            try UIShots.save(scene, folder + "/" + name + "-" + tag + ".png")
        }
        for (name, notch) in [("offer", CGFloat(200)), ("offer-none", 0)] {
            let screen = NSRect(x: 0, y: 0, width: 620, height: 110), bar: CGFloat = 32
            let scene = NSView(frame: screen); scene.wantsLayer = true
            scene.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)).cgColor
            let menu = NSView(frame: NSRect(x: 0, y: screen.maxY - bar, width: screen.width, height: bar)); menu.wantsLayer = true
            menu.layer?.backgroundColor = (dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.85, alpha: 1)).cgColor
            scene.addSubview(menu)
            let v = NotchOfferView(frame: NotchPlace.offer(screen: screen, notch: notch, bar: bar))
            v.notch = notch; v.bar = bar; v.question = "Record «Weekly sync»?"; v.detail = "Microsoft Teams · with Mila Synthetic, Sava"
            scene.addSubview(v)
            try UIShots.save(scene, folder + "/" + name + "-" + tag + ".png")
        }
        m.active = false; m.preview = false
    }
}
