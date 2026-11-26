// Screen context as a conversation (14 November 2026, the user: "some screenshot use would be useful here. cotypist
// definitely had it"). Pure rules, so this file compiles alone in tests: Vision's lines with boxes -> messages (blocks)
// -> who wrote each -> the tail the model reads under a budget. Plus when to capture and which source to trust per app.
// The runtime (capture, Vision, the cache) is app/ScreenContext.swift. Nothing here logs or stores text.
import Foundation

enum ScreenContextRules {
    /// Characters of screen text a request carries. The engine's window keeps the last 1,000 (up to 1.5 x) for the
    /// local model (engine/server.py CTX_CHARS); Claude helpers read up to 2,500. The context sweep tests 500-3,000
    /// (bench/screen_context.py); change it only from that measurement.
    static let budget = 1_600
    /// Marks the engine reads (engine/prompt.py SPEAKERS): the user's lines, the other person's, an assistant's answer. Same
    /// words as the call transcripts ("Я:" / "Вони:", app/Recording.swift) and the bench replay sets.
    static let me = "Я: ", them = "Вони: ", assistant = "Асистент: "

    // MARK: lines and blocks

    /// One line Vision read, its box in the captured part: 0...1, origin top left, y down.
    struct Line: Equatable {
        var text: String
        var x: Double, y: Double, w: Double, h: Double
        var right: Double { x + w }
        var bottom: Double { y + h }
        var mid: Double { x + w / 2 }
    }
    enum Who: Equatable { case me, them, assistant }
    /// One message: lines that sit together.
    struct Block: Equatable {
        var lines: [Line]
        var who: Who?
        var text: String { lines.map { $0.text }.joined(separator: " ") }
        var x: Double { lines.map { $0.x }.min() ?? 0 }
        var right: Double { lines.map { $0.right }.max() ?? 0 }
        var y: Double { lines.map { $0.y }.min() ?? 0 }
        var bottom: Double { lines.map { $0.bottom }.max() ?? 0 }
    }

