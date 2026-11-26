// Where each part of the voice strip goes (14 November 2026). Pure (Foundation and CoreGraphics only), so it builds
// alone in tests/strip_rules.swift. app/ComposerStrip.swift draws what this places; app/ClassicStrip.swift is the old
// one-row strip, restored as it was, and places itself.
//
// The user: "two places where typing happens at the same time", "when creating an input and sending it to the agent,
// it should be easily visible", "fix the notch". The composer:
//   - a band the height of the menu bar grows out of both sides of the camera housing (the notch, about 200 x 32 pt at
//     the top centre). Left of the housing: the state mark and the state word (Listening, Finishing, Draft ready, In the
//     field). Right of it: the user's level, then the keys ("↩ Insert · ⌥ Stop", "↩ Insert · Esc Drop"). Nothing readable
//     behind the housing.
//   - under the band, the words: large, in the primary text colour, 1 line growing to 4, then the older lines scroll up.
//   - no housing (an external display): a capsule at the top centre under the menu bar with the same content, the band's
//     content as its first row, no empty band.
// Every rect counts from the strip's top-left corner, y down.
import Foundation
import CoreGraphics   // CGRect geometry only; no AppKit

/// Setting `stripStyle`. Old values ("two", "a", "b", "c" from the try-out round) and unknown ones read as composer.
enum StripStyle: String, CaseIterable {
    case classic, composer
    static func of(_ s: String?) -> StripStyle { StripStyle(rawValue: s ?? "") ?? .composer }
    var name: String { self == .classic ? "Classic" : "Composer" }
}

/// What the strip shows, for its size.
enum StripMode: Equatable {
    case take(lines: Int, level: Bool, buttons: Bool = false)   // a voice note: the band, 0-4 lines of words, a row of keys
    case long(call: Bool)                       // a long recording or a call: title, levels, a point, Stop
    case offer(rows: Int)                       // a question (1-2 rows) and its keys as buttons, with time running out
    case message(lines: Int, button: Bool, inBand: Bool = false)   // a receipt or a text, maybe with Undo; inBand: one
                                                                   // short line beside the mark, in the band itself
}

struct StripLayout {
    var size: CGSize
    var hangs: Bool                 // hangs from the top edge of the screen (with a housing) or floats (a capsule)
    var top: CGFloat                // from the top edge of the screen to the strip's top
    var centre: CGFloat             // x in the strip that sits at the screen's centre (under the camera)
    var notch: CGRect               // the camera housing in strip coordinates (empty without one)
    var band: CGFloat               // the first row's height (the band beside the housing)
    var mark: CGRect                // the state mark
    var level: CGRect? = nil        // a note: the user's level
    var levels: [CGRect] = []       // a recording: me, then them (each a bar; a label sits left of it)
    var labels: [CGRect] = []       // "me", "them"
    var text: CGRect? = nil         // the words, a title, a question or a message
    var text2: CGRect? = nil        // a second row: a point, the rest of a question
    var state: CGRect? = nil        // the state word
    var hints: CGRect? = nil        // the keys
    var buttons: CGRect? = nil
    var countdown: CGRect? = nil
    /// Everything with letters in it.
    var readable: [CGRect] { [text, text2, state, hints].compactMap { $0 } + labels }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }
}

enum StripRules {
    static let gap: CGFloat = 10          // nothing readable comes closer to the housing's edge
    static let wing: CGFloat = 172        // each side of the housing
    static let line: CGFloat = 20         // one line of words
    static let maxLines = 4               // then the older lines scroll up
    static let row2: CGFloat = 36         // a row of buttons
    static let floatWidth: CGFloat = 560

    /// How far the strip reaches under the menu bar.
    static func below(_ l: StripLayout) -> CGFloat { l.hangs ? l.size.height - l.notch.height : l.size.height }

