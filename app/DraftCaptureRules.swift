// What a typed draft is (2026-11-14, capture round; docs/rounds/2026-11-14-capture.md). Keys kept the field's whole
// text before the caret (`lastBefore`) on every click and app switch: a rich web box read through text markers gave
// the page's text with it, the 2000-character tail cut it mid-word, and a draft he went on typing was kept again as a
// new row each time. The rules here, pure (no AppKit), tests/draft_capture_rules.swift:
//  - a draft is what he wrote between his first and last key: the field's text minus what it held at his first key
//    (`start`); never the field's whole content;
//  - a draft is never dropped (round two, lead review): when his keys, pastes, dictation and Drafter's writes
//    (`inserted`, Focus.wrote) cannot explain its length, the text after an anchor (the last 40 characters the field
//    held before the caret at his first key) is the draft; with the anchor gone, the tail his keys explain, from a word
//    or sentence start, kept with "est": true (an estimate the journal can mark);
//  - he came back to a draft he left in the same app within `window`: it grows that row (replace) or, the same text,
//    adds nothing;
//  - a row never starts inside a word: a cut moves back to the word's start, the tail window forward past the fragment.
// `DraftHide`: rows listed in data/drafts-hidden.json (scripts/hide_bad_drafts.py) are skipped when History lists.
import Foundation

enum DraftCaptureRules {
    /// A draft he comes back to within this time is the same message (the data: 70 of 98 bad rows within 5 minutes).
    static let window: TimeInterval = 10 * 60
    static let maxDraft = 2000, maxSent = 600

    /// A row kept before (this run): its text, when, and the app's name.
    /// `t0`: his first key in it, when known.
    struct Kept: Equatable {
        let text: String; let t: Double; let app: String; var t0: Double? = nil
    }

    /// `est`: the length was not explained and the text is the key-budget tail (an estimate).
    enum Record: Equatable { case skip, add(String, est: Bool), replace(String, Double, est: Bool) }
    static let anchorLength = 40, sentenceReach = 60

    static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" || c == "_" }

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{A0}", with: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Keys, pastes and dictation explain at most this many characters (Drafter's own small fixes and the read lag aside).
    static func budget(keys: Int, inserted: Int) -> Int { keys + inserted + max(12, keys / 5) }

    /// Index `i` in `s` moved back to the start of the word it is in (unchanged between words).
    static func wordStart(_ s: [Character], _ i: Int) -> Int {
        var k = min(max(i, 0), s.count)
        while k > 0, k < s.count, isWord(s[k - 1]), isWord(s[k]) { k -= 1 }
        return k
    }

    /// The last `max` characters, the cut moved forward past a broken word (the fragment is dropped).
    static func tail(_ s: String, max: Int) -> String {
        let c = Array(s)
        guard c.count > max else { return s }
        var k = c.count - max
        while k < c.count, isWord(c[k - 1]), isWord(c[k]) { k += 1 }
        return String(c[k...])
    }

    /// What he wrote: `end` (the field's text before the caret now) minus the start it shares with `start` (the same at
    /// his first key; nil: not read, the whole of `end`). A draft of the same app he left here (`recent`) whose text
    /// the shared start ends with is carried into this one. -> the text and how many of its characters were carried.
    static func typedPart(start: String?, end: String, recent: [Kept] = [], app: String = "", now: Double = 0) -> (text: String, carried: Int) {
        let e = Array(end)
        guard let start else { return (end, 0) }
        let s = Array(start)
        var k = 0
        while k < s.count, k < e.count, s[k] == e[k] { k += 1 }
        var carried = 0
        let base = String(e[..<k])
        let trimmed = Array(base.reversed().drop(while: { $0.isWhitespace }).reversed())
        for r in recent.reversed() where r.app == app && now - r.t <= window {
            let p = Array(r.text)
            if !p.isEmpty, trimmed.count >= p.count, Array(trimmed[(trimmed.count - p.count)...]) == p {
                k = trimmed.count - p.count; carried = p.count; break
            }
        }
        k = wordStart(e, k)
        return (String(e[k...]), carried)
    }

    /// What follows the last `anchorLength` characters of `start` (the field before the caret at his first key) inside
    /// `end`, searched from the end; nil when they are gone or too short to find safely.
    static func anchored(start: String, end: String) -> String? {
        let s = Array(start)
        guard s.count >= 12 else { return nil }
        let key = String(s.suffix(anchorLength))
        guard let r = end.range(of: key, options: .backwards) else { return nil }
        let e = Array(end), k = end.distance(from: end.startIndex, to: r.upperBound)
        return String(e[wordStart(e, k)...])
    }