    /// Interface words that are never a message (whole line, any case, trailing punctuation ignored).
    static let chrome: Set<String> = [
        "reply", "send", "copy", "retry", "edit", "edited", "share", "like", "react", "more", "message", "type a message",
        "write a message", "search", "new chat", "today", "yesterday", "read", "delivered", "seen", "sent", "forwarded",
        "reply to claude", "send a message", "ask anything", "thinking", "show more", "show less", "copy code", "done",
        "сьогодні", "вчора", "відповісти", "надіслати", "копіювати", "повідомлення", "написати повідомлення", "ред.",
        "змінено", "переслано", "прочитано", "доставлено", "пошук", "ще", "показати більше",
    ]
    static let chromePrefixes = ["claude can make mistakes", "chatgpt can make mistakes", "claude is ai and can make mistakes",
                                 "type a message", "write a message", "reply to ", "message @", "message #"]
    private static let timeOnly = try! NSRegularExpression(
        pattern: #"^(\d{1,2}[:.]\d{2}(\s?[ap]\.?m\.?)?|\d{1,2}\s?(m|h|d|min|хв|год)|(today|yesterday|сьогодні|вчора)(,| at| о)?\s*\d{1,2}[:.]\d{2}|\d{1,2}[./]\d{1,2}([./]\d{2,4})?)$"#,
        options: [.caseInsensitive])
    private static let timeTail = try! NSRegularExpression(pattern: #"\s+\d{1,2}[:.]\d{2}(\s?[ap]\.?m\.?)?(\s?[✓✔︎]+)?$"#, options: [.caseInsensitive])

    static func squash(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// True for interface text: buttons, a time alone, a lone letter or number, a menu word.
    static func isChrome(_ t: String) -> Bool {
        let s = squash(t).trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?…·•|>›»-–—()[]"))
        if s.count < 3 { return true }
        if !s.contains(where: { $0.isLetter }) { return true }
        if chrome.contains(s) { return true }
        if chromePrefixes.contains(where: { s.hasPrefix($0) }) { return true }
        return timeOnly.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The lines worth reading: above the field (`cut`, 0...1 from the top; nil = all), inside the conversation's column
    /// (`column`: the field's left and right edges, 0...1; nil = all), not interface text and not the text the user is typing
    /// in the field now (`typing`, the field's text before the caret). Trailing times ("… 14:02") are cut off.
    static func clean(_ lines: [Line], cut: Double? = nil, column: (Double, Double)? = nil, typing: String = "") -> [Line] {
        let typed = squash(String(typing.suffix(600)))
        return lines.compactMap { l in
            if let cut, l.y + l.h / 2 > cut { return nil }
            if let (a, b) = column, l.mid < a - 0.04 || l.mid > b + 0.04 { return nil }
            var t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            t = timeTail.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
            if isChrome(t) { return nil }
            let s = squash(t)
            if s.count >= 6, typed.contains(s) { return nil }   // the user's own text in the field, seen again in the picture
            var out = l; out.text = t
            return out
        }
    }

    /// Lines -> messages, top to bottom: a line joins the block above it when the gap between them is under ~0.8 of a
    /// line and their left edges (or right edges, for right-aligned bubbles) line up.
    static func blocks(_ lines: [Line]) -> [Block] {
        let sorted = lines.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
        guard !sorted.isEmpty else { return [] }
        let hs = sorted.map { $0.h }.sorted()
        let lineH = max(0.004, hs[hs.count / 2])
        var out: [Block] = []
        for l in sorted {
            if var b = out.last, let last = b.lines.last {
                let gap = l.y - last.bottom
                let aligned = abs(l.x - last.x) < 0.03 || abs(l.right - last.right) < 0.03
                let sameRow = l.y < last.bottom - lineH * 0.3   // side by side on one row: two blocks
                if gap < lineH * 0.8, aligned, !sameRow {
                    b.lines.append(l); out[out.count - 1] = b; continue
                }
            }
            out.append(Block(lines: [l], who: nil))
        }
        return out
    }

    /// Who wrote each block, from where it sits in the column (`column`, 0...1; nil = the blocks' own extent).
    /// Chat and AI apps both draw the user's messages as bubbles on the right and the other side on the left (an assistant's
    /// answer runs the full width). With no right-hand block at all (Slack, a mail thread) nobody is named: a wrong
    /// mark is worse than none.
    static func speakers(_ blocks: [Block], kind: String, column: (Double, Double)? = nil) -> [Block] {
        guard !blocks.isEmpty, kind == "chat" || kind == "ai" else { return blocks }
        let a = column?.0 ?? (blocks.map { $0.x }.min() ?? 0)
        let b = column?.1 ?? (blocks.map { $0.right }.max() ?? 1)
        let w = max(0.05, b - a)
        func mine(_ k: Block) -> Bool { k.x > a + 0.25 * w && k.right > b - 0.18 * w }
        guard blocks.contains(where: mine) else { return blocks }
        return blocks.map { k in
            var k = k
            k.who = mine(k) ? .me : (kind == "ai" ? .assistant : .them)
            return k
        }
    }

    // MARK: the tail under a budget

    /// What the model reads, oldest first: the other side's last message in full when it fits (else its end), the user's own
    /// last message, then earlier ones from the newest back while `budget` characters last.
    static func tail(_ blocks: [Block], budget: Int = budget) -> [Block] {
        guard !blocks.isEmpty, budget > 0 else { return [] }
        var keep = Set<Int>(), used = 0
        func size(_ i: Int) -> Int { blocks[i].text.count + 1 + (blocks[i].who == nil ? 0 : 7) }
        func take(_ i: Int) -> Bool {
            if keep.contains(i) { return true }
            guard used + size(i) <= budget else { return false }
            keep.insert(i); used += size(i); return true
        }
        var out = blocks
        let lastOther = blocks.lastIndex { $0.who == .them || $0.who == .assistant }
        if let i = lastOther, !take(i) {
            // longer than the whole budget: its end (the part nearest the field) is what the user answers
            var b = blocks[i]; let room = max(0, budget - 8)
            let t = String(b.text.suffix(room))
            b.lines = [Line(text: t, x: b.x, y: b.y, w: b.right - b.x, h: b.bottom - b.y)]
            out[i] = b; keep.insert(i); used = budget
        }
        if let j = blocks.lastIndex(where: { $0.who == .me }), lastOther.map({ j > $0 - 3 }) ?? true { _ = take(j) }
        for i in stride(from: blocks.count - 1, through: 0, by: -1) where !keep.contains(i) {
            if !take(i) { break }
        }
        return keep.sorted().map { out[$0] }
    }

    /// One line per message, marked with who wrote it when known.
    static func render(_ blocks: [Block]) -> String {
        blocks.map { b in
            let mark = b.who.map { $0 == .me ? me : $0 == .them ? them : assistant } ?? ""
            return mark + b.text
        }.joined(separator: "\n")
    }

    /// Everything above in one call: Vision lines -> the marked tail.
    static func conversation(_ lines: [Line], kind: String, cut: Double? = nil, column: (Double, Double)? = nil,
                             typing: String = "", budget: Int = budget) -> (text: String, blocks: Int, marked: Int) {
        let bs = speakers(blocks(clean(lines, cut: cut, column: column, typing: typing)), kind: kind, column: column)
        let t = tail(bs, budget: budget)
        return (render(t), t.count, t.filter { $0.who != nil }.count)
    }

    // MARK: which source

    /// Accessibility text is clean when it holds a few real lines, not a page of labels: measured 14 November on the user's
    /// sent lines' screen text (Claude app 9.9% short lines, Beeper 4.2%, ChatGPT 8.0%; Dia 56% short and 14% repeated).
    static func axClean(_ text: String) -> Bool {
        guard text.count >= 120 else { return false }
        let ls = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ls.isEmpty else { return false }
        let short = ls.filter { $0.split(separator: " ").count < 4 }.count
        let dup = ls.count - Set(ls).count
        return Double(short) / Double(ls.count) <= 0.35 && Double(dup) / Double(ls.count) <= 0.12
    }

    enum Source: Equatable { case ax, screen }

    /// Per app: how the picture fared, so an app where it fails or reads nothing stops being captured for a while.
    struct AppMemory: Equatable {
        var good = 0, bad = 0, badInRow = 0
        var until: Double = 0   // seconds since 1970: no capture for this app before then
        mutating func note(ok: Bool, now: Double) {
            if ok { good += 1; badInRow = 0; until = 0; return }
            bad += 1; badInRow += 1
            if badInRow >= 3 { until = now + min(600, 30 * pow(2, Double(badInRow - 3))) }
        }
        func allowed(_ now: Double) -> Bool { now >= until }
    }

    /// Accessibility where it is clean (exact text, ~25 ms, and the Beeper chat finder matches its lines), the picture
    /// where it is empty or a page of labels, unless the picture keeps failing in this app.
    static func source(ax: String, memory: AppMemory, now: Double) -> Source {
        if axClean(ax) { return .ax }
        return memory.allowed(now) ? .screen : .ax
    }

    // MARK: when to capture

    /// focus: a field read for the first time; request: a ghost request found kept text over 2 s old (a look first);
    /// scroll, moved: the window changed; poll: the 4 s look while the user types.
    enum Why: Equatable { case focus, scroll, moved, poll, request }
    enum When: Equatable { case now, later(Double), no }
    /// Never per key: on focus of a field, when the window scrolls or moves (at most one capture per `gap` seconds), and
    /// a cheap look when the user pauses typing for `pause` seconds: once per pause, at most every `poll` seconds (speed plan
    /// item 5, step 4: looks every 4 s while the user typed came to 17.4 captures a typing minute). None after `idle` s.
    static func when(_ why: Why, now: Double, lastCapture: Double, lastKey: Double, gap: Double = 1.5,
                     poll: Double = 10, pause: Double = pause, idle: Double = 60) -> When {
        if why != .focus, now - lastKey > idle { return .no }
        let since = now - lastCapture
        if looks(why) {
            if lastCapture >= lastKey { return .no }              // looked since the user's last key: one per pause
            let quiet = now - lastKey
            if quiet < pause { return .later(pause - quiet) }     // still typing: when the user stops
            return since >= poll ? .now : .no
        }
        return since >= gap ? .now : .later(gap - since)
    }

    /// A typing pause, in seconds: the looks wait for it.
    static let pause = 1.0

    /// A cheap 96 px look first, the full read only when it changed or the window moved (17 November 2026: requests read
    /// the window in full every 2 s while the user typed, 14-15 reads a typing minute, each p50 0.5 s of text recognition).
    static func looks(_ why: Why) -> Bool { why == .poll || why == .request }

    /// Two 96 px gray looks differ enough to read again: more than `frac` of the pixels moved by more than `step` (a new
    /// one-line message changes ~100 of ~9,000; a "1m ago" turning into "2m ago" changes under 15). Other sizes: changed.
    static func lookChanged(_ a: [UInt8], _ b: [UInt8], frac: Double = 0.0015, step: Int = 24) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var n = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > step { n += 1 }
        return Double(n) / Double(a.count) > frac
    }

    /// The cached text is used at once while it is this young (seconds); older is still used, and a fresh capture runs.
    static let fresh = 2.0
    /// A capture older than this is dropped (the chat may be another one now).
    static let stale = 600.0

    /// The part of the window to read, in the window's own points (top left): from `above` points over the field's top
    /// (`fieldTop`; else the caret's top; else 85% down the window, where most apps put the box) to that line.
    static func region(window: (w: Double, h: Double), fieldTop: Double?, caretTop: Double?, above: Double = 900) -> (y: Double, h: Double)? {
        let cut = [fieldTop, caretTop].compactMap { $0 }.first { $0 > 20 && $0 <= window.h } ?? window.h * 0.85
        let top = max(0, cut - above)
        let h = cut - top
        return h > 20 ? (top, h) : nil
    }

    /// Pixel size for Vision: the display's scale, at least 2 so small chat text reads, at most ~3 MP and 2,600 wide.
    static func pixels(w: Double, h: Double, scale: Double) -> (Int, Int) {
        var s = max(2, scale)
        s = min(s, 2600 / max(1, w))
        let mp = w * h * s * s
        if mp > 3_000_000 { s *= (3_000_000 / mp).squareRoot() }
        return (max(1, Int(w * s)), max(1, Int(h * s)))
    }
}
