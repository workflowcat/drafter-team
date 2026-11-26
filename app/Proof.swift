// The "Fix N" chip's path (from the Claude proofread of 1 November 2026; its Claude part went on 2026-11-17). The local
// reader check (app/Reader.swift, engine/reader.py) puts its word fixes in `pending` and shows "⇥ Fix N · old → new";
// Tab puts the fixes in place, one word at a time (the user's formatting stays), the caret goes back where it was, and each
// fixed word keeps a dotted line with the user's own word in a chip to undo it (FixMarks). Nothing changes unless the field
// still holds exactly the text that was checked.
import AppKit
import ApplicationServices
import Carbon

enum Proof {
    struct Pending { let el: AXUIElement; let pid: pid_t; let before: String; let text: String; let caret: Int; let web: Bool; let edits: [[String: Any]]; let fixed: String }
    static var pending: Pending?

    /// The part of the field that is checked: from the last blank line (or the field start), at most 800 characters,
    /// starting at a word.
    static func span(_ before: String) -> String {
        var t = before
        if let r = t.range(of: "\n\n", options: .backwards) { t = String(t[r.upperBound...]) }
        if (t as NSString).length > 800 {
            t = String(t.suffix(800))
            if let i = t.firstIndex(where: { $0 == " " || $0 == "\n" }) { t = String(t[t.index(after: i)...]) }
        }
        return t
    }

    /// Where the field is (AppKind.swift): ai, chat, mail or other (the reader check runs in chats).
    static func kind(_ s: Spot) -> String {
        AppKind.of(s.app.bundleIdentifier ?? "", title: s.title, ai: Keys.aiApps, chats: Keys.chatApps, browsers: Keys.browsers, aiTitle: Keys.aiTitle)
    }

    /// Tab on the chip.
    static func apply() {
        guard Autocorrect.refresh(), let p = pending else { return }
        pending = nil
        guard let now = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(now.el, p.el), now.app.processIdentifier == p.pid,
              now.before == p.before else { Ghost.shared.flash("Text has changed"); return }
        let el = p.el
        AXUIElementSetMessagingTimeout(el, AXOff.timeout)
        let fm = FixMarks.shared
        let text16 = (p.text as NSString).length
        // edits as UTF-16 places in the checked text, last first, so earlier places stay right while the later change
        let list = p.edits.compactMap { e -> (at: Int, len: Int, old: String, new: String)? in
            guard let at = e["at"] as? Int, let len = e["len"] as? Int, let old = e["old"] as? String, let new = e["new"] as? String,
                  (!old.split(whereSeparator: { $0.isWhitespace }).contains(where: { Autocorrect.known(String($0)) }) ||
                   CorrectionRules.spacing(old, new, word: { Autocorrect.known($0) || Spell.known($0, "en") || Spell.known($0, "uk") })),
                  at >= 0, at + len <= text16, (p.text as NSString).substring(with: NSRange(location: at, length: len)) == old else { return nil }
            return (at, len, old, new)
        }.sorted { $0.at > $1.at }
        guard !list.isEmpty else { return }
        var places: [(AXTextMarker, AXTextMarker)] = []
        if now.viaMarkers {
            // all places first, while the text is as checked: one walk back from the caret
            guard let caret = fm.caretMarker(el) else { Ghost.shared.flash("Could not fix"); return }
            var walk = [caret]
            let far = text16 - (list.last?.at ?? 0)
            for _ in 0..<(far + 30) { guard let q = fm.prev(el, walk.last!) else { break }; walk.append(q) }
            for e in list {
                let d = text16 - e.at
                var hit: (AXTextMarker, AXTextMarker)?
                for i in ([d] + Array((d + 1)...(d + 30)) + [d - 1, d - 2]) where i >= e.len && i < walk.count {
                    if fm.same(fm.text(el, walk[i], walk[i - e.len]), e.old) { hit = (walk[i], walk[i - e.len]); break }
                }
                guard let hit else { log("proofread: \(e.old) not found"); Ghost.shared.flash("Could not fix"); return }
                places.append(hit)
            }
        }
        Keys.shared.cancel()
        Run(p: p, now: now, list: list, places: places).step(0)
    }

    typealias Edit = (at: Int, len: Int, old: String, new: String)

    /// One edit at a time: select the word, type the new one, and go on only once the keys have landed. Typed keys
    /// pass Drafter's own event tap on the main thread, so the wait must not block it (2026-11-01, Chrome: a blocking
    /// wait never saw them, and without a wait the next selection came first and the word was typed over it).
    final class Run {
        let p: Pending, now: Spot, list: [Edit], places: [(AXTextMarker, AXTextMarker)], el: AXUIElement
        let fm = FixMarks.shared, text16: Int, rev = Keys.shared.inputRevision
        var done: [Edit] = []
        init(p: Pending, now: Spot, list: [Edit], places: [(AXTextMarker, AXTextMarker)]) {
            self.p = p; self.now = now; self.list = list; self.places = places; el = p.el; text16 = (p.text as NSString).length
        }

