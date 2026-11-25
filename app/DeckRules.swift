// The capture deck's rules (17 November 2026; Andrii: "we build a deck of screenshots that are explainable"). After a
// capture one floating strip holds the pictures taken so far as cards, each with its caption under it, and a + card.
// The mic starts with each shot (`captureTalk`): what he says until the next shot is that card's caption. ⌘N or +
// takes the next one without closing the deck; ↵ puts the whole deck in as one pack; esc stops the caption take, else
// makes the deck passive (round 3); Cancel drops the shot (10 s Undo in the pill, then the pack goes to the Trash). Pure (Foundation and CoreGraphics only), tested in tests/deck_rules.swift. The strip: app/CaptureNote.swift.
import Foundation
import CoreGraphics

enum DeckRules {
    // MARK: order

    /// A card dragged from `from` to `to` (both indexes in the deck before the move); out of range: unchanged.
    static func move<T>(_ a: [T], from: Int, to: Int) -> [T] {
        guard a.indices.contains(from), from != to else { return a }
        var b = a
        let x = b.remove(at: from)
        b.insert(x, at: min(max(0, to), b.count))
        return b
    }
    /// Where a dragged card lands: the slot whose card centre the mouse passed (`centres`: the cards' mid x, in order).
    static func slot(x: CGFloat, centres: [CGFloat]) -> Int {
        guard !centres.isEmpty else { return 0 }
        return min(centres.count - 1, centres.filter { $0 < x }.count)
    }
    /// The picked card after a move: it follows the card that moved.
    static func picked(after from: Int, to: Int, picked: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let t = min(max(0, to), count - 1)
        if picked == from { return t }
        var p = picked
        if from < p, t >= p { p -= 1 } else if from > p, t <= p { p += 1 }
        return min(max(0, p), count - 1)
    }
    /// The picked card after one is taken out.
    static func picked(afterRemoving i: Int, picked: Int, count: Int) -> Int {
        let n = count - 1
        guard n > 0 else { return 0 }
        if picked > i { return picked - 1 }
        return min(picked, n - 1)
    }

    // MARK: the caption

