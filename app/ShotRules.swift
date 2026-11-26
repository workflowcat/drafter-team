// Quick capture's rules (round three, Part B and C, 14 November 2026): the capture key, what a drag or a key in the
// dimmed screen means, where the region sits on its display, and what goes into the field afterwards. Pure: no AppKit,
// tested in tests/shot_rules.swift. The overlay, ScreenCaptureKit and the paste live in app/Capture.swift.
import Foundation
import CoreGraphics

enum ShotRules {
    /// Keys round two (17 November 2026, the user: one key family per job, no chords taken from other apps): ⌘⇧5 is the
    /// capture key. macOS's own ⌘⇧5 wins while it is on, so until the user turns it off there is no capture key, a one-time
    /// hint says where to turn it off (`hint`), and an optional fallback key (setting `captureFallbackKey`, "" = none)
    /// may stand beside it. ⌘⇧S (Save As or Duplicate in many apps) is a setting, `captureCmdShiftS`, now off by
    /// default. ⌃⌥S was the default from 14 to 17 November; it may still be set as the key or the fallback.
    static let defaultKey = "⌘⇧5"
    static let systemKey = "⌘⇧5"
    static let saveAsKey = "⌘⇧S"
    static let oldKey = "⌃⌥S"
    static let taken: Set<String> = ["⌘⇧3", "⌘⇧4", "⌘⇧6", "⌃⌥V", "⌘⇧V", "⌘Space", "⌃⌥Space"]
    /// The exact System Settings path that frees ⌘⇧5 (macOS 15 and 26), for the hint and Settings.
    static let systemPath = "System Settings › Keyboard › Keyboard Shortcuts… › Screenshots › untick “Screenshot and recording options” (⌘⇧5)"
    /// A capture key the user may set: parses, has ⌘ ⌃ or ⌥, and is none of the taken ones (⌘⇧S and ⌘⇧5 are allowed).
    static func allowed(_ s: String) -> Bool {
        guard let k = QuickRules.hotkey(s), k.cmd || k.ctrl || k.alt else { return false }
        return !taken.contains { QuickRules.hotkey($0) == k }
    }