        /// Still the user's field, and no key or click of theirs since Tab (Codex review 2026-11-01: a later step could select
        /// and type into text the user had typed meanwhile, or into another field).
        var still: String? {
            if Keys.shared.inputRevision != rev { return "user typed" }
            if IsSecureEventInputEnabled() { return "secure input" }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != p.pid { return "another app" }
            guard let f = Focus.focused(), CFEqual(f, el) else { return "another field" }
            return nil
        }

        /// Stopped part way: what went in stays, the caret is left where it is and nothing is marked.
        func stop(_ why: String) {
            log("proofread stopped after \(done.count) of \(list.count): \(why)")
            Ghost.shared.flash(done.isEmpty ? "Could not fix" : "Fixed \(done.count) of \(list.count)")
        }

        func settled(_ ok: () -> Bool) -> Bool {
            for i in 0..<8 { if ok() { return true }; if i < 7 { usleep(25_000) } }
            return false
        }

        /// The text just before the caret is the new word.
        func landed(_ new: String) -> Bool {
            let n = (new as NSString).length
            if now.viaMarkers {
                guard let c = fm.caretMarker(el) else { return false }
                var m = c
                for _ in 0..<n { guard let q = fm.prev(el, m) else { return false }; m = q }
                return fm.same(fm.text(el, m, c), new)
            }
            // the value, not StringForRange: Chrome's textarea did not answer that one
            guard let r = Focus.range(el), r.length == 0, r.location >= n, let v: String = Focus.attr(el, kAXValueAttribute) else { return false }
            let ns = v as NSString
            return r.location <= ns.length && fm.same(ns.substring(with: NSRange(location: r.location - n, length: n)), new)
        }

        func step(_ i: Int) {
            if let why = still { stop(why); return }
            guard i < list.count else { finish(); return }
            let e = list[i]
            if now.viaMarkers {
                let place = places[i]
                guard AXUIElementSetAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, AXTextMarkerRangeCreate(nil, place.0, place.1)) == .success,
                      settled({ fm.same(fm.selected(el), e.old) }) else { log("proofread: selection did not take (markers)"); finish(); return }
            } else {
                let at = p.caret - text16 + e.at
                var sel = CFRange(location: at, length: e.len)
                guard let arg = AXValueCreate(.cfRange, &sel), AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, arg) == .success,
                      settled({ Focus.range(el).map { $0.location == at && $0.length == e.len } ?? false }) else {
                    log("proofread: selection did not take (range)"); finish(); return
                }
                if !p.web, Focus.setSelectedText(el, e.new) == .success {
                    done.append(e); step(i + 1); return
                }
            }
            Focus.typeText(e.new)
            wait(e, i, tries: 40)
        }

        func wait(_ e: Edit, _ i: Int, tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                if self.landed(e.new) { self.done.append(e); self.step(i + 1) }
                else if let why = self.still { self.stop(why) }
                else if tries > 0 { self.wait(e, i, tries: tries - 1) }
                else { self.stop("typing did not land") }   // unconfirmed: it may land later, so the caret stays
            }
        }

        func finish() {
            guard !done.isEmpty else { Ghost.shared.flash("Could not fix"); return }
            // the text as it is now (only the edits that went in) and the caret back at its end
            var fixed = p.text as NSString
            for e in done { fixed = fixed.replacingCharacters(in: NSRange(location: e.at, length: e.len), with: e.new) as NSString }
            let fixed16 = fixed.length
            if now.viaMarkers || p.web {
                // after the earliest fix the caret sits at its end: walk right over what follows
                let first = done.last!
                let rest = fixed.substring(from: min(first.at + (first.new as NSString).length, fixed16)).count
                if rest > 0 { FixMarks.arrowRight(rest) }
            } else {
                var c = CFRange(location: p.caret - text16 + fixed16, length: 0)
                if let a = AXValueCreate(.cfRange, &c) { AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, a) }
            }
            // each fixed word: where it now starts in the fixed text
            var words: [(word: String, old: String, loc: Int?, back: Int?)] = []
            for e in done {
                let shift = done.filter { $0.at < e.at }.reduce(0) { $0 + ($1.new as NSString).length - $1.len }
                let at = e.at + shift
                words.append((e.new, e.old, now.viaMarkers ? nil : p.caret - text16 + at, fixed16 - at))
            }
            // marks once the caret is back at the end (arrow keys land a moment later in Chromium)
            let want = (fixed as String).replacingOccurrences(of: "\u{A0}", with: " "), el = el, pid = p.pid, fm = fm
            func mark(_ tries: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let b = Focus.spot(skip: Drafter.shared.settings.skip).0?.before.replacingOccurrences(of: "\u{A0}", with: " ") ?? ""
                    if b.hasSuffix(want) || tries <= 0 { fm.addAt(words, el: el, pid: pid) } else { mark(tries - 1) }
                }
            }
            mark(15)
            log("proofread applied \(done.count) of \(list.count) (\(now.viaMarkers ? "markers" : p.web ? "web range" : "range"))" + (debugLog ? " " + done.map { "\($0.old)→\($0.new)" }.joined(separator: ", ") : ""))
        }
    }
}