    /// A take's words added to a card's caption: a space between, a lone dot or comma dropped, nothing when empty.
    static func add(_ heard: String, to caption: String) -> String {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, h.rangeOfCharacter(from: .alphanumerics) != nil else { return caption }
        let c = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? h : c + " " + h
    }
    /// The caption's first words under a card: whole words, at most `lines` lines of `width` characters, "…" when cut.
    /// A word longer than a line is cut. Empty: no lines.
    static func label(_ caption: String, width: Int, lines: Int = 2) -> [String] {
        let words = caption.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, width > 1, lines > 0 else { return [] }
        var out: [String] = [], cur = "", i = 0
        while i < words.count {
            var w = words[i]
            if w.count > width { w = String(w.prefix(width - 1)) + "…" }
            let next = cur.isEmpty ? w : cur + " " + w
            if next.count <= width { cur = next; i += 1; continue }
            out.append(cur); cur = ""
            if out.count == lines { break }
        }
        if out.count < lines, !cur.isEmpty { out.append(cur) }
        if i < words.count, var last = out.popLast() {
            // cut: the last line ends with "…", inside the width
            while last.count + 1 > width, let sp = last.lastIndex(of: " ") { last = String(last[..<sp]) }
            if last.count + 1 > width { last = String(last.prefix(width - 1)) }
            out.append(last + "…")
        }
        return out
    }
    /// While a caption take listens: the caption's last words under the card, so the newest spoken words show there
    /// (17 November 2026, Andrii: the live words belong in the card, not the strip up top). At most `lines` lines of
    /// `width` characters, the first one starting with "…" when cut. Each line with the index of its first word.
    static func labelTail(_ text: String, width: Int, lines: Int = 2) -> [(line: String, firstWord: Int)] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, width > 2, lines > 0 else { return [] }
        var out: [(line: String, firstWord: Int)] = [], cur = "", i = words.count - 1, start = words.count
        while i >= 0 {
            var w = words[i]
            if w.count > width { w = "…" + String(w.suffix(width - 1)) }
            let next = cur.isEmpty ? w : w + " " + cur
            if next.count <= width { cur = next; start = i; i -= 1; continue }
            out.insert((cur, start), at: 0); cur = ""
            if out.count == lines { break }
        }
        if out.count < lines, !cur.isEmpty { out.insert((cur, start), at: 0) }
        if i >= 0, var first = out.first {
            // cut: the first line starts with "…", inside the width
            while first.line.count + 1 > width, let sp = first.line.firstIndex(of: " ") {
                first.line = String(first.line[first.line.index(after: sp)...]); first.firstWord += 1
            }
            if first.line.count + 1 > width { first.line = String(first.line.suffix(width - 1)) }
            out[0] = ("…" + first.line, first.firstWord)
        }
        return out
    }
    /// The words a caption take shows in the voice strip up top: none (the card shows them), only the level.
    static func stripWords(_ words: String, deckTake: Bool) -> String { deckTake ? "" : words }

    /// The card under which typed and spoken text lands: the picked one, else the last.
    static func target(picked: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        if let p = picked, p >= 0, p < count { return p }
        return count - 1
    }

    // MARK: keys

    /// A key while the deck shows its cards (not the send-to list).
    /// esc never sends or keeps: round 3 (18 November 2026) it stops the caption take, else makes the deck passive (`esc`).
    /// `none`: the deck takes the key and does nothing. `pass`: a ⌘ chord the deck does not use goes on to the app.
    enum Key: Equatable {
        case putIn, cancel, escape, add, markup, sendList, retake, delete, pin
        case pick(Int), move(Int)     // move: the picked card to this index
        case backspace, typing, none, pass
    }
    /// The ⌘ keys the deck uses (↵ ⌘N ⌘E ⌘R ⌘P ⌘⌫ ⌘← ⌘→, with or without ⇧). Every other ⌘ chord passes to the app below.
    static let cmdCodes: Set<Int> = [36, 76, 53, ShotRules.addCode, 14, 15, 35, 51, 117, 123, 124]
    /// Does the deck take this key down while active? Plain keys always (they edit the caption); ⌘ chords only its own.
    static func takes(code: Int, cmd: Bool) -> Bool { !cmd || cmdCodes.contains(code) }

    // MARK: passive and active (round 3)
    // Round 3 (18 November 2026, Andrii: "it doesn't hijack my typing and controls at the same time, unless I
    // specifically click it"). The deck opens passive: his keys, ↵, esc and Right Option voice go to his app. A click on
    // the deck (a card, its caption, a button, its background) makes it active: typing edits the caption and the deck
    // keys work. A click outside it, or esc with no caption take listening, makes it passive again.

    enum Hold: Equatable { case passive, active }
    /// Does the deck take this key down? Passive: never. Active: as `takes(code:cmd:)`.
    static func takes(code: Int, cmd: Bool, hold: Hold) -> Bool { hold == .active && takes(code: code, cmd: cmd) }
    /// The hold after a mouse down anywhere while the deck shows: inside the deck active, outside passive.
    static func hold(afterClickInside inside: Bool) -> Hold { inside ? .active : .passive }
    /// esc while active: a caption take listening stops first; a spread deck gathers (round 4); else the deck goes
    /// passive (Cancel drops the shot).
    enum Esc: Equatable { case stopTalk, gather, passive }
    static func esc(listening: Bool, spread: Bool = false) -> Esc { listening ? .stopTalk : spread ? .gather : .passive }
    /// A Right Option take is the deck's caption only while it is active, or while the screen is dimmed for its next
    /// shot (he asked for that shot); passive, the take goes to his app as text.
    static func takesVoice(open: Bool, hold: Hold, collecting: Bool) -> Bool { open && (hold == .active || collecting) }
    /// The caption mic starting by itself with a shot (`captureTalk`): only when the deck is active. Passive, he is
    /// talking or typing to his app; the card's mic or Caption by voice starts it on a click.
    static func autoTalk(setting: Bool, hold: Hold) -> Bool { setting && hold == .active }

    // MARK: round 4 "Hand" (18 November 2026)
    // Andrii: the shot "in the middle of the caret and with smaller controls below ... a card deck that gather together
    // and can then organize ... send it all to the chat or one by one". He picked the "Hand" mockup: a small fan of
    // cards just above the caret, one pill under it (round 4b: a row; "Insert", not "Put in"). The deck never takes his keys; its only active state is
    // a voice caption on one card.

    /// An AX rect (top-left origin, y down) in AppKit points (bottom-left origin), by the main screen's height.
    static func appKit(ax r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
    /// The point the deck opens round: the caret's middle, else the field's middle, else none.
    static func anchor(caret: CGRect?, field: CGRect?) -> CGPoint? {
        if let c = caret, c.width >= 0, c.height > 0 { return CGPoint(x: c.midX, y: c.midY) }
        if let f = field, f.width > 0, f.height > 0 { return CGPoint(x: f.midX, y: f.midY) }
        return nil
    }

    // Round 4b (18 November 2026). Andrii's first live try of the 96 pt fan: "it is too tiny and now there are
    // basically no controls"; then "hand is the way to go but make it better". A design review found: a card click
    // pasted (twice, before the check ended), small hover targets pasted on a miss, mark up / retake / pin out of reach,
    // no close, no Undo for one card, click, reorder and drop on one press, targets moving under the mouse, and a deck
    // placed once over his lines on the old app's screen. Now: a click selects, the row acts, nothing moves under him.
    static let handBox = CGSize(width: 360, height: 190), handMin = CGSize(width: 150, height: 110)
    static let behindScale: CGFloat = 0.85, peekStep: CGFloat = 28, peekDrop: CGFloat = 5, peekDegrees: CGFloat = 3
    static let handMax = 3, hoverLift: CGFloat = 6, handGap: CGFloat = 8, handTabW: CGFloat = 34
    /// Motion: the hover lift 120 ms, a new shot flies on 180 ms (none with Reduce motion); a peek shows large after
    /// 700 ms (the top card is already large).
    static let slideSeconds = 0.12, flySeconds = 0.18, peekPreviewDelay = 0.7
    static let previewW: CGFloat = 480
    /// Round 4c (Andrii: "the controls to be a little neater"): one bar under the fan, 8 pt below it, 32 pt high, its
    /// buttons divided by hairlines, 12 pt words; one spacing (8 pt) and one corner (10 pt) for the bar and the cards.
    /// A button shows pressed at least 80 ms and acts on mouse up inside it.
    static let rowGap: CGFloat = 8, rowH: CGFloat = 32, rowFontSize: CGFloat = 12, rowSpacing: CGFloat = 8, pressSeconds = 0.08
    static let corner: CGFloat = 10, plusSize: CGFloat = 24, captionInset: CGFloat = 6
    /// The folded shots' strip (56 pt), the grip above the fan (12 pt), the close x (24 pt), Undo for a dropped card.
    static let stripH: CGFloat = 56, gripH: CGFloat = 12, closeSize: CGFloat = 24, undoSeconds = 10.0
    /// A drag reorders once it has gone 8 pt sideways (more across than down); there is no drag-to-drop.
    static let dragStart: CGFloat = 8
    static func reorders(dx: CGFloat, dy: CGFloat) -> Bool { abs(dx) >= dragStart && abs(dx) >= abs(dy) }

    /// The selected card: the one he clicked while it is still in the deck, else the newest.
    static func selected(_ s: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        if let s, s >= 0, s < count { return s }
        return count - 1
    }
    /// The cards the fan shows (deck indices, back to front): up to 2 others, the newest first chosen, oldest at the
    /// back; the selected card always on top. The rest fold (deck order) behind a count badge.
    static func handShown(count: Int, selected sel: Int?, max m: Int = handMax) -> (shown: [Int], folded: [Int]) {
        guard let top = selected(sel, count: count) else { return ([], []) }
        let others = (0..<count).filter { $0 != top }
        let behind = Array(others.suffix(Swift.max(0, m - 1)))
        return (behind + [top], others.filter { !behind.contains($0) })
    }
    /// The top card's size: the picture's shape inside 360x190 pt (a usual screen shot about 300x190), never smaller
    /// than 150x110.
    static func handTop(pixels p: CGSize) -> CGSize {
        guard p.width > 0, p.height > 0 else { return CGSize(width: 300, height: handBox.height) }
        let k = min(handBox.width / p.width, handBox.height / p.height)
        return CGSize(width: Swift.max(handMin.width, (p.width * k).rounded()), height: Swift.max(handMin.height, (p.height * k).rounded()))
    }
    /// The fan's size for `m` cards round a top card of `top`: the cards behind peek out at its left.
    static func fanSize(_ m: Int, top: CGSize) -> CGSize {
        guard m > 0 else { return .zero }
        let back = m > 1 ? CGFloat(m - 1) * peekStep - top.width * (1 - behindScale) / 2 : 0
        return CGSize(width: Swift.max(top.width, back + top.width), height: top.height)
    }
    /// Slot `k` of `m` (flipped y, from the fan's top-left): the top card (the last slot) straight at the right; each
    /// card behind it 85%, `peekStep` further left, a little lower, `peekDegrees` more tilt. `lifted` (the hover): up
    /// `hoverLift`, nothing else moves.
    static func fanCard(slot k: Int, of m: Int, top: CGSize, lifted: Bool = false) -> (frame: CGRect, degrees: CGFloat) {
        let d = CGFloat(m - 1 - k), fs = fanSize(m, top: top)
        let cx = fs.width - top.width / 2 - d * peekStep, cy = top.height / 2 + d * peekDrop - (lifted ? hoverLift : 0)
        let sc: CGFloat = d == 0 ? 1 : behindScale
        let w = top.width * sc, hh = top.height * sc
        return (CGRect(x: cx - w / 2, y: cy - hh / 2, width: w, height: hh), -d * peekDegrees)
    }
    /// The row under the fan. Insert all is the primary; Insert this only with 2 or more cards. Insert this, Voice,
    /// Mark up and Drop act on the selected card.
    enum HandButton: Int, CaseIterable {
        case insertAll, insertThis, next, voice, markup, drop
        /// The bar's order: the quiet ones first, Insert all (the primary, filled) always at the right end.
        static func row(count: Int) -> [HandButton] { [.insertThis, .next, .voice, .markup, .drop, .insertAll].filter { $0 != .insertThis || count > 1 } }
        func word(listening: Bool) -> String {
            switch self {
            case .insertAll: return "Insert all"
            case .insertThis: return "Insert this"
            case .next: return "Next shot"
            case .voice: return listening ? "Stop" : "Voice"
            case .markup: return "Mark up"
            case .drop: return "Drop"
            }
        }
        var glyph: String {
            switch self { case .insertAll: return "corner-down-left"; case .insertThis: return "arrow-up-right"; case .next: return "plus"
                          case .voice: return "microphone"; case .markup: return "edit"; case .drop: return "trash" }
        }
        /// The tooltip: what it does and its key hint. The deck takes no keys: the next shot names the capture key (it
        /// works while the deck is up), Insert all names ↵ while ↵ still inserts (`returnKey`, DeckRules.returnInserts).
        func tip(captureKey: String, count: Int, returnKey: Bool = false) -> (word: String, key: String) {
            switch self {
            case .insertAll: return (count > 1 ? "Insert all \(count) shots into your field" : "Insert the shot into your field", returnKey ? "↵" : "")
            case .insertThis: return ("Insert the selected shot only", "")
            case .next: return ("Take the next shot", captureKey)
            case .voice: return ("Say a caption for the selected shot", "")
            case .markup: return ("Mark up the selected shot", "")
            case .drop: return ("Drop the selected shot · Undo for 10 s", "")
            }
        }
    }
    /// The selected card's own small controls (top left): pin it on the screen, take it again.
    enum CardTool: Int, CaseIterable {
        case pin, retake
        var glyph: String { self == .pin ? "pinned" : "refresh" }
        var tip: String { self == .pin ? "Pin on the screen" : "Take this shot again" }
    }
    /// Where the hand sits (AppKit points): its fan's left edge at the caret's x (`fanLeft`: the fan's left inside the
    /// deck), its bottom just above the caret's line; no room above, just under it. A caret in the top `topBand` pt of
    /// its screen: right of the caret line, level with it (never over the lines under it). No caret: the field's
    /// top-left line. Neither: the middle of the screen. Always whole on its screen.
    static let topBand: CGFloat = 300
    static func placeHand(_ size: CGSize, fanLeft: CGFloat, caret: CGRect?, field: CGRect?, screens: [CGRect], screen: CGRect,
                          margin: CGFloat = 8, gap: CGFloat = 6) -> CGRect {
        let line = caret ?? field.map { CGRect(x: $0.minX + 12, y: $0.maxY - 26, width: 2, height: 18) }
        guard let c = line else {
            return CGRect(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        }
        let s = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(CGPoint(x: c.midX, y: c.midY)) }) ?? screen
        var x: CGFloat, y: CGFloat
        if c.maxY > s.maxY - topBand {
            x = c.maxX + 12; y = c.midY - size.height / 2
        } else {
            x = c.minX - fanLeft; y = c.maxY + gap
            if y + size.height > s.maxY - margin { y = c.minY - gap - size.height }
        }
        x = min(max(x, s.minX + margin), s.maxX - margin - size.width)
        y = min(max(y, s.minY + margin), s.maxY - margin - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
    // Round 5 "Stack" (23 November 2026; Andrii: the deck "must not wander", one column instead of a long strip,
    // larger images, Insert / Copy / Delete on each shot, Insert all / Copy all at the foot). One column of shots,
    // newest at the bottom, each 272 pt wide in its own shape (left edges aligned, 10 pt apart); the column scrolls
    // up and down only once it is taller than 70% of its screen. Placed once when it opens, next to the caret (else the
    // field's line, else the mouse pointer), whole on that screen; then it stays: a new shot never moves it (the edge
    // toward the caret stays put and the column grows away from it), only his drag does.
    static let stackW: CGFloat = 272, stackMinH: CGFloat = 120, stackMaxCardH: CGFloat = 360, stackGap: CGFloat = 10
    static let stackPad: CGFloat = 12, stackHeadH: CGFloat = 28, stackFootH: CGFloat = 30, stackShare: CGFloat = 0.7
    /// The panel's parts round the list: pad, head, 8, the list, 10, foot, pad.
    static var stackChrome: CGFloat { stackPad + stackHeadH + 8 + 10 + stackFootH + stackPad }
    /// A shot's picture in the column: 272 pt wide in its own shape, at most 360 pt high (a tall one narrower).
    static func stackImage(pixels p: CGSize) -> CGSize {
        guard p.width > 0, p.height > 0 else { return CGSize(width: stackW, height: 170) }
        let k = Swift.min(stackW / p.width, stackMaxCardH / p.height)
        return CGSize(width: Swift.max(40, (p.width * k).rounded()), height: Swift.max(24, (p.height * k).rounded()))
    }
    /// The shot's box (the picture centred on the card's ground): never under 120 pt, so its buttons always fit.
    static func stackBox(pixels p: CGSize) -> CGSize {
        CGSize(width: stackW, height: Swift.max(stackMinH, stackImage(pixels: p).height))
    }
    /// Where the column sits once it opens, and which edge stays put. `size`: its whole size (all shots, no scroll);
    /// `spot`: the caret (or the field's line, or a 1 pt rect at the mouse). Above the spot when there is room (its
    /// bottom stays, it grows up), else under it (its top stays, it grows down); x at the spot's left less the pad;
    /// whole on the screen. `maxH`: the most it may grow from the edge that stays before it scrolls.
    struct StackPlace: Equatable { var frame: CGRect; var growsDown: Bool; var maxH: CGFloat }
    static func placeStack(_ size: CGSize, spot c: CGRect, screen s: CGRect, margin: CGFloat = 8, gap: CGFloat = 8) -> StackPlace {
        let cap = (s.height * stackShare).rounded(.down)
        let above = s.maxY - margin - (c.maxY + gap), below = (c.minY - gap) - (s.minY + margin)
        let want = Swift.min(size.height, cap)
        let up = above >= want || above >= below
        let maxH = Swift.max(stackChrome + stackMinH, Swift.min(cap, up ? above : below))
        let h = Swift.min(size.height, maxH)
        var x = c.minX - stackPad, y = up ? c.maxY + gap : c.minY - gap - h
        x = Swift.min(Swift.max(x, s.minX + margin), s.maxX - margin - size.width)
        y = Swift.min(Swift.max(y, s.minY + margin), s.maxY - margin - h)
        return StackPlace(frame: CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: h), growsDown: !up, maxH: maxH)
    }
    /// The room the column has from the edge that stays to its screen's edge (after a drag too), at most 70% of it.
    static func stackRoom(_ f: CGRect, growsDown: Bool, screen s: CGRect, margin: CGFloat = 8) -> CGFloat {
        let room = growsDown ? f.maxY - (s.minY + margin) : s.maxY - margin - f.minY
        return Swift.max(stackChrome + stackMinH, Swift.min((s.height * stackShare).rounded(.down), room))
    }
    /// The column at a new height: the edge that stays, stays (the top when it grows down, else the bottom); x never moves.
    static func restack(_ f: CGRect, height h: CGFloat, growsDown: Bool) -> CGRect {
        CGRect(x: f.minX, y: growsDown ? f.maxY - h : f.minY, width: f.width, height: h)
    }
    /// The list's scroll: within 0...(content - room).
    static func clampScroll(_ y: CGFloat, content: CGFloat, room: CGFloat) -> CGFloat { Swift.min(Swift.max(0, y), Swift.max(0, content - room)) }
    /// A drag on a shot reorders it once it went 8 pt up or down (more down than across).
    static func reordersInColumn(dx: CGFloat, dy: CGFloat) -> Bool { abs(dy) >= dragStart && abs(dy) >= abs(dx) }
    /// A shot's own buttons (on the hovered or selected shot): Insert, Copy, Delete at its foot; Voice, Mark up, Pin,
    /// Take again as small round symbols at its top right. The foot: Next shot, Copy all, Insert all (filled).
    enum ShotAct: Int, CaseIterable {
        case insert, copy, delete, voice, markup, pin, retake
        static let words: [ShotAct] = [.insert, .copy, .delete]
        static let tools: [ShotAct] = [.voice, .markup, .pin, .retake]
        func word(listening: Bool = false) -> String {
            switch self {
            case .insert: return "Insert"; case .copy: return "Copy"; case .delete: return "Delete"
            case .voice: return listening ? "Stop" : "Voice"; case .markup: return "Mark up"; case .pin: return "Pin"; case .retake: return "Take again"
            }
        }
        var glyph: String {
            switch self {
            case .insert: return "corner-down-left"; case .copy: return "copy"; case .delete: return "trash"; case .voice: return "microphone"
            case .markup: return "edit"; case .pin: return "pinned"; case .retake: return "refresh"
            }
        }
        var tip: String {
            switch self {
            case .insert: return "Insert this shot into your field"; case .copy: return "Copy this shot"
            case .delete: return "Delete this shot · Undo for 10 s"; case .voice: return "Say a caption for this shot"
            case .markup: return "Mark up this shot"; case .pin: return "Pin on the screen"; case .retake: return "Take this shot again"
            }
        }
    }
    enum FootAct: Int, CaseIterable {
        case next, copyAll, insertAll
        func word(count: Int) -> String {
            switch self { case .next: return "Next shot"; case .copyAll: return count > 1 ? "Copy all" : "Copy"; case .insertAll: return count > 1 ? "Insert all" : "Insert" }
        }
        var glyph: String { switch self { case .next: return "plus"; case .copyAll: return "copy"; case .insertAll: return "corner-down-left" } }
        /// Its key as a cap: the capture key for the next shot, ↵ on Insert all while ↵ still inserts (returnInserts).
        func key(captureKey: String, returnKey: Bool) -> String {
            switch self { case .next: return captureKey; case .copyAll: return ""; case .insertAll: return returnKey ? "↵" : "" }
        }
    }

    /// Insert this: that card alone, the rest stay; on the last card it is all, and the deck closes.
    enum PutWhat: Equatable { case one(Int), all }
    static func putOne(_ i: Int, count: Int) -> PutWhat? {
        guard count > 0, i >= 0, i < count else { return nil }
        return count == 1 ? .all : .one(i)
    }
    /// One insert at a time: a second press while one runs does nothing (no double paste).
    static func mayInsert(busy: Bool, count: Int) -> Bool { !busy && count > 0 }
    /// A card back after a failed insert: where it was, or the end if the deck got shorter.
    static func backAt(_ k: Int, count: Int) -> Int { Swift.max(0, Swift.min(k, count)) }
    /// The deck never takes his keys (round 4); his voice is a caption only while the selected card's Voice opens a take.
    static let takesKeys = false
    /// Round 4c (Andrii: "many times enter just did not react"; his habit is ↵ = put in): Return or keypad Enter inserts
    /// all, swallowed by the key tap (the deck still never becomes key), but only while the deck is up and ready, no
    /// key went to his app since it opened or since the last card was added, and no ⌘ ⌃ ⌥ ⇧ is held (the keypad and fn
    /// bits do not count). After one key he typed, ↵ is his app's again: never a message he is writing.
    static func returnInserts(deckOpen: Bool, keysSinceOpen: Int, mods: CGEventFlags) -> Bool {
        deckOpen && keysSinceOpen == 0 && mods.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }
    /// Return (36) or keypad Enter (76).
    static func isReturn(_ code: Int64) -> Bool { code == 36 || code == 76 }
    /// The log line for every ↵ while the deck is up.
    static func returnLog(inserted: Bool, keysSinceOpen: Int) -> String {
        inserted ? "shot: ↵ inserted all" : "shot: ↵ passed to app, \(keysSinceOpen) keys since open"
    }
    static func handVoice(open: Bool, micOpening: Bool) -> Bool { open && micOpening }
    /// A card's caption take ends on its mic again or a click outside the deck.
    static func endsCaption(clickInside: Bool, onMic: Bool) -> Bool { !clickInside || onMic }

    // MARK: motion (round 3, Andrii: "a little more animated visually")
    /// The deck's arrival: 180 ms, rising 10 pt and growing from 97% while it fades in. Close has no motion: AppKit's
    /// fade held a closed deck on the screen 0.38 s (app/DeckBench.swift).
    static let arriveSeconds = 0.18, arriveRise: CGFloat = 10, arriveScale: CGFloat = 0.97, closeSeconds = 0.0
    static func key(code: Int, cmd: Bool, shift: Bool, picked: Int, count: Int) -> Key {
        switch code {
        case 36, 76: return .putIn                         // ⌘↵ too: one key for put in
        case 53: return .escape                            // round 3: stops the caption take, else passive
        case 48 where !cmd: return .sendList
        default: break
        }
        if cmd {
            switch code {
            case ShotRules.addCode: return .add               // ⌘N
            case 14: return .markup                           // ⌘E
            case 15: return .retake                           // ⌘R
            case 35: return .pin                              // ⌘P: the picked card floats on the screen
            case 51, 117: return count > 1 ? .delete : .none     // ⌘⌫ the picked card; the last one stays (esc drops the shot)
            case 123: return shift ? (picked > 0 ? .move(picked - 1) : .none) : .pick(max(0, picked - 1))
            case 124: return shift ? (picked < count - 1 ? .move(picked + 1) : .none) : .pick(min(count - 1, picked + 1))
            default: return .pass
            }
        }
        if code == 51 { return .backspace }
        return .typing
    }

    // MARK: a pinned card (app/Pin.swift)

    /// A pinned picture's first size, in points: the picture at its own size (`pixels` / `scale`), at most 45% of the
    /// screen's width and 85% of its height (a tall scrolling capture stays readable), at least 80 pt on its long side;
    /// the shape kept.
    static func pinSize(pixels: CGSize, scale: CGFloat, screen: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: 80, height: 80) }
        let pt = CGSize(width: pixels.width / max(scale, 1), height: pixels.height / max(scale, 1))
        let k = min(1, screen.width * 0.45 / pt.width, screen.height * 0.85 / pt.height)
        return grow(pt, k, screen: screen)
    }
    /// Scroll on a pinned picture: `dy` up grows it 2% a step, down shrinks it; 80 pt to the screen's size, shape kept.
    static func pinZoom(_ size: CGSize, dy: CGFloat, screen: CGSize) -> CGSize {
        grow(size, max(0.5, min(1.5, 1 + dy * 0.02)), screen: screen)
    }
    private static func grow(_ s: CGSize, _ k: CGFloat, screen: CGSize) -> CGSize {
        var w = s.width * k, h = s.height * k
        let long = max(w, h)
        if long < 80 { w *= 80 / long; h *= 80 / long }
        let fit = min(1, screen.width / w, screen.height / h)
        return CGSize(width: (w * fit).rounded(), height: (h * fit).rounded())
    }

    // MARK: what goes in

    /// One step of a put-in: a card's picture (by index) or a text pasted after it.
    enum Step: Equatable { case picture(Int), text(String) }
    /// The order things go into a field. An ordinary field: each card as one unit, its picture and then its caption
    /// (an empty caption: the picture alone). An agent app: the agent text first (it names each picture and its
    /// caption), then every picture as attachments, so the message is whole before the last paste and the caret stays
    /// after the text (17 November 2026: pictures first, then a 1.6 s wait, then the text arrived as 2 messages in
    /// the Claude app). `pictures` false (a terminal): the text alone.
    static func steps(captions: [String], agent: Bool, pictures: Bool = true, agentText: String = "") -> [Step] {
        var out: [Step] = []
        if !pictures { return agentText.isEmpty ? [] : [.text(agentText)] }
        if agent {
            if !agentText.isEmpty { out.append(.text(agentText)) }
            out += captions.indices.map { .picture($0) }
            return out
        }
        for (i, c) in captions.enumerated() {
            out.append(.picture(i))
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.text(t)) }
        }
        return out
    }
    /// How long the last picture stays on the clipboard after its ⌘V before his clipboard comes back: Electron and
    /// Chromium apps read a big picture late.
    static let pictureHold = 1.6
    /// The wait after a step's ⌘V before the next step overwrites the clipboard (speed round, 17 November 2026: was
    /// 1.6 s after each picture and 1.15-1.4 s after each text). A picture gets longer: a big one is read late.
    static func gap(after s: Step) -> Double {
        if case .picture = s { return 0.8 }
        return 0.25
    }

    /// ↵ waits for the screen read only where the put-in uses it (a terminal line points at shot.md, which holds it);
    /// an ordinary field and an agent app go at once.
    static func waitsForRead(terminal: Bool) -> Bool { terminal }
    /// ↵ waits for a voice take only when it is the deck's own caption take; a take in another app is not the deck's.
    static func waitsForTalk(idle: Bool, deckTake: Bool) -> Bool { !idle && deckTake }

    // where the put-in goes: PutRules (one rule for every place that pastes into a remembered app)

    // MARK: the action row

    /// The action row's buttons: `widths` in order, in three groups (`groups`: how many on the left, in the middle, on
    /// the right). The left group starts at `x0`, the right group ends at `x1`, the middle one is centred between them.
    static func row(widths: [CGFloat], groups: (Int, Int, Int), x0: CGFloat, x1: CGFloat, y: CGFloat, h: CGFloat, gap: CGFloat = 6) -> [CGRect] {
        func run(_ ws: ArraySlice<CGFloat>, from x: CGFloat) -> [CGRect] {
            var x = x
            return ws.map { w in defer { x += w + gap }; return CGRect(x: x, y: y, width: w, height: h) }
        }
        func span(_ ws: ArraySlice<CGFloat>) -> CGFloat { ws.reduce(0, +) + CGFloat(max(0, ws.count - 1)) * gap }
        let (l, m, _) = groups
        let left = widths.prefix(l), mid = widths.dropFirst(l).prefix(m), right = widths.dropFirst(l + m)
        let lr = run(left, from: x0)
        let rr = run(right, from: x1 - span(right))
        let lEnd = lr.last?.maxX ?? x0, rStart = rr.first?.minX ?? x1
        let mr = run(mid, from: ((lEnd + rStart) / 2 - span(mid) / 2).rounded())
        return lr + mr + rr
    }
    /// The row's least width: every button, a gap between, `space` round the middle group.
    static func rowWidth(widths: [CGFloat], groups: (Int, Int, Int), gap: CGFloat = 6, space: CGFloat = 24) -> CGFloat {
        let n = widths.count
        return widths.reduce(0, +) + CGFloat(max(0, n - 1)) * gap + (groups.1 > 0 ? 2 * space : space)
    }

    // MARK: size and place

    static let cardW: CGFloat = 132, cardH: CGFloat = 84, minCardW: CGFloat = 76
    /// The cards' width so the deck fits its screen: `room` for the cards, `n` cards, `gap` between.
    static func cardWidth(n: Int, room: CGFloat, gap: CGFloat = 10) -> CGFloat {
        guard n > 0 else { return cardW }
        let w = (room - CGFloat(n - 1) * gap) / CGFloat(n)
        return max(minCardW, min(cardW, w.rounded(.down)))
    }
    /// The saved place ("x,y", the card's bottom-left) back as a point; nil when empty or not two numbers.
    static func parse(_ s: String) -> CGPoint? {
        let p = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 2, let x = p[0], let y = p[1], x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
    static func save(_ p: CGPoint) -> String { "\(Int(p.x.rounded())),\(Int(p.y.rounded()))" }
    /// Where the deck's card sits: at the place he dragged it to (kept inside the screen that holds it), else at the
    /// bottom centre of `screen` (the visible part of the mouse's screen). `screens`: every screen's visible part.
    static func place(_ size: CGSize, saved: CGPoint?, screens: [CGRect], screen: CGRect, margin: CGFloat = 8, foot: CGFloat = 24) -> CGRect {
        func inside(_ o: CGPoint, _ s: CGRect) -> CGRect {
            let x = min(max(o.x, s.minX + margin), s.maxX - margin - size.width)
            let y = min(max(o.y, s.minY + margin), s.maxY - margin - size.height)
            return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        }
        if let o = saved, let s = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(o) }) { return inside(o, s) }
        return inside(CGPoint(x: screen.midX - size.width / 2, y: screen.minY + foot), screen)
    }
    /// The deck grown or shrunk (a card added or taken out) keeps its centre when it sat at the default place, else
    /// its left edge; then it is kept inside the screen.
    static func regrow(_ f: CGRect, to size: CGSize, centred: Bool, screen: CGRect, margin: CGFloat = 8) -> CGRect {
        let x0 = centred ? f.midX - size.width / 2 : f.minX
        let x = min(max(x0, screen.minX + margin), screen.maxX - margin - size.width)
        let y = min(max(f.minY, screen.minY + margin), screen.maxY - margin - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: the live level

    /// The mic's level as 0…1 for the strip's bars: a peak in -50…-10 dB, so a quiet room shows nothing and speech
    /// fills most of it.
    static func level(peak: Float) -> CGFloat {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(Double(peak))
        return CGFloat(min(1, max(0, (db + 50) / 40)))
    }
    /// Five bars' heights (0…1) from the last levels, newest last; fewer levels give zeros in front.
    static func bars(_ levels: [CGFloat], n: Int = 5) -> [CGFloat] {
        let l = Array(levels.suffix(n))
        return Array(repeating: 0, count: n - l.count) + l
    }
}
