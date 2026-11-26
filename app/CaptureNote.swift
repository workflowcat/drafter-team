// The capture deck (17 November 2026; the user: "we build a deck of screenshots that are explainable", "I click on
// screenshots and at the same time I can start talking about it"). It replaces the shot strip's one line ("What is
// this?"): after a capture one floating strip shows every picture taken so far as a card, each with its caption under
// it, and a + card. The rules: app/DeckRules.swift.
// Talk: with `captureTalk` on (the default) the mic starts with each shot through the usual voice take (Talk, no second
// recorder); what the user says until the next shot is that card's caption (Talk tags the take with the card, so a take that
// ends late still lands on its own card). A small level shows on the card it listens for. Right ⌥ or the mic button
// stops it, and starts it again for the picked card. Typing edits the picked card's caption (the last one, unless the user
// picked another): one place for the text.
// The deck stays up: ⌘N or + dims the screen for the next shot with the deck still showing above it. A click on a card
// picks it; its buttons retake (⌘R), mark up (⌘E, app/Markup.swift) and take it out (⌘⌫); dragging a card reorders the
// deck (⌘⇧← ⌘⇧→ on the keyboard). Dragging the strip by its background moves it, and the place is kept (`deckAt`).
// Round 2 (docs/rounds/2026-11-17-deck.md): one row of actions under the cards, [Cancel esc] … [Mark up ⌘E]
// [Next shot ⌘N] … [Send to… ⇥] [Put in ↵]. ↵ ends the take, waits for its words, and puts the deck in, each card as
// one unit: its picture, then its caption (an agent app: the pictures, then "Screenshots attached: N pictures" with a
// caption under each). Every picture goes on the clipboard as PNG, TIFF and its file URL and stays there 1.6 s
// (ShotSend.paste). ⇥ turns the row into the targets (ShotPack.order, digits); Person into a name field and
// the chats found (beeper, read only; the draft is never sent). Esc only cancels: it stops the caption take, else
// drops the shot (Undo for 10 s, then the pack goes to the Trash). It never sends or keeps.
// Every change (a caption, the marks, the order, a send) is written into its pack off the main thread (ShotStore).
// Keys come through the event tap (Quick.tap); the strip never becomes key. ⌘ chords the deck does not use
// (DeckRules.takes) go on to the app below; ⌘↵ is ↵.
import AppKit
import QuartzCore

final class CaptureNote {
    static let shared = CaptureNote()
    enum Mode { case note, list, person }
    /// One card of the deck: the picture as it goes (marked), as taken, its marks, its caption, where it was on the screen.
    struct Pic {
        var id = UUID()
        var png: Data
        var original: Data? = nil
        var marks: [PicMark] = []
        var shot: ShotPicture
        var caption = ""
        var region: NSRect? = nil      // AppKit screen points
        var full = false               // a whole screen
        var inPlace = false            // its region is still on the screen as taken: ⌘E marks up in place
        var thumb: NSImage?
    }
    private(set) var isOpen = false
    /// The screen is dimmed for the next shot (⌘N, +) or a retake; the deck stays up over it.
    private(set) var collecting = false
    private var retakeAt: Int?
    var mode = Mode.note
    var line = ""                              // the name being searched (person mode)
    var note = ""                              // older sets: the one note for the whole set (kept as it was)
    var noteVia = "typed"
    var pics: [Pic] = []
    var picked: Int?                           // the card typing and ⌘E go to (nil: the last)
    var hover: Int?                            // the button under the mouse (ShotRules.StripButton raw value)
    var hoverCard: Int?                        // the card under the mouse (its buttons show)
    var pack: ShotPack?
    var list: [ShotTarget] = []
    var chats: [(id: String, title: String)] = []
    var searching = false
    var sel = 0
    /// The card the voice take is for, and the mic's last levels (DeckRules.level), newest last.
    var listeningFor: UUID?
    var levels: [CGFloat] = []
    var heardLive = ""                         // the take's words so far (shown faint under its card)
    private var openFront = "?", openAsks = 0  // the app with the keys at deck open, accessibility asks then
    private var origin: NSRunningApplication?
    private var t0 = Date()
    private var readDone = true
    private var waiting: [() -> Void] = []
    private var searchGen = 0
    private var card = NSRect.zero              // the deck's card on the screen (AppKit points)
    private var placed = false                  // placed once since it opened: later sizes regrow round it
    private var growsDown = false               // round 5: the column's top stays (it grows down), else its bottom
    private var tick: Timer?
    let panel: NSPanel
    let view = HandView()
    let preview = HandPreview()

    /// The first picture (one-picture code paths).
    var png: Data { pics.first?.png ?? Data() }
    var pngs: [Data] { pics.map(\.png) }
    /// The card typing, the mic and ⌘E go to.
    var current: Int? { DeckRules.target(picked: picked, count: pics.count) }
    /// Round 4 "Hand": the deck never takes the user's keys (DeckRules.takesKeys); their voice is a card's caption only while that
    /// card's mic opens the take (DeckRules.handVoice). Every other take is the user's app's.
    private var micOpening = false
    /// Round 4b: one insert at a time (DeckRules.mayInsert); its number, so a late answer of an older one is ignored.
    private(set) var inserting = false
    private var insertGen = 0
    /// The card the row acts on (DeckRules.selected): the one the user clicked, else the newest.
    var selectedIndex: Int? { DeckRules.selected(picked, count: pics.count) }
    /// The app the deck was last placed for (re-placed when the user switches to another app on another screen).
    private var switchToken: NSObjectProtocol?
    var takesVoice: Bool { DeckRules.handVoice(open: isOpen, micOpening: micOpening) }
    /// A caption take listening for one of the deck's cards: the deck's only active state.
    var captionOn: Bool { listeningFor != nil && Talk.shared.state == .listening && Talk.shared.toNote }