    /// The last `budget` characters of `text`, moved back to the start of the word, and further to a sentence or line
    /// start when one is within `sentenceReach` characters.
    static func estimate(_ text: String, budget: Int) -> String {
        let c = Array(text)
        guard c.count > budget else { return text }
        var k = wordStart(c, c.count - max(budget, 0))
        let floor = max(0, k - sentenceReach)
        var j = k
        while j >= floor {
            if j == 0 || c[j - 1].isNewline || (j >= 2 && ".!?…".contains(c[j - 2]) && c[j - 1] == " ") { k = j; break }
            j -= 1
        }
        return String(c[k...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// His text in the field, never nothing: the shared-start part when his keys explain it, else the anchored part
    /// when they explain that, else the key-budget tail (est).
    static func resolve(start: String?, end: String, keys: Int, inserted: Int, recent: [Kept], app: String, now: Double) -> (text: String, est: Bool) {
        let part = typedPart(start: start, end: end, recent: recent, app: app, now: now)
        let ws = CharacterSet.whitespacesAndNewlines
        let text = part.text.trimmingCharacters(in: ws), b = budget(keys: keys, inserted: inserted + part.carried)
        if text.count <= b { return (text, false) }
        var base = text
        if let start, let a = anchored(start: start, end: end)?.trimmingCharacters(in: ws) {
            if a.count <= budget(keys: keys, inserted: inserted) { return (a, false) }
            base = a
        }
        return (estimate(base, budget: b), true)
    }

    /// The draft row to keep when he leaves the field (Keys.keepDraft). `keys`: letters he typed there since his first
    /// key; `inserted`: characters pasted, dictated or put in by Drafter meanwhile; `recent`: rows kept this run, oldest
    /// first.
    static func record(start: String?, end: String, keys: Int, inserted: Int, recent: [Kept], app: String, now: Double) -> Record {
        let got = resolve(start: start, end: end, keys: keys, inserted: inserted, recent: recent, app: app, now: now)
        let text = tail(got.text, max: maxDraft)
        guard text.split(whereSeparator: { $0.isWhitespace }).count >= 3 else { return .skip }
        let n = norm(text)
        for r in recent.reversed() where r.app == app && now - r.t <= window {
            let m = norm(r.text)
            if m == n { return .skip }
            if n.hasPrefix(m) { return .replace(text, r.t, est: got.est) }
        }
        return .add(text, est: got.est)
    }

    /// The times a new draft row carries (window round two reads "t0" as the start and "t" as the end): `t` his last
    /// key (else now), `t0` his first key. A draft that replaces `continued` keeps that row's first start and moves the
    /// end. A start is never after the end; unknown stays nil (old rows show no duration).
    static func stamps(firstKey: Double?, lastKey: Double?, now: Double, continued: Kept? = nil) -> (t0: Double?, t: Double) {
        let t = min(lastKey ?? now, now)
        let first = [continued?.t0, firstKey].compactMap { $0 }.min()
        return (first.map { min($0, t) }, t)
    }

    /// The line he sends with Return (Keys, /typed): the last line of what he wrote, at most `maxSent` characters, never
    /// starting inside a word (`resolve`: never page text his keys cannot explain, never nothing).
    static func sentLine(start: String?, end: String, keys: Int, inserted: Int, recent: [Kept], app: String, now: Double) -> String {
        let got = resolve(start: start, end: end, keys: keys, inserted: inserted, recent: recent, app: app, now: now)
        return tail(got.text.components(separatedBy: "\n").last ?? "", max: maxSent)
    }

    /// For the journal: an old row cut by the tail window (shape B: a draft of 1990+ characters or a sent line of
    /// exactly 600 that starts inside a word) shown from its first whole word after "…"; any other row as it is.
    static func shownText(_ text: String, sent: Bool) -> String {
        let capped = sent ? text.count == maxSent : text.count >= maxDraft - 10
        guard capped, let f = text.first, isWord(f), let sp = text.firstIndex(where: { $0.isWhitespace }) else { return text }
        let rest = text[sp...].drop(while: { $0.isWhitespace })
        return rest.isEmpty ? text : "…" + rest
    }
}

/// Rows hidden from the typed list without touching typed.jsonl or drafts.jsonl: data/drafts-hidden.json
/// {"hidden": [{"kind": "draft"|"sent", "t": <the row's t>, ...}]}, written only by scripts/hide_bad_drafts.py.
enum DraftHide {
    struct Key: Hashable { let kind: String; let t: Double }

    static func load(_ url: URL) -> Set<Key> {
        guard let d = try? Data(contentsOf: url), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let list = j["hidden"] as? [[String: Any]] else { return [] }
        return Set(list.compactMap { e in
            guard let k = e["kind"] as? String, let t = (e["t"] as? NSNumber)?.doubleValue else { return nil }
            return Key(kind: k, t: t)
        })
    }

    /// The rows as read, without the hidden ones of this kind.
    static func drop(_ rows: [[String: Any]], kind: String, hidden: Set<Key>) -> [[String: Any]] {
        guard !hidden.isEmpty else { return rows }
        return rows.filter { r in
            guard let t = (r["t"] as? NSNumber)?.doubleValue else { return true }
            return !hidden.contains(Key(kind: kind, t: t))
        }
    }
}
