// Places to fill in a snippet (1 November 2026; TextExpander fill-ins, VS Code snippets). A snippet like
// "Hi {name}, the call is {day:Mon|Tue} at {time=15:00}.{cursor}" goes in whole; the first place is selected, so typing
// replaces it. Tab jumps to the next place, ↑ ↓ change a choice, a second {name} takes what he typed in the first, and
// after the last place Tab puts the caret at {cursor} (or the end). Esc, Return, a click, arrows, a shortcut or
// another app end it; so do 3 minutes without a key. Everything is done with arrow keys, so it works the same in
// native fields and in Chromium boxes: the text after the caret is the snippet's own until he reaches it.
//
// Also the use count per shortcut (TextExpander's statistics): data/snippet-stats.json, shown on the Shortcuts page.
import AppKit
import Carbon

enum Fields {
    struct Stop { let name: String; let at: Int; let len: Int; var text = ""; let options: [String]; let copy: Bool
        init(name: String, at: Int, len: Int, text: String = "", options: [String], copy: Bool) {
            self.name = name; self.at = at; self.len = len; self.text = text; self.options = options; self.copy = copy
        }
    }

    final class Session {
        let stops: [Stop], final: Int, pid: pid_t, el: AXUIElement
        var i = 0
        var untouched = true       // no key of his in this place yet: its text is the snippet's own (and selected)
        var now = ""               // that text while untouched (the default, or the chosen option)
        var typed = ""             // what he typed here once he started
        var known = true           // `typed` is all the place holds
        var option = 0
        var values: [String: String] = [:]
        var delta: [Int: Int] = [:]   // place -> its length now minus its length in the snippet
        var last = Date()
        init(stops: [Stop], final: Int, pid: pid_t, el: AXUIElement) { self.stops = stops; self.final = final; self.pid = pid; self.el = el }
    }
    static var cur: Session?

    static func end(_ why: String = "") {
        guard cur != nil else { return }
        cur = nil
        if debugLog, !why.isEmpty { log("fields end: \(why)") }
    }

    static var active: Bool {
        guard let s = cur else { return false }
        if Date().timeIntervalSince(s.last) > 180 { end("idle"); return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != s.pid { end("app"); return false }
        return true
    }

    /// Before Drafter moves or types: still the field the snippet went into, and no secure input (Codex review
    /// 2026-11-01: an app that moved the focus by itself got the next Tab's text).
    static func here(_ s: Session) -> Bool {
        guard active, !IsSecureEventInputEnabled(), let f = Focus.focused(), CFEqual(f, s.el) else { end("field changed"); return false }
        return true
    }

    static func arrows(_ code: CGKeyCode, _ n: Int, shift: Bool = false, alt: Bool = false) {
        guard n > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<n {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
                e?.flags = CGEventFlags(rawValue: (shift ? CGEventFlags.maskShift.rawValue : 0) | (alt ? CGEventFlags.maskAlternate.rawValue : 0))
                e?.setIntegerValueField(.eventSourceUserData, value: Focus.mark); e?.post(tap: .cghidEventTap)
            }
        }
    }
    static func left(_ n: Int, shift: Bool = false) { arrows(123, n, shift: shift) }
    static func right(_ n: Int, shift: Bool = false) { arrows(124, n, shift: shift) }

    /// Right after the snippet was typed, the caret at its end.
    static func start(_ f: Snippets.Filled, pid: pid_t, el: AXUIElement) {
        guard let first = f.stops.first else { return }
        let n = f.text.count
        let s = Session(stops: f.stops, final: f.final ?? n, pid: pid, el: el)
        cur = s
        left(n - first.at)
        enter(s, 0)
        Ghost.shared.flash(f.stops.filter { !$0.copy }.count > 1 ? "Tab · next place" : "Tab · done")
        log("fields: \(f.stops.count) places")
    }

    /// The caret is at the start of place i: select its text.
    static func enter(_ s: Session, _ i: Int) {
        let st = s.stops[i]
        s.i = i; s.untouched = true; s.typed = ""; s.known = true; s.option = 0
        s.now = st.options.first ?? st.text
        if st.len > 0 { right(st.len, shift: true) }
    }