    /// `notch` 0: a screen without one. `bar`: the menu bar's height. `buttons`: the width of the buttons' row (0 = none).
    static func layout(_ m: StripMode, notch n: CGFloat, bar: CGFloat, screen: CGFloat = 1512, buttons bw: CGFloat = 0) -> StripLayout {
        let hangs = n > 0
        let hb: CGFloat = hangs ? max(28, bar) : 32
        let w = hangs ? min(2 * wing + n, screen - 40) : min(floatWidth, screen - 40)
        let side = hangs ? (w - n) / 2 : 0
        // the band: left part (mark, state) and right part (level, keys)
        let leftEnd = hangs ? side - gap : w / 2 - 10
        let rightStart = hangs ? side + n + gap + 2 : w - 16 - 200
        let mid = hb / 2
        var l = StripLayout(size: CGSize(width: w, height: hb), hangs: hangs, top: hangs ? 0 : bar + 6, centre: w / 2,
                            notch: hangs ? CGRect(x: side, y: 0, width: n, height: hb) : .zero, band: hb,
                            mark: CGRect(x: 14, y: mid - 8, width: 16, height: 16))
        l.state = CGRect(x: 36, y: 0, width: leftEnd - 36, height: hb)
        let pad: CGFloat = 18
        switch m {
        case .take(let lines, let level, let keys):
            let k = CGFloat(min(max(0, lines), maxLines))
            if level {
                l.level = CGRect(x: rightStart, y: mid - 8, width: 36, height: 16)
                l.hints = CGRect(x: rightStart + 46, y: 0, width: w - 14 - rightStart - 46, height: hb)
            } else {
                l.hints = CGRect(x: rightStart, y: 0, width: w - 14 - rightStart, height: hb)
            }
            if k > 0 {
                l.text = CGRect(x: pad, y: hb + 4, width: w - 2 * pad, height: k * line)
                l.size.height = hb + 4 + k * line + 12
            }
            if keys {   // the draft's keys as buttons, at the right end of a short row under the words
                let y = k > 0 ? hb + 4 + k * line + 4 : hb + 2
                l.buttons = CGRect(x: w - 12 - bw, y: y, width: bw, height: 26)
                l.size.height = y + 26 + 10
            }
        case .long(let call):
            let lab: CGFloat = 30
            var x = rightStart
            for i in 0..<(call ? 2 : 1) {
                if call { l.labels.append(CGRect(x: x, y: mid - 6, width: i == 0 ? 22 : lab, height: 12)); x += i == 0 ? 24 : lab + 2 }
                l.levels.append(CGRect(x: x, y: mid - 2, width: 44, height: 4)); x += 44 + 14
            }
            l.text = CGRect(x: pad, y: hb + 4, width: w - 2 * pad, height: line)
            let y2 = hb + 4 + line
            l.buttons = CGRect(x: pad - 4, y: y2 + 5, width: bw, height: 26)
            let t2 = pad - 4 + bw + (bw > 0 ? 12 : 0)
            l.text2 = CGRect(x: t2, y: y2, width: w - pad - t2, height: row2)
            l.size.height = y2 + row2 + 6
        case .offer(let rows):
            l.text = CGRect(x: pad, y: hb + 4, width: w - 2 * pad, height: line)
            var y = hb + 4 + line
            if rows >= 2 { l.text2 = CGRect(x: pad, y: y, width: w - 2 * pad, height: 20); y += 20 }
            l.buttons = CGRect(x: pad - 4, y: y + 6, width: bw, height: 26)
            l.size.height = y + 6 + 26 + 12
            l.countdown = CGRect(x: pad, y: l.size.height - 5, width: w - 2 * pad, height: 1.5)
        case .message(let lines, let button, let inBand):
            let k = CGFloat(max(1, lines))
            let end = button ? w - 14 - bw - 12 : w - pad
            if !hangs {
                // a capsule: the message is its first row, beside the mark (no empty band)
                l.state = nil
                l.text = CGRect(x: 36, y: 6, width: end - 36, height: k * 20)
                l.size.height = max(32, k * 20 + 12)
                l.mark = CGRect(x: 14, y: (lines > 1 ? 8 : (l.size.height - 16) / 2), width: 16, height: 16)
                if button { l.buttons = CGRect(x: w - 14 - bw, y: (l.size.height - 26) / 2, width: bw, height: 26) }
            } else if inBand {
                // one short line beside the mark, left of the housing; its button right of the housing
                l.text = l.state; l.state = nil
                if button { l.buttons = CGRect(x: max(rightStart, w - 14 - bw), y: (hb - 26) / 2, width: bw, height: 26) }
            } else {
                l.text = CGRect(x: pad, y: hb + 6, width: end - pad, height: k * 20)
                l.size.height = hb + 6 + k * 20 + 12
                if button { l.buttons = CGRect(x: w - 14 - bw, y: hb + 6 + 10 - 13, width: bw, height: 26) }
            }
        }
        return l
    }

    // MARK: the words