    init() {
        panel = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true   // round 4c: the one shadow, the panel's own (HandView draws none)
        // over the dimmed screen too: the deck stays in sight while the user takes the next shot (a CapturePanel: never in a picture)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none   // AppKit's own fade kept a closed deck on screen ~0.38 s (app/DeckBench.swift)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.model = self; panel.contentView = view
    }

    static func pic(_ png: Data, region: NSRect?, full: Bool, inPlace: Bool) -> Pic {
        let size = NSBitmapImageRep(data: png).map { ($0.pixelsWide, $0.pixelsHigh) } ?? (0, 0)
        return Pic(png: png, shot: ShotPicture(file: "", width: size.0, height: size.1), region: region, full: full, inPlace: inPlace, thumb: NSImage(data: png))
    }

    /// The deck after a capture. `pack`: the shot as written at capture (nil in the previews); its text is read here,
    /// once. `region`: where it was taken (screen points), `full` a whole screen; `inPlace`: a dragged region (⌘E then
    /// marks it up in place). `talk`: start the mic for this card (`captureTalk`).
    func open(png: Data, row: [String: Any], origin: NSRunningApplication?, t0: Date, pack: ShotPack? = nil,
              region: NSRect? = nil, full: Bool = false, inPlace: Bool = false, talk: Bool = false) {
        let mark = Speed.begin(.deckOpen, from: t0)
        self.origin = origin; self.t0 = t0; line = ""; note = ""; noteVia = "typed"; collecting = false; retakeAt = nil
        openFront = Capture.keyApp()?.bundleIdentifier ?? "?"; openAsks = Focus.asks   // for the put-in's front line
        self.pack = pack; mode = .note; chats = []; sel = 0; searching = false; picked = nil; hover = nil; hoverCard = nil
        listeningFor = nil; levels = []; heardLive = ""; placed = false; keysSinceOpen = 0; view.reset()
        pics = [Self.pic(png, region: region, full: full, inPlace: inPlace)]
        readDone = pack == nil; waiting = []
        if let id = pack?.id { readPicture(png, id: id, first: true) }
        show()
        log("capture: deck open, \(Int(Date().timeIntervalSince(t0) * 1000)) ms after release")
        mark.drawn("from the release")
    }

    private func readPicture(_ png: Data, id: String, first: Bool) {
        if !first { readDone = false }
        ShotStore.read(png) { text, found in
            guard self.pack?.id == id else { ShotStore.update(id) { $0.read += (first ? "" : "\n") + text; $0.found += found }; return }
            if var p = self.pack {
                p.read = first || p.read.isEmpty ? text : p.read + "\n" + text
                p.found = Array((p.found + found).prefix(20))
                self.pack = p
            }
            self.readDone = true
            self.save()
            let w = self.waiting; self.waiting = []; w.forEach { $0() }
        }
    }

    /// A deck from the journal again: its pack and pictures from data/shots/<id>/, every caption as it was; then the
    /// deck (or markup over the first picture with the kept marks). ↵ goes to the app that was in front before Drafter's window.
    func reopen(_ p: ShotPack, folder: URL, markup mark: Bool) {
        var loaded: [Pic] = []
        for (i, sp) in p.pics.enumerated() {
            guard let d = try? Data(contentsOf: folder.appendingPathComponent(ShotPack.pictureFile(i))) else { continue }
            var pc = Self.pic(d, region: nil, full: false, inPlace: false)
            pc.shot = sp
            pc.caption = sp.caption ?? ""
            if let o = try? Data(contentsOf: folder.appendingPathComponent(ShotPack.originalFile(i))) {
                pc.original = o; pc.marks = Markup.picMarks(sp.marks, crop: sp.crop)
            }
            loaded.append(pc)
        }
        guard !loaded.isEmpty else { Pill.shared.flash("The shot's picture is gone"); return }
        if isOpen { close() }
        open(png: loaded[0].png, row: ["kind": "image", "shot": p.id], origin: Capture.keyApp(), t0: Date(), pack: p)
        pics = loaded
        note = loaded.count > 1 ? p.note : ""; noteVia = p.noteVia
        log("shot: again, \(mark ? "markup" : "deck"), \(pics.count) pictures")
        if mark { markup(0); return }
        resize()
    }

    /// A spot off every screen for the deck bench (app/DeckBench.swift); nil in use.
    static var benchAt: NSPoint?

    /// The closed deck drawn once off every screen, as it stands: its code, fonts and window store paged in before the
    /// next open (at launch, and when the capture overlay opens: the user drags for half a second or more). Changes nothing.
    func prewarm() {
        guard !isOpen else { return }
        let f = panel.frame
        panel.alphaValue = 0
        panel.setFrame(NSRect(x: -12000, y: -12000, width: max(f.width, 200), height: max(f.height, 120)), display: false)
        panel.orderFrontRegardless()
        view.needsDisplay = true
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.setFrame(f, display: false)
        panel.alphaValue = 1
    }

    /// The deck goes from the screen (the pack is already written). A take still running lands on its card when it ends.
    func close() {
        let mark = Speed.begin(.deckClose)
        defer { mark.drawn() }
        isOpen = false; collecting = false; retakeAt = nil
        tick?.invalidate(); tick = nil
        view.layer?.removeAllAnimations()   // no motion on close (DeckRules.closeSeconds)
        view.stopMotion(); preview.hide(); stopWatchingSwitches()
        panel.orderOut(nil)
    }