    /// His key while places are open. true = Drafter takes it.
    static func key(_ code: Int64, typed: String, mods: CGEventFlags) -> Bool {
        guard active, let s = cur else { return false }
        s.last = Date()
        let st = s.stops[s.i]
        switch code {
        case 48 where mods.isEmpty:                                          // Tab: the next place
            DispatchQueue.main.async { next() }; return true
        case 125 where mods.isEmpty, 126 where mods.isEmpty:                                  // ↓ ↑ on a choice
            if s.untouched, st.options.count > 1 { DispatchQueue.main.async { cycle(code == 125 ? 1 : -1) }; return true }
            end("arrow"); return false
        case 51 where mods.isEmpty:                                           // Backspace
            if s.untouched {
                if s.now.isEmpty { end("backspace before the place") } else { s.untouched = false; s.typed = "" }
            } else if !s.typed.isEmpty { s.typed.removeLast() } else { end("backspace before the place") }
            return false
        case 36, 76, 53, 48, 123, 124, 125, 126, 115, 116, 117, 119, 121:    // Return, Esc, ⇧Tab, arrows, Home/End/Page
            end("key \(code)"); return false
        default:
            if !mods.subtracting([.maskShift, .maskAlternate]).isEmpty { end("shortcut"); return false }
            guard !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) else { return false }
            if s.untouched { s.untouched = false; s.typed = typed } else { s.typed += typed }
            return false
        }
    }

    /// ↓ ↑: the next or previous choice, selected again.
    static func cycle(_ dir: Int) {
        guard let s = cur, s.untouched else { return }
        guard here(s) else { arrows(dir == 1 ? 125 : 126, 1); return }   // the key goes on to wherever he is now
        let opts = s.stops[s.i].options
        s.option = (s.option + dir + opts.count) % opts.count
        let o = opts[s.option]
        if o.isEmpty { if !s.now.isEmpty { Focus.backspace(1) } }
        else { Focus.typeText(o); left(o.count, shift: true) }
        s.now = o
    }

    /// Tab: leave this place (keep what it holds), fill copies of it on the way, select the next place.
    static func next() {
        guard let s = cur else { return }
        guard here(s) else { arrows(48, 1); return }   // his Tab goes on to wherever he is now
        Keys.shared.cancel()
        let st = s.stops[s.i]
        let value: String? = s.untouched ? s.now : (s.known ? s.typed : nil)
        if s.untouched, !s.now.isEmpty { right(1) }                       // the selection ends: the caret goes to its end
        if let value, !st.name.isEmpty, s.values[st.name] == nil { s.values[st.name] = value }
        s.delta[s.i] = value.map { $0.count - st.len }
        var end = st.at + st.len
        var j = s.i + 1
        while j < s.stops.count {
            let nx = s.stops[j]
            right(nx.at - end)
            if nx.copy, let v = s.values[nx.name] {
                if v == nx.text { right(nx.len) }
                else {
                    if nx.len > 0 { right(nx.len, shift: true) }
                    if v.isEmpty { if nx.len > 0 { Focus.backspace(1) } } else { Focus.typeText(v) }
                }
                s.delta[j] = v.count - nx.len
                end = nx.at + nx.len; j += 1
                continue
            }
            enter(s, j)
            if debugLog { log("fields: place \(j + 1) of \(s.stops.count)") }
            return
        }
        // no place left: the caret goes to {cursor} or the end
        if s.final >= end { right(s.final - end) }
        else {
            var back = end - s.final
            for (k, p) in s.stops.enumerated() where p.at >= s.final && p.at + p.len <= end {
                guard let d = s.delta[k] else { back = -1; break }
                back += d
            }
            if back > 0 { left(back) }
        }
        cur = nil
        log("fields done")
    }

    // MARK: use counts

    static var statsFile: URL { Home.data.appendingPathComponent("snippet-stats.json") }
    static func stats() -> [String: [String: Any]] {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: statsFile))) as? [String: [String: Any]]) ?? [:]
    }
    /// One use of a shortcut: how many characters he typed for it and how many went in.
    static func used(_ key: String, typed: Int, put: Int) {
        guard !key.isEmpty, !["clip", "fact", "lookup"].contains(key) else { return }
        var all = stats()
        var row = all[key] ?? [:]
        row["uses"] = (row["uses"] as? Int ?? 0) + 1
        row["saved"] = (row["saved"] as? Int ?? 0) + max(0, put - typed)
        row["last"] = ISO8601DateFormatter().string(from: Date())
        all[key] = row
        if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: statsFile, options: .atomic) }
    }
    /// "12 uses · 840 characters you did not type" for the Shortcuts page.
    static func summary() -> String {
        let rows = stats().values
        let uses = rows.reduce(0) { $0 + ($1["uses"] as? Int ?? 0) }, saved = rows.reduce(0) { $0 + ($1["saved"] as? Int ?? 0) }
        return uses == 0 ? "" : "\(uses) uses so far · \(saved) characters you did not type"
    }
    static func uses(_ key: String) -> Int { stats()[key]?["uses"] as? Int ?? 0 }
}