    /// The lines of the words to show: wrapped to `room`, at most `maxLines`, the newest last. When older lines were
    /// left out the first shown line starts with "… ". `measure` gives a text's width.
    static func lines(_ text: String, room: CGFloat, max k: Int = maxLines, measure: (String) -> CGFloat) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if t.isEmpty { return [] }
        var out: [String] = [], cur = ""
        for w in t.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let next = cur.isEmpty ? w : cur + " " + w
            if cur.isEmpty || measure(next) <= room { cur = next } else { out.append(cur); cur = w }
            // a single word wider than the room: cut from its start (the newest letters stay)
            while measure(cur) > room, cur.count > 1 { cur.removeFirst() }
        }
        if !cur.isEmpty { out.append(cur) }
        if out.count > k {
            out = Array(out.suffix(k))
            var first = "… " + out[0]
            while measure(first) > room, first.count > 3 { first.removeLast() }
            out[0] = first
        }
        return out
    }

    /// Where the newest `k` words start (a character offset): partial words may be one step quieter than these.
    static func newestFrom(_ shown: String, words k: Int = 3) -> Int {
        var seen = 0, i = shown.count
        let chars = Array(shown)
        while i > 0 {
            while i > 0, chars[i - 1] == " " { i -= 1 }
            if i == 0 { break }
            while i > 0, chars[i - 1] != " " { i -= 1 }
            seen += 1
            if seen == k { break }
        }
        if seen < k { return 0 }
        return i
    }

    // MARK: checks (the test and the preview run these)

    /// What is wrong with a layout; empty when nothing.
    static func problems(_ l: StripLayout, _ m: StripMode) -> [String] {
        var bad: [String] = []
        let b = l.bounds.insetBy(dx: -0.5, dy: -0.5)
        func inside(_ r: CGRect?, _ what: String) { if let r, r.width > 0, !b.contains(r) { bad.append("\(what) outside the strip") } }
        func apart(_ a: CGRect?, _ c: CGRect?, _ what: String) {
            if let a, let c, a.width > 0, c.width > 0, a.intersects(c) { bad.append(what) }
        }
        for (i, r) in l.readable.enumerated() { inside(r, "readable \(i)") }
        inside(l.level, "level"); inside(l.buttons, "buttons"); inside(l.mark, "mark")
        for (i, r) in l.levels.enumerated() { inside(r, "level row \(i)") }
        for r in l.readable where r.width < 1 { bad.append("a readable part has no room") }
        if l.notch.width > 0 {
            for r in l.readable + [l.mark] + l.levels + [l.level, l.buttons].compactMap({ $0 }) where r.intersects(l.notch) {
                bad.append("something behind the housing at \(Int(r.minX)),\(Int(r.minY))")
            }
            // the words sit below the band, never beside the housing
            if case .message(_, _, true) = m {} else {
                for r in [l.text, l.text2].compactMap({ $0 }) where r.minY < l.band - 0.5 { bad.append("words in the band") }
            }
        }
        for lv in [l.level].compactMap({ $0 }) + l.levels {
            for r in l.readable { apart(lv, r, "level over text") }
            apart(lv, l.buttons, "level over a button")
        }
        for r in [l.text, l.text2, l.state, l.hints] { apart(r, l.buttons, "a button over text") }
        apart(l.state, l.hints, "state over the keys")
        apart(l.mark, l.text, "mark over the words"); apart(l.mark, l.state, "mark over the state")
        if case .take(let k, _, _) = m, k <= maxLines, let t = l.text, t.height < CGFloat(k) * line - 0.5 { bad.append("no room for \(k) lines") }
        if !l.hangs, l.size.height > 0, l.band > 0, case .take(0, _, false) = m, l.size.height > l.band + 0.5 { bad.append("an empty row under the capsule") }
        return bad
    }

    /// Keys written one way in the strip and in Help (14 November 2026, the lead: "⇧ right ⌥" was hard to read): the
    /// words where there is room, the glyphs only where the row is tight (then the tooltip gives the words).
    enum Key: CaseIterable { case rightOption, shiftRightOption, doubleRightOption, ret, esc, tab, ctrlOptR }
    static func key(_ k: Key, tight: Bool = false) -> String {
        switch k {
        case .rightOption: return tight ? "⌥" : "Right Option"
        case .shiftRightOption: return tight ? "⇧⌥" : "⇧ Right Option"
        case .ret: return tight ? "↩" : "Return"
        case .esc: return "Esc"
        case .tab: return tight ? "⇥" : "Tab"
        case .doubleRightOption: return tight ? "⌥⌥" : "Right Option twice"
        case .ctrlOptR: return "⌃⌥R"
        }
    }
    /// The key that puts the last take in again (keys round two): the double tap while `againTap` is on, else the user's
    /// `againKey` chord, else none (the hint then says nothing about it).
    static func againKey(tap: Bool, chord: String, tight: Bool = true) -> String? {
        if tap { return key(.doubleRightOption, tight: tight) }
        let c = chord.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? nil : c
    }

    /// The theme's colour jobs the composer draws letters with (contrast-checked on black in tests). The words are
    /// ink; partial words one step quieter (muted), never fainter.
    static let textJobs = ["ink", "muted", "warn", "mint"]   // words on the strip (never the faint grey: too dim on black); warn: "No text field in …" on a draft; mint: "In the field" while the user still speaks
}