    /// The pack written again: the pictures in deck order (when given), every caption, shot.json / shot.md.
    private func save(pictures: Bool = false) {
        guard var p = pack else { return }
        p.noteVia = noteVia
        p.setPictures(pics.enumerated().map { i, pc in
            var s = pc.shot; s.original = pc.original == nil ? nil : "x"
            s.caption = pc.caption.isEmpty ? nil : pc.caption
            return s
        })
        // a set's captions are under its pictures; an older set's one note stays as it was
        p.note = pics.count == 1 ? pics[0].caption : note
        pack = p
        if pictures { ShotStore.writeSet(p, pngs: pngs, originals: pics.map(\.original)) }
        else { ShotStore.write(p) }
    }

    /// `f` once the pictures' text is read (at most 2 s later; then without it).
    private func withRead(_ f: @escaping () -> Void) {
        if readDone { f(); return }
        var done = false
        let once = { if !done { done = true; f() } }
        waiting.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once() }
    }

    // MARK: where it sits

    // MARK: ↵ inserts all, until the user types (round 4c, DeckRules.returnInserts)

    /// Keys that went to the user's app since the deck opened or since the last card was added (Keys counts them).
    private(set) var keysSinceOpen = 0
    /// The deck is up and an Insert all could start now.
    var returnReady: Bool {
        isOpen && !collecting && !inserting && !pics.isEmpty && pack != nil && !Capture.shared.isOpen && !MarkupEditor.shared.isOpen
    }
    /// ↵ still inserts all: Insert all shows ↵.
    var returnHint: Bool { returnReady && keysSinceOpen == 0 }
    /// A key went to the user's app (from the key tap, on the main thread): after the first, ↵ is their app's and the hint goes.
    func keyInApp() {
        keysSinceOpen += 1
        if keysSinceOpen == 1 { DispatchQueue.main.async { if self.isOpen { self.refit(); self.view.needsDisplay = true } } }
    }

    private func show() {
        isOpen = true
        watchSwitches()
        place()
        view.needsDisplay = true
        panel.orderFrontRegardless()
        arrive()
        if tick == nil {
            // the mic's state can end without words (no callback): the deck looks again 4 times a second
            tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.watchTalk() }
        }
    }

    /// Round 3: a short arrival by Core Animation (the main thread stays free); none with Reduce motion, none in the bench.
    private func arrive() {
        guard Self.benchAt == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        view.wantsLayer = true
        guard let l = view.layer else { return }
        let b = view.bounds, k = DeckRules.arriveScale
        var t = CATransform3DMakeTranslation(b.midX, b.midY - DeckRules.arriveRise, 0)   // starts a little lower
        t = CATransform3DScale(t, k, k, 1)
        t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: t); move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        let g = CAAnimationGroup()
        g.animations = [move, fade]; g.duration = DeckRules.arriveSeconds
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(g, forKey: "arrive")
    }

    private func setCard(_ c: NSRect) {
        card = c
        panel.setFrame(c, display: true)
        view.needsDisplay = true
    }

    private var screens: [CGRect] { NSScreen.screens.map(\.visibleFrame) }
    private var mouseScreen: CGRect {
        let m = NSEvent.mouseLocation
        return (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Round 5 "Stack": once, when it opens: next to the caret of the field the user was in; no caret, that field's top-left
    /// line; neither, the mouse pointer; whole on that screen (DeckRules.placeStack). Then it stays put.
    private func place() {
        view.maxH = .greatestFiniteMagnitude
        let size = view.fit()
        if let at = Self.benchAt { setCard(NSRect(origin: at, size: size)); placed = true; return }
        let ax = Capture.shared.caretAX, mainH = NSScreen.screens.first?.frame.height ?? 900
        let caret = ax.caret.map { DeckRules.appKit(ax: $0, mainHeight: mainH) }, field = ax.field.map { DeckRules.appKit(ax: $0, mainHeight: mainH) }
        let m = NSEvent.mouseLocation
        let spot = caret ?? field.map { CGRect(x: $0.minX + 12, y: $0.maxY - 26, width: 2, height: 18) } ?? CGRect(x: m.x, y: m.y - 9, width: 1, height: 18)
        let scr = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: spot.midX, y: spot.midY)) }?.visibleFrame ?? mouseScreen
        let p = DeckRules.placeStack(size, spot: spot, screen: scr)
        growsDown = p.growsDown; view.maxH = p.maxH
        view.fit()
        setCard(p.frame)
        placed = true
        log("capture: deck at the \(caret != nil ? "caret" : field != nil ? "field" : "mouse"), grows \(growsDown ? "down" : "up")")
    }

    /// A card added or taken out: the hand fits again and redraws.
    private func resize() {
        guard placed else { place(); return }
        view.cardsChanged()
    }
    /// The column fits its shots again: the edge that stays, stays (DeckRules.restack); past its room it scrolls.
    /// It never moves to stay on the screen: it was placed whole, and its room was measured then (or after the user's drag).
    func refit() {
        guard isOpen, placed else { return }
        let size = view.fit()
        guard size != card.size, Self.benchAt == nil else { return }
        setCard(DeckRules.restack(card, height: size.height, growsDown: growsDown))
    }

    // MARK: talk

    /// The mic for a card: a voice take tagged with it (Talk.noteCard). A take still reading the last words: once it is done.
    func startTalk(for id: UUID, force: Bool = false, tries: Int = 0) {
        guard isOpen, Drafter.shared.settings.captureTalk || force else { return }
        let t = Talk.shared
        if t.state != .idle {
            guard tries < 40 else { log("shot: talk not started, the voice take is busy"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.startTalk(for: id, force: force, tries: tries + 1) }
            return
        }
        guard pics.contains(where: { $0.id == id }) else { return }
        // round 4: only this mic opens a deck take (DeckRules.handVoice); the user's own voice key stays their app's
        listeningFor = id; levels = []; heardLive = ""
        t.clock = Clock(press: Date())
        micOpening = true; t.begin(); micOpening = false
        if t.state != .listening || !t.toNote { listeningFor = nil }
        log("shot: caption take \(listeningFor == nil ? "not started" : "on")")
        view.needsDisplay = true
    }
    /// A card's mic: its caption take on, or (on again) off; the user's words land on that card. Another card's take ends
    /// first (its words land there).
    func micTap(_ i: Int) {
        guard pics.indices.contains(i) else { return }
        let t = Talk.shared, id = pics[i].id
        if t.state == .listening, t.toNote {
            let was = listeningFor
            t.end()
            if was == id { view.needsDisplay = true; return }
        }
        startTalk(for: id, force: true)   // asked for: even with `captureTalk` off
    }
    /// The card a take starting now belongs to (Talk.begin).
    func voiceCard() -> UUID? {
        if let l = listeningFor { return l }
        return current.map { pics[$0].id }
    }
    /// One stretch of the mic while a deck take listens.
    func level(_ peak: Float) {
        levels.append(DeckRules.level(peak: peak)); if levels.count > 8 { levels.removeFirst(levels.count - 8) }
        let live = Talk.shared.lastDraft
        if live != heardLive { heardLive = live }
        if isOpen { view.needsDisplay = true; preview.refresh() }
    }
    private func watchTalk() {
        let t = Talk.shared
        if listeningFor != nil, !(t.state == .listening && t.toNote) { listeningFor = nil; levels = []; heardLive = ""; view.needsDisplay = true }
    }
    /// The take's words (Talk, when it ends): onto the card it was for; nil (an older take): the current card.
    func heard(_ text: String, card id: UUID? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if listeningFor == id || id == nil { listeningFor = nil; levels = []; heardLive = "" }
        guard !t.isEmpty else { view.needsDisplay = true; preview.refresh(); return }
        guard let i = id.flatMap({ id in pics.firstIndex { $0.id == id } }) ?? current else { return }
        pics[i].caption = DeckRules.add(t, to: pics[i].caption)
        noteVia = "voice"
        save()
        view.needsDisplay = true; preview.refresh()
        log("shot: caption by voice, card \(i + 1), \(t.count) chars")
    }
    /// `f` once no deck take is running: a take still listening is ended first and its words land (at most 6 s).
    private func afterTalk(_ f: @escaping () -> Void) {
        let t = Talk.shared
        // only the deck's own caption take is waited for (DeckRules.waitsForTalk): a take in another app is not the deck's
        let mine = DeckRules.waitsForTalk(idle: t.state == .idle, deckTake: t.toNote)
        if t.state == .listening, t.toNote { t.end() }
        guard mine else { f(); return }
        var n = 0
        func wait() {
            if Talk.shared.state == .idle || n >= 60 { f(); return }
            n += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait() }
        }
        wait()
    }

    // MARK: focus (round 4: the deck never takes the user's keys)

    /// A mouse down anywhere (the event tap): outside the deck a caption take ends (its words land on its card).
    func clicked(at p: NSPoint) {
        guard isOpen, captionOn, !collecting, !Capture.shared.isOpen, !MarkupEditor.shared.isOpen else { return }
        if DeckRules.endsCaption(clickInside: panel.frame.contains(p), onMic: false) {
            Talk.shared.end()
            log("shot: caption take ended (click outside)")
        }
    }
    /// ⌘P: the card's picture floats on the screen (app/Pin.swift); the deck stays as it is.
    func pin(_ i: Int) {
        guard pics.indices.contains(i) else { return }
        Pins.pin(pics[i].png, region: pics[i].inPlace ? pics[i].region : nil)
    }
    /// A card dragged to another place in the deck.
    func move(_ from: Int, to: Int) {
        guard pics.indices.contains(from), from != to else { return }
        let cur = current ?? from
        pics = DeckRules.move(pics, from: from, to: to)
        picked = DeckRules.picked(after: from, to: to, picked: cur, count: pics.count)
        save(pictures: true)
        view.cardsChanged()
        log("shot: card \(from + 1) moved to \(min(to, pics.count - 1) + 1)")
    }

    // MARK: round 4b: select, insert, drop with Undo, close

    /// A card clicked: it is selected (it comes to the top of the fan); nothing is inserted.
    func select(_ i: Int) {
        guard pics.indices.contains(i), picked != i else { return }
        picked = i
        view.cardsChanged()
        log("shot: card \(i + 1) of \(pics.count) selected")
    }
    /// Insert this: the selected card alone, the rest stay. The last card: all of it, and the deck closes.
    func putOne(_ i: Int) {
        switch DeckRules.putOne(i, count: pics.count) {
        case .all?: putIn()
        case .one(let k)?: putIn(only: k)
        case nil: break
        }
    }
    /// Insert all: every card in deck order; the deck closes.
    func putAll() { putIn() }
    /// Round 5: a shot (or every shot) onto the clipboard as pictures (and files once written), its caption as text.
    func copyOne(_ i: Int) {
        guard pics.indices.contains(i) else { return }
        copy([i])
    }
    func copyAll() { copy(Array(pics.indices)) }
    private func copy(_ ix: [Int]) {
        guard !ix.isEmpty else { return }
        let urls = pack.map { ShotSend.pictureURLs($0.id, count: pics.count) } ?? []
        let text = ix.map { pics[$0].caption }.filter { !$0.isEmpty }.joined(separator: "\n")
        ShotSend.clipboard(ix.map { pics[$0].png }, urls: ix.compactMap { urls.indices.contains($0) ? urls[$0] : nil }, text: text)
        Pill.shared.flash(ix.count > 1 ? "\(ix.count) shots copied" : "Shot copied")
        log("shot: copied \(ix.count) of \(pics.count)")
    }
    /// Drop: the selected card leaves the deck, "Card dropped · Undo" in the pill for 10 s. The last card: the whole
    /// shot is dropped (its own Undo).
    func dropOne(_ i: Int) {
        guard pics.indices.contains(i) else { return }
        if pics.count == 1 { dropAll(); return }
        let card = pics[i], id = pack?.id
        remove(i)
        Pill.shared.flash("Card dropped", button: StripButton("Undo", key: "", style: .primary) { [weak self] in
            guard let self, self.isOpen, self.pack?.id == id, !self.pics.contains(where: { $0.id == card.id }) else { return }
            let at = DeckRules.backAt(i, count: self.pics.count)
            self.pics.insert(card, at: at); self.picked = at
            self.save(pictures: true); self.view.cardsChanged()
            log("shot: card drop undone")
        })
    }
    /// Every card dropped (a caption take first, without its words); Undo in the pill for 10 s.
    func dropAll() {
        let t = Talk.shared
        if t.state == .listening, t.toNote { t.cancel(); listeningFor = nil; levels = []; heardLive = "" }
        cancel()
    }
    /// The x at the fan's top right: the deck goes without dropping anything; the pack stays in the journal. A caption
    /// take ends first (its words land on its card). No motion.
    func dismiss() {
        let t = Talk.shared
        if t.state == .listening, t.toNote { t.end() }
        SwitchWatch.shared.stop()
        close()
        log("shot: deck closed, \(pics.count) pictures kept in the journal")
    }
    /// The grip above the fan: the deck moved by the mouse's steps, for this deck only (nothing is saved).
    func drag(by dx: CGFloat, _ dy: CGFloat) {
        setCard(card.offsetBy(dx: dx, dy: dy))
    }
    /// The drag ended: the room from the edge that stays is measured again where the user dropped it.
    func dragEnded() {
        let scr = (NSScreen.screens.first { $0.frame.intersects(card) } ?? NSScreen.main)?.visibleFrame ?? card
        view.maxH = DeckRules.stackRoom(card, growsDown: growsDown, screen: scr)
        refit()
    }
    /// The user switched to another app while the deck is up: its caret (read off main) decides; the deck moves only when
    /// that is on another screen than the deck.
    private func watchSwitches() {
        if let t = switchToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        switchToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.isOpen, !self.collecting, Self.benchAt == nil,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != getpid() else { return }
            Capture.readCaret(app) { at in
                guard self.isOpen, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                let mainH = NSScreen.screens.first?.frame.height ?? 900
                let caret = at.caret.map { DeckRules.appKit(ax: $0, mainHeight: mainH) }, field = at.field.map { DeckRules.appKit(ax: $0, mainHeight: mainH) }
                let spot = caret ?? field
                let there = spot.flatMap { r in NSScreen.screens.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) } }
                    ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                let here = NSScreen.screens.first { $0.frame.intersects(self.card) }
                guard let there, there != here else { return }
                // round 5: the deck stays put for the whole session (the user: "it must not wander"); only logged
                log("shot: front app \(app.bundleIdentifier ?? "?") on another screen, the deck stays")
            }
        }
    }
    private func stopWatchingSwitches() {
        if let t = switchToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        switchToken = nil
    }

    // MARK: the next shot, a retake, taking one out

    /// ⌘N or +: the screen dims again with the deck still up; the next capture joins it (`append`), esc goes back.
    func addAnother() {
        guard pack != nil, !collecting else { return }
        if mode != .note { mode = .note; chats = []; resize() }
        save()
        collecting = true; retakeAt = nil
        log("shot: next shot, \(pics.count) so far")
        DispatchQueue.main.async { Capture.shared.open() }
    }
    /// ⌘R or the card's button: that card's picture taken again, its caption kept.
    func retake(_ i: Int) {
        guard pack != nil, pics.indices.contains(i), !collecting else { return }
        save()
        collecting = true; retakeAt = i
        log("shot: retake card \(i + 1)")
        DispatchQueue.main.async { Capture.shared.open() }
    }
    /// The capture was dropped while collecting (Capture.close): the deck as it was.
    func resume() {
        guard collecting else { return }
        collecting = false; retakeAt = nil
        view.needsDisplay = true
    }
    /// The next picture of the deck, or a card taken again. A new card ends the take for the last one (its words land
    /// there) and starts one for itself.
    func append(png: Data, region: NSRect?, full: Bool, inPlace: Bool) {
        collecting = false; keysSinceOpen = 0
        for k in pics.indices { pics[k].inPlace = false }   // only the newest picture is still on the screen as taken
        let pc = Self.pic(png, region: region, full: full, inPlace: inPlace)
        if let i = retakeAt, pics.indices.contains(i) {
            retakeAt = nil
            var p = pics[i]
            p.png = pc.png; p.thumb = pc.thumb; p.shot = pc.shot; p.region = region; p.full = full; p.inPlace = inPlace
            p.original = nil; p.marks = []
            pics[i] = p
            save(pictures: true)
            log("shot: card \(i + 1) taken again")
            resize()
            return
        }
        retakeAt = nil
        pics.append(pc)
        picked = nil
        save(pictures: true)
        if let id = pack?.id { readPicture(png, id: id, first: false) }
        log("shot: picture \(pics.count) added")
        resize()
        view.flyIn(pc.id)   // round 4: the new shot flies onto the fan (DeckRules.flySeconds)
    }
    private func remove(_ i: Int) {
        guard pics.count > 1, pics.indices.contains(i) else { return }
        preview.hide()
        let cur = current ?? i
        if listeningFor == pics[i].id, Talk.shared.state == .listening { Talk.shared.cancel(); listeningFor = nil }
        pics.remove(at: i)
        picked = DeckRules.picked(afterRemoving: i, picked: cur, count: pics.count + 1)
        if picked == pics.count - 1 { picked = nil }
        save(pictures: true)
        resize()
        log("shot: card taken out, \(pics.count) left")
    }

    // MARK: markup

    func markup(_ i: Int) {
        guard pics.indices.contains(i) else { return }
        panel.orderOut(nil)
        let pc = pics[i]
        let scr = pc.region.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.screens.first { $0.frame.intersects(panel.frame) }
        // in place only where the picture still is on the screen: the newest region capture
        let region = pc.inPlace ? pc.region : nil
        MarkupEditor.shared.open(pc.original ?? pc.png, near: scr, marks: pc.marks, region: region) { marked in
            if let marked, self.pics.indices.contains(i) {
                // the marked picture is the one that goes in; the capture stays on the tape as it was
                let m = MarkupEditor.shared.model
                var p = self.pics[i]
                if p.original == nil { p.original = p.png }
                p.marks = m.marks
                let size = NSBitmapImageRep(data: marked).map { ($0.pixelsWide, $0.pixelsHigh) } ?? (0, 0)
                _ = History.addPicture(marked, width: size.0, height: size.1, app: self.origin?.localizedName ?? "", shot: self.pack?.id)
                p.png = marked; p.thumb = NSImage(data: marked)
                p.shot.marks = m.shotMarks; p.shot.crop = m.shotCrop; p.shot.width = size.0; p.shot.height = size.1
                p.inPlace = false   // marked once: ⌘E again opens the panel over the original
                self.pics[i] = p
                self.save(pictures: true)
                log("shot: marked, \(m.marks.count) marks")
            } else if self.pics.indices.contains(i) {
                self.pics[i].inPlace = false
            }
            guard self.isOpen else { return }
            self.panel.orderFrontRegardless(); self.view.needsDisplay = true
            if MarkupEditor.shared.addAfter { self.addAnother() }
        }
    }

    // MARK: ↵ the deck in, esc cancel

    /// ↵ (⌘↵ the same): the take's last words first, then the whole deck by the field's kind (ShotPack.fieldPut).
    /// No field that takes it: all of it on the clipboard.
    /// `only` (round 4b, Insert this): that card alone; the rest stay on the deck. One insert at a time (no double
    /// paste). The card leaves the fan at once; a failed or unsure paste brings it back (Insert all: the deck again).
    private func putIn(only: Int? = nil) {
        guard let p0 = pack else { close(); return }
        guard DeckRules.mayInsert(busy: inserting, count: pics.count) else { log("shot: insert already running, press ignored"); return }
        let tEnter = Date()
        let atEnter = Capture.keyApp()?.bundleIdentifier ?? "?"
        // its picture file as written now (the files are rewritten only once it went in)
        let allURLs = ShotSend.pictureURLs(p0.id, count: pics.count)
        let one: (k: Int, card: Pic, url: URL?)? = only.flatMap { pics.indices.contains($0) ? ($0, pics[$0], allURLs.indices.contains($0) ? allURLs[$0] : nil) : nil }
        if only != nil, one == nil { return }
        inserting = true
        let gen = insertGen + 1; insertGen = gen
        // never stuck: a check that never answers frees the buttons after 15 s
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in if self?.insertGen == gen { self?.inserting = false } }
        if let one {
            preview.hide()
            pics.remove(at: one.k); picked = nil
            view.cardsChanged()
        } else { close() }
        let atClose = Capture.keyApp()?.bundleIdentifier ?? "?", openFront = self.openFront, openAsks = self.openAsks
        let goneMs = Int(Date().timeIntervalSince(tEnter) * 1000)
        if one == nil { save() }
        /// The insert ended: in (the card stays out; the files follow the deck), or not (the card back where it was;
        /// Insert all: the deck up again with every card).
        let finish = { (ok: Bool) in
            guard self.insertGen == gen else { return }
            self.inserting = false
            guard self.pack?.id == p0.id else { return }
            if let one {
                if ok { self.save(pictures: true) }
                else if !self.pics.contains(where: { $0.id == one.card.id }) {
                    self.pics.insert(one.card, at: DeckRules.backAt(one.k, count: self.pics.count))
                    self.picked = DeckRules.backAt(one.k, count: self.pics.count - 1)
                    if self.isOpen { self.view.cardsChanged() }
                    log("shot: insert this did not land, the card is back")
                }
            } else if !ok, !self.isOpen {
                self.show()
                log("shot: insert all did not land, the deck is back")
            }
        }
        // a shot that recorded Drafter as its app (an older deck, or nothing else known): the app the user is in now
        let id = p0.id, shotIn = self.origin?.processIdentifier == getpid() ? Capture.keyApp() : self.origin
        afterTalk {
            // where it goes (PutRules.goesHere): the app the user moved to themselves, else the app the shot was taken in
            let moved = SwitchWatch.shared.moved
            if one == nil { SwitchWatch.shared.stop() }   // one card: the deck stays up, the watch goes on
            let here = Capture.keyApp(), toHere = PutRules.goesHere(front: PutBack.front(shotIn), moved: moved)
            let origin = toHere ? here : shotIn
            if toHere { log("shot: the user moved to \(here?.bundleIdentifier ?? "?") themselves, put in there (shot in \(shotIn?.bundleIdentifier ?? "?"))") }
            let way = ShotPack.fieldWay(bundle: origin?.bundleIdentifier ?? "", ai: Keys.aiApps)
            // the screen read only where the put-in uses it (DeckRules.waitsForRead): a terminal's shot.md
            let read: (@escaping () -> Void) -> Void = DeckRules.waitsForRead(terminal: way == .terminal) ? self.withRead : { $0() }
            read {
                guard var p = self.pack, p.id == id else { finish(false); return }
                var pngs = self.pngs, urls = ShotSend.pictureURLs(id, count: pngs.count)
                var path = ShotStore.pngURL(id).path
                if let one {
                    // one card: a pack of just it (its picture file, its caption)
                    var sh = one.card.shot; sh.caption = one.card.caption.isEmpty ? nil : one.card.caption
                    p.setPictures([sh]); p.note = one.card.caption
                    pngs = [one.card.png]; urls = one.url.map { [$0] } ?? []
                    path = urls.first?.path ?? path
                }
                let put = p.fieldPut(way, path: path, md: ShotStore.mdURL(id).path)
                let steps = DeckRules.steps(captions: p.captions, agent: way == .agent, pictures: put.picture,
                                            agentText: way == .other ? "" : (put.text ?? ""))
                let whyNot: () -> String? = {
                    way == .terminal ? (Capture.terminalTarget(origin) ? nil : "terminal not in front") : Capture.targetWhyNot(origin)
                }
                let clip = { put.picture ? ShotSend.clipboard(pngs, urls: urls, text: put.text ?? "") : History.copy(put.text ?? "") }
                let go = {
                    // where it goes, read again after the paste (PutBack.check): "sent to field" only when it still looks right
                    let target = Capture.keyApp(), before = PutBack.before(target), tGo = Date()
                    if steps.count > 1 { Pill.shared.show("Inserting…", seconds: 10) }
                    ShotSend.paste(steps: steps, pngs: pngs, urls: urls, pasted: {
                        if steps.count > 1 { Pill.shared.hide() }
                        let ms = { (d: Date) in Int(d.timeIntervalSince(tEnter) * 1000) }
                        log("shot: put in timing: deck gone \(goneMs) ms, first paste \(ms(tGo)) ms, last paste \(ms(Date())) ms after ↵, \(steps.count) steps")
                    }) {
                        PutBack.check(target, windowsBefore: before, who: "shot", after: 0,
                                      field: way == .terminal ? { Capture.terminalTarget(target) } : nil, clip: clip, failed: { finish(false) }) {
                            if one == nil { ShotStore.sent(id, .field) }
                            finish(true)
                            log("shot: deck put in (\(way)) to \(target?.bundleIdentifier ?? "?"), \(pngs.count) pictures, \(p.captions.filter { !$0.isEmpty }.count) captions, \(put.text?.count ?? 0) chars, \(Int(Date().timeIntervalSince(self.t0) * 1000)) ms after the first shot")
                        }
                    }
                }
                let fail = { (why: String) in
                    clip()
                    Pill.shared.flash(!put.picture ? "Text on the clipboard · ⌘V to paste"
                                      : why.hasPrefix("front app moved") ? PutBack.movedPill(origin, what: "Pictures and captions on the clipboard")
                                      : "Pictures and captions on the clipboard")
                    finish(false)
                    log("shot: put in failed (\(why)), origin \(origin?.bundleIdentifier ?? "?"), front \(Capture.keyApp()?.bundleIdentifier ?? "?"), on the clipboard")
                }
                let why = whyNot()
                // the front app at each point, and accessibility asks while the deck was up (17 November 2026: lost shots)
                log("shot: put in fronts: deck open \(openFront), ↵ \(atEnter), deck closed \(atClose), now \(Capture.keyApp()?.bundleIdentifier ?? "?"), shot in \(shotIn?.bundleIdentifier ?? "?"), to \(origin?.bundleIdentifier ?? "?"), accessibility asks +\(Focus.asks - openAsks), switch by \(moved)")
                switch PutRules.way(why: why, targetAlive: PutBack.alive(origin), moved: moved) {
                case .go: go()
                case .clipboard: fail(why.map { $0 == "front app moved" ? "\($0) by \(moved)" : $0 } ?? "")
                case .bringBack:
                    // Drafter, or a switch the user did not make, took the front while the user talked: their app back once, then
                    // retry. Never over an app the user moved to themselves.
                    if why == "front app moved" { log("shot: \(Capture.keyApp()?.bundleIdentifier ?? "?") came to the front without the user's input, origin brought back") }
                    origin?.activate()
                    // ready as soon as it holds the keys and a field (was a fixed 0.35 s): every 50 ms, 1 s at most
                    let t1 = Date()
                    func poll(_ left: Int) {
                        if whyNot() == nil { log("shot: origin brought back for put in, \(Int(Date().timeIntervalSince(t1) * 1000)) ms"); go(); return }
                        guard left > 0 else { fail("\(why ?? ""), then \(whyNot() ?? "")"); return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(left - 1) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(19) }
                }
            }
        }
    }

    /// esc, Cancel: only cancels (round 2, the user). The mic listening: this caption take stops and its words are
    /// dropped (the caption keeps what it had). Else the shot is dropped: the deck goes, Undo in the pill for 10 s,
    /// then the pack goes to the Trash. Never sends, never keeps.
    private func cancel() {
        let t = Talk.shared
        if t.state == .listening, t.toNote {
            t.cancel(); listeningFor = nil; levels = []; heardLive = ""
            view.needsDisplay = true
            log("shot: caption take cancelled")
            return
        }
        SwitchWatch.shared.stop()
        guard let id = pack?.id else { close(); return }
        close()
        dropped = id
        Pill.shared.flash(pics.count > 1 ? "\(pics.count) pictures dropped" : "Shot dropped",
                          button: StripButton("Undo", key: "", style: .primary) { [weak self] in self?.undoDrop(id) })
        log("shot: dropped, \(pics.count) pictures")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.dropped == id else { return }
            self.dropped = nil
            ShotStore.queue.async { try? FileManager.default.trashItem(at: ShotStore.folder(id), resultingItemURL: nil) }
        }
    }
    private var dropped: String?
    private func undoDrop(_ id: String) {
        guard dropped == id, pack?.id == id, !isOpen else { return }
        dropped = nil
        mode = .note
        show()
        log("shot: drop undone")
    }

    // MARK: ⇥ the send-to list

    private func pick(_ t: ShotTarget) {
        guard let p0 = pack else { return }
        if t == .person {
            mode = .person; line = ""; chats = []; sel = 0; searching = false; resize(); return
        }
        close(); save()
        let id = p0.id
        afterTalk {
            self.withRead {
                let pngs = self.pngs, urls = ShotSend.pictureURLs(id, count: pngs.count)
                let p = self.pack?.id == id ? self.pack! : p0
                let path = ShotStore.pngURL(id).path, md = ShotStore.mdURL(id).path
                switch t {
                case .clipboard:
                    ShotSend.clipboard(pngs, urls: urls, text: p.agentText(path: path, screenText: false))
                    Pill.shared.flash(pngs.count > 1 ? "\(pngs.count) pictures and the text on the clipboard" : "Picture and text on the clipboard")
                    ShotStore.sent(id, t)
                case .file:
                    // the pictures are written on the shots queue: copy after them
                    ShotStore.queue.async {
                        DispatchQueue.main.async {
                            guard let name = ShotSend.file(id, t: p.t, count: pngs.count) else { Pill.shared.flash("The file could not be saved"); return }
                            Pill.shared.flash("Saved · " + name)
                            ShotStore.sent(id, t, detail: name)
                        }
                    }
                case .claude, .codex:
                    guard let b = ShotPack.appBundle(t), NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil else {
                        ShotSend.clipboard(pngs, urls: urls, text: p.agentText(path: path, screenText: false))
                        Pill.shared.flash("\(t.word) is not on this Mac · picture and text on the clipboard")
                        return
                    }
                    ShotSend.bringForward(b) { ok in
                        guard ok else {
                            ShotSend.clipboard(pngs, urls: urls, text: p.agentText(path: path, screenText: false))
                            Pill.shared.flash("\(t.word) did not come up · picture and text on the clipboard"); return
                        }
                        let app = Capture.keyApp(), before = PutBack.before(app)
                        ShotSend.paste(steps: DeckRules.steps(captions: p.captions, agent: true, agentText: p.agentText(path: nil)), pngs: pngs, urls: urls, done: {
                            PutBack.check(app, windowsBefore: before, who: "shot", after: 0,
                                          clip: { ShotSend.clipboard(pngs, urls: urls, text: p.agentText(path: path, screenText: false)) }, ok: { ShotStore.sent(id, t) })
                        })
                    }
                case .claudeCode:
                    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    let running = [front].compactMap { $0 } + NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
                    let b = ShotPack.claudeCodeApp(running: running)
                    let text = ShotPack.terminals.contains(b) ? p.terminalLine(path: path, md: md) : p.agentText(path: path, screenText: false)
                    ShotSend.bringForward(b) { ok in
                        guard ok else { History.copy(text); Pill.shared.flash("Text on the clipboard · ⌘V to paste"); return }
                        let app = Capture.keyApp(), before = PutBack.before(app)
                        ShotSend.paste(picture: nil, text: text)
                        PutBack.check(app, windowsBefore: before, who: "shot", field: { Capture.terminalTarget(app) || Capture.targetWhyNot(app) == nil },
                                      clip: { History.copy(text) }, ok: { ShotStore.sent(id, t) })
                    }
                case .ask:
                    // shot.md holds the read text once the queue wrote it
                    ShotStore.queue.async { DispatchQueue.main.async { ShotSend.ask(id); ShotStore.sent(id, t) } }
                case .field, .person: break
                }
            }
        }
    }

    private func draft(_ chat: (id: String, title: String)) {
        guard let p = pack else { return }
        mode = .note
        close(); save()
        let id = p.id, more = pics.count > 1
        afterTalk {
            let text = self.pack?.deckText ?? ""
            ShotStore.queue.async {
                DispatchQueue.main.async {
                    // `beeper chats draft` takes one --file: a deck goes as a draft with its first picture and every caption
                    ShotSend.draft(chat: chat.id, id: id, note: text) { ok in
                        Pill.shared.flash(ok ? "Draft in Beeper → \(chat.title) (not sent)\(more ? " · the first picture only" : "")" : "The Beeper draft did not work")
                        if ok { ShotStore.sent(id, .person, detail: chat.title) } else { log("shot: beeper draft failed") }
                    }
                }
            }
        }
    }
}