    /// Is macOS's own ⌘⇧5 ("Screenshot and recording options", symbolic hot key 184) on? `hotkeys`: the
    /// AppleSymbolicHotKeys dictionary of com.apple.symbolichotkeys (read only, never written). No entry: on (the default).
    static func systemKeyOn(_ hotkeys: [String: Any]?) -> Bool {
        guard let e = hotkeys?["184"] as? [String: Any], let on = e["enabled"] else { return true }
        if let b = on as? Bool { return b }
        if let n = on as? NSNumber { return n.boolValue }
        if let i = on as? Int { return i != 0 }
        return true
    }
    /// The capture keys in use, the first one shown in Settings. `setting` "" = capture off (no key at all, the
    /// fallback and ⌘⇧S included). ⌘⇧5 only once macOS let it go; any other allowed setting: that key. Then the
    /// fallback, then ⌘⇧S while `cmdShiftS` is on. A key that is not allowed is left out.
    static func keys(setting: String, systemOn: Bool, cmdShiftS: Bool, fallback: String = "") -> [String] {
        let s = setting.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return [] }
        var want: [String] = []
        if QuickRules.hotkey(s) == QuickRules.hotkey(systemKey) { if !systemOn { want.append(systemKey) } }
        else { want.append(s) }
        want.append(fallback.trimmingCharacters(in: .whitespaces))
        if cmdShiftS { want.append(saveAsKey) }
        var out: [String] = []
        for k in want where allowed(k) && !out.contains(where: { QuickRules.hotkey($0) == QuickRules.hotkey(k) }) {
            if QuickRules.hotkey(k) == QuickRules.hotkey(systemKey), systemOn { continue }   // macOS takes it first
            out.append(k)
        }
        return out
    }
    /// Settings shows the step to free ⌘⇧5 while ⌘⇧5 is the key and macOS still holds it.
    static func showSystemStep(setting: String, systemOn: Bool) -> Bool {
        systemOn && QuickRules.hotkey(setting) == QuickRules.hotkey(systemKey)
    }
    /// The one-time hint (a strip line with `systemPath`): due once, while the step is needed and not shown before.
    static func hintDue(setting: String, systemOn: Bool, shown: Bool) -> Bool {
        !shown && showSystemStep(setting: setting, systemOn: systemOn)
    }

    // MARK: the pills (look round, 15 November 2026: one floating pill like macOS ⌘⇧5 / CleanShot)

    /// A pill: groups of buttons, `h` tall each, `gap` apart inside a group, `split` between groups (a hairline sits in
    /// the middle of it), `pad` round them. `origin`: the bar's corner. Returns the bar, each button and the hairlines' x.
    struct Pill: Equatable { var bar: CGRect; var items: [CGRect]; var dividers: [CGFloat] }
    static let pillButton: CGFloat = 42, pillPad: CGFloat = 7   // key and strip round: 32 → 42 (the user: bigger)
    static func pillSize(_ groups: [[CGFloat]], pad: CGFloat = pillPad, gap: CGFloat = 2, split: CGFloat = 13, h: CGFloat = pillButton) -> CGSize {
        let inner = groups.map { g in g.reduce(0, +) + CGFloat(max(0, g.count - 1)) * gap }.reduce(0, +)
        return CGSize(width: inner + CGFloat(max(0, groups.count - 1)) * split + 2 * pad, height: h + 2 * pad)
    }
    static func pill(_ groups: [[CGFloat]], at origin: CGPoint, pad: CGFloat = pillPad, gap: CGFloat = 2, split: CGFloat = 13,
                     h: CGFloat = pillButton) -> Pill {
        var x = origin.x + pad
        var items: [CGRect] = [], dividers: [CGFloat] = []
        for (gi, g) in groups.enumerated() {
            if gi > 0 { dividers.append(x + split / 2 - gap / 2); x += split - gap }
            for w in g { items.append(CGRect(x: x, y: origin.y + pad, width: w, height: h)); x += w + gap }
        }
        let size = pillSize(groups, pad: pad, gap: gap, split: split, h: h)
        return Pill(bar: CGRect(origin: origin, size: size), items: items, dividers: dividers)
    }
    /// The item under a point; nil for the gaps and outside.
    static func hitItem(_ p: CGPoint, _ items: [CGRect]) -> Int? { items.firstIndex { $0.contains(p) } }

    /// The one placement rule for what follows a capture (the strip, its send-to list, the markup pill), in flipped
    /// coordinates (y down): right under the picture `r`, left edge at `x`; no room under it: on the bottom edge of
    /// `bounds`, never above the picture, so the whole shot stays in sight. If that bottom place still covers the
    /// picture (it reaches the bottom), it moves beside it, right then left, when there is room; else it stays at the
    /// bottom over the picture's foot. Kept `margin` inside `bounds`.
    static func under(_ size: CGSize, _ r: CGRect, x: CGFloat, in b: CGRect, gap: CGFloat = 10, margin: CGFloat = 8) -> CGRect {
        var x = min(max(x, b.minX + margin), b.maxX - margin - size.width)
        var y = r.maxY + gap
        let floor = b.maxY - margin - size.height
        if y > floor {
            y = max(floor, b.minY + margin)
            if CGRect(x: x, y: y, width: size.width, height: size.height).intersects(r) {
                if b.maxX - margin - r.maxX >= size.width + gap { x = r.maxX + gap }
                else if r.minX - b.minX - margin >= size.width + gap { x = r.minX - gap - size.width }
            }
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
    /// The markup pill attached to a picture on the screen (flipped: y down), centred on it (`under`).
    static func attach(_ size: CGSize, to r: CGRect, in bounds: CGRect, gap: CGFloat = 10, margin: CGFloat = 8) -> CGRect {
        under(size, r, x: r.midX - size.width / 2, in: bounds, gap: gap, margin: margin)
    }

    // MARK: the toolbar on the dimmed screen (like macOS ⌘⇧5)

    /// The toolbar's buttons, left to right: region · window · screen | keep · text | the last send-to target · close.
    enum Tool: Int, CaseIterable { case region, window, screen, scroll, keep, text, target, cancel
        var glyph: String {
            switch self { case .region: return "marquee"; case .window: return "app-window"; case .screen: return "device-desktop"
            case .scroll: return "arrows-vertical"
            case .keep: return "bookmark"; case .text: return "text"; case .target: return "send"; case .cancel: return "close" }
        }
        var key: String {
            switch self { case .region: return "1"; case .window: return "2"; case .screen: return "3"; case .scroll: return "S"; case .keep: return "K"
            case .text: return "T"; case .target: return "⇥"; case .cancel: return "esc" }
        }
        /// The word in its hover tip and for VoiceOver (never on the bar).
        var word: String {
            switch self { case .region: return "Region"; case .window: return "Window"; case .screen: return "Screen"
            case .scroll: return "Scrolling: drag a region, then scroll"
            case .keep: return "Keep on the tape"; case .text: return "Put its text in"; case .target: return "Send to"; case .cancel: return "Close" }
        }
    }
    static let toolGroups: [[Tool]] = [[.region, .window, .screen, .scroll], [.keep, .text], [.target, .cancel]]
    /// The capture pill at the bottom centre of a screen (`screen` local, origin bottom-left), `bottom` above its edge.
    static func toolbar(screen: CGSize, bottom: CGFloat = 72) -> (bar: CGRect, items: [CGRect]) {
        let groups = toolGroups.map { $0.map { _ in pillButton } }
        let size = pillSize(groups)
        let p = pill(groups, at: CGPoint(x: ((screen.width - size.width) / 2).rounded(), y: bottom))
        return (p.bar, p.items)
    }
    /// The capture pill's dividers (x), for drawing.
    static func toolbarPill(screen: CGSize, bottom: CGFloat = 72) -> Pill {
        let groups = toolGroups.map { $0.map { _ in pillButton } }
        let size = pillSize(groups)
        return pill(groups, at: CGPoint(x: ((screen.width - size.width) / 2).rounded(), y: bottom))
    }
    /// The item under a point (same space as the layout); nil for the bar's gaps and outside it.
    static func hit(_ p: CGPoint, _ items: [CGRect]) -> Tool? {
        hitItem(p, items).flatMap { Tool(rawValue: $0) }
    }

    // MARK: the markup pill (in place and in the editor panel)

    enum MarkItem: Equatable { case tool(MarkTool), color(Int), size(Int), undo, add, back, done
        var key: String {
            switch self {
            case .tool(let t): return t.key
            case .color(let c): return Markup.colors[c].key
            case .size: return ""
            case .undo: return "⌘Z"; case .add: return "⌘N"; case .back: return "esc"; case .done: return "↵"
            }
        }
        var word: String {
            switch self {
            case .tool(let t): return t.word.prefix(1).uppercased() + t.word.dropFirst()
            case .color(let c): return Markup.colors[c].name.prefix(1).uppercased() + Markup.colors[c].name.dropFirst()
            case .size(let s): return Markup.sizeWords[s].prefix(1).uppercased() + Markup.sizeWords[s].dropFirst() + " · [ ]"
            case .undo: return "Undo"; case .add: return "Add another picture"; case .back: return "Back"; case .done: return "Done"
            }
        }
        var glyph: String? {
            switch self { case .tool(let t): return t.glyph; case .undo: return "arrow-back-up"; case .add: return "plus"; case .back: return "arrow-left"
            case .done: return "check"; case .color, .size: return nil }
        }
    }
    static let markGroups: [[MarkItem]] = [
        MarkTool.allCases.map { .tool($0) },
        Markup.colors.indices.map { .color($0) },
        Markup.sizeFactors.indices.map { .size($0) },
        [.undo, .add],
        [.back, .done],
    ]
    /// Swatches and sizes are narrower than the glyph buttons (32 pt since the key and strip round).
    static func markWidth(_ i: MarkItem) -> CGFloat {
        switch i { case .color, .size: return 32; default: return pillButton }
    }
    static func markPill(at origin: CGPoint) -> Pill { pill(markGroups.map { $0.map(markWidth) }, at: origin) }
    static var markPillSize: CGSize { pillSize(markGroups.map { $0.map(markWidth) }) }
    static func markHit(_ p: CGPoint, _ pill: Pill) -> MarkItem? {
        hitItem(p, pill.items).map { markGroups.flatMap { $0 }[$0] }
    }

    // MARK: where the strip opens (AppKit screen points, y up)

    /// The strip after a capture (AppKit screen points, y up): `under` the captured region on its left edge; a whole
    /// screen (or no region): at the bottom centre. `size`: the strip's card with the send-to list when open (the list
    /// opens under the strip, so the card is placed again when it grows); `screen`: the visible part of the region's
    /// screen.
    static func stripPlace(_ size: CGSize, region: CGRect?, full: Bool, screen: CGRect, gap: CGFloat = 10, margin: CGFloat = 8) -> CGRect {
        let whole = full || region == nil
        let r = whole ? screen : region!
        // y up → y down within the screen, and back
        let down = CGRect(x: r.minX, y: screen.minY + screen.maxY - r.maxY, width: r.width, height: r.height)
        let p = under(size, down, x: whole ? screen.midX - size.width / 2 : r.minX, in: screen, gap: gap, margin: margin)
        return CGRect(x: p.minX, y: screen.minY + screen.maxY - p.maxY, width: p.width, height: p.height)
    }
    /// The strip at a caret (no captured region: a shot from the journal): under the caret, above it without room,
    /// else the bottom centre.
    static func caretPlace(_ size: CGSize, caret r: CGRect, screen: CGRect, gap: CGFloat = 10, margin: CGFloat = 8) -> CGRect {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height) }
        let x = min(max(r.minX, screen.minX + margin), screen.maxX - margin - size.width)
        let below = r.minY - gap - size.height
        if below >= screen.minY + margin { return at(x, below) }
        let above = r.maxY + gap
        if above + size.height <= screen.maxY - margin { return at(x, above) }
        return at(min(max(screen.midX - size.width / 2, screen.minX + margin), screen.maxX - margin - size.width), screen.minY + margin)
    }
    /// The strip grown at a caret (the send-to list opens under it): its top edge stays; past the screen's bottom it moves up.
    static func stripGrow(_ f: CGRect, to h: CGFloat, screen: CGRect, margin: CGFloat = 8) -> CGRect {
        var y = f.maxY - h
        if y < screen.minY + margin { y = screen.minY + margin }
        return CGRect(x: f.minX, y: y, width: f.width, height: h)
    }

    /// A set's thumbnails in the strip: ⌘← ⌘→ pick one (past the last: back to the line), ⌫ takes the picked one out,
    /// esc lets go of it. nil: the key is not about the thumbnails (one picture, or nothing picked and no ⌘ arrow).
    enum PickKey: Equatable { case pick(Int?), remove(Int) }
    static func stripPick(code: Int, cmd: Bool, picked: Int?, count: Int) -> PickKey? {
        guard count > 1 else { return nil }
        if cmd, code == 123 { return .pick(max(0, (picked ?? count) - 1)) }
        if cmd, code == 124 { guard let i = picked else { return nil }; return .pick(i + 1 < count ? i + 1 : nil) }
        guard let i = picked, i < count else { return nil }
        switch code { case 51, 117: return .remove(i); case 53: return .pick(nil); default: return nil }
    }

    // MARK: the strip's buttons

    /// The capture deck's action row, left to right (round 2, 17 November 2026; docs/rounds/2026-11-17-deck.md):
    /// cancel (esc: stops the caption take, else drops the shot), mark up ⌘E, next shot ⌘N, send to… ⇥, put in ↵ (primary).
    /// The deck's row, in order (round 3, from a week's use: put in 83, next shot 24, caption by voice 7, mark up 4,
    /// cancel 13; Send to rarely): Put in first and largest, Next shot second, the rest small, Send to as a small button.
    enum StripButton: Int, CaseIterable { case putIn, add, talk, markup, cancel, send
        var glyph: String {
            switch self { case .cancel: return "close"; case .markup: return "edit"; case .add: return "plus"; case .send: return "send"
            case .putIn: return "corner-down-left"; case .talk: return "microphone" }
        }
        var key: String {
            switch self { case .cancel: return ""; case .markup: return "⌘E"; case .add: return "⌘N"; case .send: return "⇥"; case .putIn: return "↵"
            case .talk: return "" }
        }
        var word: String {
            switch self { case .cancel: return "Cancel"; case .markup: return "Mark up"; case .add: return "Next shot"; case .send: return "Send to…"
            case .putIn: return "Put in"; case .talk: return "Caption by voice" }
        }
        /// Large: Put in and Next shot. Small: the rest. Icon only: Send to (its word shows as the tip).
        var large: Bool { self == .putIn || self == .add }
        var iconOnly: Bool { self == .send }
    }

    /// What happens on release: put the picture in (default), keep it on the tape only (K), or put its read text in (T).
    enum Mode: String { case paste, keep, text }
    enum Pick { case region, window, screen, scroll }   // scroll: a region, then frames while the user scrolls (app/ScrollShot.swift)

    /// A key while the screen is dimmed.
    enum Action: Equatable { case cancel, screen, windowMode, pick(Pick), mode(Mode), none }
    static func key(_ code: Int, dragging: Bool) -> Action {
        switch code {
        case 53: return .cancel
        case 36, 76: return dragging ? .none : .screen
        case 49: return .windowMode
        case 18: return dragging ? .none : .pick(.region)    // 1 2 3: the toolbar's region · window · screen
        case 19: return dragging ? .none : .pick(.window)
        case 20: return dragging ? .none : .screen
        case 1: return dragging ? .none : .pick(.scroll)   // S: scrolling capture
        case 40: return .mode(.keep)     // K
        case 17: return .mode(.text)     // T
        case 35: return .mode(.paste)    // P: back to paste
        default: return .none
        }
    }

    /// The dragged rectangle from two points; nil when it is too small to mean a region (a click).
    static func region(_ a: CGPoint, _ b: CGPoint, min: CGFloat = 6) -> CGRect? {
        let r = CGRect(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return r.width >= min && r.height >= min ? r.integral : nil
    }
    /// A region in AppKit screen points (origin bottom-left of the main screen) as ScreenCaptureKit's source rectangle
    /// on its display (origin top-left of that display), clipped to it.
    static func sourceRect(_ r: CGRect, display: CGRect) -> CGRect {
        let c = r.intersection(display)
        guard !c.isNull else { return .zero }
        return CGRect(x: c.minX - display.minX, y: display.maxY - c.maxY, width: c.width, height: c.height)
    }

    /// The hint line under the dimmed screen's top edge.
    static func hint(_ mode: Mode, pick: Pick) -> String {
        let what = pick == .window ? "click a window" : "drag a region"
        let then: String
        switch mode { case .paste: then = "puts it in"; case .keep: then = "keeps it on the tape"; case .text: then = "puts its text in" }
        return "\(what) · space window · ↵ screen · K keep · T text · esc — release \(then)"
    }

    // MARK: Part C: the picture and a line together

    /// After a capture, the strip "what is this?": what each key sends, in the order it goes in.
    enum Note: Equatable { case picture, pictureAndLine(String), pictureAndText }
    /// The strip's keys (screenshot tool): ⌘E mark up, ⇥ the send-to list, else `note`'s ↵ ⌘↵ esc, else typing.
    enum StripKey: Equatable { case note(Note), markup, sendList, addAnother, typing }
    /// ⌘N: another picture for the same hand-off (the strip closes, the screen dims again, the next capture joins).
    static let addCode = 45
    static func strip(code: Int, cmd: Bool, line: String) -> StripKey {
        if cmd, code == 14 { return .markup }
        if cmd, code == addCode { return .addAnother }
        if code == 48, !cmd { return .sendList }
        if let n = note(code: code, cmd: cmd, line: line) { return .note(n) }
        return .typing
    }
    static func note(code: Int, cmd: Bool, line: String) -> Note? {
        switch code {
        case 53: return .picture
        case 36, 76:
            if cmd { return .pictureAndText }
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return l.isEmpty ? .picture : .pictureAndLine(l)
        default: return nil
        }
    }
    /// How the two go in: two pastes in a row, picture first, then the text after a short wait (the app takes the
    /// picture as an attachment or inline, then the text goes into the box). One pasteboard holding both makes most
    /// fields take one type and drop the other, so the text would be lost.
    struct Delivery: Equatable { let picture: Bool; let text: String?; let gapMs: Int }
    static func delivery(_ n: Note, read: String) -> Delivery {
        switch n {
        case .picture: return Delivery(picture: true, text: nil, gapMs: 0)
        case .pictureAndLine(let l): return Delivery(picture: true, text: l, gapMs: 350)
        case .pictureAndText:
            let t = read.trimmingCharacters(in: .whitespacesAndNewlines)
            return Delivery(picture: true, text: t.isEmpty ? nil : t, gapMs: 350)
        }
    }

    /// What each app is known to do with a picture paste followed by a text paste (Part C's table). "known" rows were
    /// read from how the app handles ⌘V of an image; every row needs one live check before it is relied on.
    static let apps: [(app: String, bundle: String, picture: String, status: String)] = [
        ("Claude", "com.anthropic.claudefordesktop", "attachment above the box", "needs a live test"),
        ("Codex", "com.openai.codex", "attachment above the box", "needs a live test"),
        ("Slack", "com.tinyspeck.slackmacgap", "attachment, the text stays in the box", "needs a live test"),
        ("Beeper", "com.automattic.beeper.desktop", "attachment preview, the text in the box", "needs a live test"),
        ("Notes", "com.apple.Notes", "inline picture, the text after it", "known"),
        ("Mail", "com.apple.mail", "inline picture, the text after it", "known"),
    ]
}

extension ShotTarget {
    /// The line glyph in the send-to list when the app's own icon is not on this Mac (Claude, Codex, Claude
    /// Code show their app icon when it is).
    var glyph: String {
        switch self {
        case .field: return "corner-down-left"; case .clipboard: return "clipboard"; case .file: return "download"
        case .claude, .codex, .ask: return "sparkle"; case .claudeCode: return "terminal"
        case .person: return "user"
        }
    }
}
