// The Quick panel's rules (14 November 2026), pure: no AppKit, no files. Which rows the panel lists and in what
// order (merge, pins, de-duplication), how typing narrows them (fold, substring first, then all words), what the
// clipboard history keeps (count, age, secrets), the three instant rewrites (plain text, one line, as a quote), the
// relative time in a row, and the global key written as "⌃⌥V". Tested by tests/quick_rules.swift.
import Foundation

enum QuickKind: String, CaseIterable {
    case copied, typed, voice
}

/// One row: a copied text, a message the user typed (TypedList), or a voice take.
struct QuickItem {
    let kind: QuickKind
    let text: String
    let app: String
    let at: Double                 // seconds since 1970
    var image = false              // a copied image: only its size is kept, never the pixels
    var pinned = false
    let first: String              // the first line with words, for the row
    let single: Bool               // one line with no spaces (a link, a path): the row cuts it in the middle
    let key: [UInt8]               // folded text and app, UTF-8, for search
    let head: [UInt8]              // the folded first line, for "starts with"
    let id: String                 // kind + text, hashed: what data/quick-stats.json counts
    let appID: String

    // round three: what the copy is (ClipRules), a link's title, a file's or picture's size, the stored picture
    // (a name in data/clips/) and its read text
    var clip = ClipKind.text
    var title = "", bytes = 0, picture = "", ocr = ""
    var rich = false
    // clip kinds round (17 November 2026): what else it is (ClipShape), the stored formatted or original copy in
    // data/clips/ ("data": rich text, a table, PDF data), and one note for the shape (a language, "#RRGGBB", "4 × 12")
    var shape: ClipShape? = nil
    var data = "", note = ""
    var look: [String]? = nil      // a kept picture's Vision labels (pictures round, 24 November 2026; PictureLookRules)

    init(kind: QuickKind, text: String, app: String, at: Double, image: Bool = false, clip: ClipKind? = nil,
         title: String = "", bytes: Int = 0, picture: String = "", ocr: String = "", rich: Bool = false,
         shape: ClipShape? = nil, data: String = "", note: String = "", look: [String]? = nil) {
        self.shape = shape; self.data = data; self.note = note; self.look = look
        self.kind = kind; self.text = text; self.app = app; self.at = at; self.image = image
        self.clip = clip ?? (image ? .image : .text)
        self.title = title; self.bytes = bytes; self.picture = picture; self.ocr = ocr; self.rich = rich
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        first = String((lines.first ?? "").prefix(400))
        single = lines.count <= 1 && !first.contains(where: \.isWhitespace)
        var extra = ClipRules.searchExtra(self.clip, text: text, title: title, ocr: ocr)
        if self.clip == .image, !picture.isEmpty, !text.hasPrefix("PDF") {
            extra += "\n" + PictureLookRules.searchWords(kind: PictureLookRules.kind(ocr: ocr, labels: look ?? []), labels: look ?? [])
        }
        key = Array(QuickRules.fold(String(text.prefix(QuickRules.keyChars)) + "\n" + app + (extra.isEmpty ? "" : "\n" + extra)).utf8)
        head = Array(QuickRules.fold(first).utf8)
        id = QuickRules.hash(kind.rawValue + "\u{1}" + text + (picture.isEmpty ? "" : "\u{1}" + picture))
        appID = QuickRules.hash("app\u{1}" + app)
    }
    func same(_ o: QuickItem) -> Bool { kind == o.kind && text == o.text && picture == o.picture }
}

/// A pinned row, kept in data/quick-pins.json with its own text, so it stays when the history around it is trimmed.
struct QuickPin: Equatable {
    let kind: QuickKind
    let text: String
    let app: String
    let at: Double
    var json: [String: Any] { ["kind": kind.rawValue, "text": text, "app": app, "t": at] }
    init(kind: QuickKind, text: String, app: String, at: Double) { self.kind = kind; self.text = text; self.app = app; self.at = at }
    init?(_ j: [String: Any]) {
        guard let k = (j["kind"] as? String).flatMap(QuickKind.init(rawValue:)), let t = j["text"] as? String, !t.isEmpty else { return nil }
        self.init(kind: k, text: t, app: j["app"] as? String ?? "", at: j["t"] as? Double ?? 0)
    }
}

/// When the user put items in, by item id and by app id (hashed): data/quick-stats.json holds numbers and ids only.
struct QuickUses: Equatable {
    var items: [String: [Double]] = [:]
    var apps: [String: [Double]] = [:]
    var json: [String: Any] { ["items": items, "apps": apps] }
    init() {}
    init(_ j: [String: Any]) {
        items = (j["items"] as? [String: [Double]]) ?? [:]
        apps = (j["apps"] as? [String: [Double]]) ?? [:]
    }
}

struct QuickHotkey: Equatable {
    let code: Int
    let ctrl: Bool, alt: Bool, cmd: Bool, shift: Bool
}

enum QuickRules {
    /// Search reads the first 4,000 characters of a row (a long copy is still found by its start).
    static let keyChars = 4000

    // MARK: search

    /// Case, accents and width away; ʼ ’ ` as '; runs of space as one. "Їжак" and "іжак" fold alike (Ukrainian ї, й, ґ
    /// lose their marks on both sides, so a query typed either way finds the row).
    static func fold(_ s: String) -> String {
        let t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = "", space = false
        out.reserveCapacity(t.utf8.count)
        for ch in t {
            if ch.isWhitespace { space = true; continue }
            if space, !out.isEmpty { out.append(" ") }
            space = false
            switch ch { case "ʼ", "’", "‘", "`", "´": out.append("'"); case "ґ": out.append("г"); default: out.append(ch) }   // ґ has no mark to drop
        }
        return out
    }

    private static func has(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > hay.count { return false }
        return hay.withUnsafeBufferPointer { h in needle.withUnsafeBufferPointer { n in
            memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
        } }
    }

    /// The rows to show, as indices into `items` (which is newest first, pinned on top). No query: all of the kind, as
    /// they are. A query: rows holding the whole query or every word of it, pinned first, then by `score`.
    static func filter(_ items: [QuickItem], query: String, kind: QuickKind?, uses: QuickUses = QuickUses(), now: Double = 0) -> [Int] {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if q.isEmpty { return items.indices.filter { kind == nil || items[$0].kind == kind } }
        let whole = Array(q.utf8)
        let words = q.split(separator: " ").map { Array($0.utf8) }
        var hits: [(i: Int, score: Double, pinned: Bool)] = []
        for i in items.indices {
            let it = items[i]
            if let kind, it.kind != kind { continue }
            var match = 0.0
            if has(it.key, whole) { match = it.head.starts(with: whole) ? 4 : 3 }
            else if words.count > 1, words.allSatisfy({ has(it.key, $0) }) { match = 1.5 }
            guard match > 0 else { continue }
            hits.append((i, score(match: match, at: it.at, now: now, item: uses.items[it.id] ?? [], app: uses.apps[it.appID] ?? []), it.pinned))
        }
        hits.sort { a, b in a.pinned != b.pinned ? a.pinned : a.score != b.score ? a.score > b.score : a.i < b.i }
        return hits.map(\.i)
    }

    /// A row's rank for a query: how it matches (3 the whole query, +1 at the start of its first line, 1.5 every word),
    /// how fresh it is (2 now, half after 17 h), how often and how lately the user put it in (1.5 a time, fading over a week,
    /// at most 6), and a little for the app it came from (0.2 a time, fading over a week, at most 1).
    /// So an item put in three times this week (≈ 3) beats a one-off copy of an hour ago (≈ 1.9) for the same words.
    static func score(match: Double, at: Double, now: Double, item: [Double], app: [Double]) -> Double {
        let week = 7.0 * 86400
        let fresh = 2 * exp(-max(0, now - at) / 86400)
        let used = min(6, 1.5 * item.reduce(0) { $0 + exp(-max(0, now - $1) / week) })
        let from = min(1, 0.2 * app.reduce(0) { $0 + exp(-max(0, now - $1) / week) })
        return match + fresh + used + from
    }

    /// The user put `item` in at `t`: kept are its last 20 times and its app's last 50; at most 2,000 items (the least
    /// recently used go).
    static func used(_ u: inout QuickUses, _ item: QuickItem, at t: Double) {
        u.items[item.id, default: []].append(t.rounded())
        if u.items[item.id]!.count > 20 { u.items[item.id]!.removeFirst(u.items[item.id]!.count - 20) }
        u.apps[item.appID, default: []].append(t.rounded())
        if u.apps[item.appID]!.count > 50 { u.apps[item.appID]!.removeFirst(u.apps[item.appID]!.count - 50) }
        if u.items.count > 2000 {
            let old = u.items.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(u.items.count - 2000).map(\.key)
            for k in old { u.items[k] = nil }
        }
    }

    /// FNV-1a, 64 bits, hex: the same id on every run (Swift's own hash changes per process).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: rows

    /// One list: pins first (newest pin first), then every row newest first. The same text of the same kind shows
    /// once, at its newest time (a repeated copy moves to the top).
    static func merge(_ rows: [QuickItem], pins: [QuickPin]) -> [QuickItem] {
        // keys as UTF-8 bytes: hashing a long non-ASCII String normalises it each time (speed round: 28 ms of 3,000 rows)
        var newest: [[UInt8]: Int] = [:]           // kind+text -> index of its newest row
        for (i, r) in rows.enumerated() {
            let k = Array((r.kind.rawValue + "\u{1}" + r.text).utf8)
            if let j = newest[k], rows[j].at >= r.at { continue }
            newest[k] = i
        }
        let pinKeys = Set(pins.map { Array(($0.kind.rawValue + "\u{1}" + $0.text).utf8) })
        var out: [QuickItem] = pins.map { p in
            var it = QuickItem(kind: p.kind, text: p.text, app: p.app, at: p.at)
            it.pinned = true
            return it
        }
        out += newest.filter { !pinKeys.contains($0.key) }.map { rows[$0.value] }.sorted { $0.at > $1.at }
        return out
    }

    /// Which clipboard rows stay (indices in file order): the newest of each text, none older than `days`, none
    /// that match a secret pattern, at most `max` (the newest).
    static func keepClips(_ rows: [(t: Double, text: String)], now: Double, max: Int, days: Double,
                          secret: (String) -> Bool = { _ in false }) -> [Int] {
        var seen = Set<String>(), keep: [Int] = []
        for i in rows.indices.reversed() {
            let r = rows[i]
            if keep.count >= max { break }
            if days > 0, now - r.t > days * 86400 { continue }
            if r.text.isEmpty || seen.contains(r.text) || secret(r.text) { continue }
            seen.insert(r.text); keep.append(i)
        }
        return keep.reversed()
    }

    // MARK: secrets

    /// Never kept: lines that look like API keys and tokens, card numbers, one-time codes, private keys. Each a
    /// regular expression, matched anywhere in the copy (setting `quickSecret`).
    static let defaultSecrets: [String] = [
        #"\b(sk|pk|rk)[-_](live|test|proj|ant)?[-_]?[A-Za-z0-9_-]{20,}"#,                           // sk-…, sk_live_…
        #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}"#,                 // GitHub
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}|\bAKIA[0-9A-Z]{16}\b|\bAIza[0-9A-Za-z_-]{35}"#,             // Slack, AWS, Google
        #"(?i)\b(api[_ -]?key|secret|token|password|passwd|пароль)\s*[:=]\s*\S{6,}"#,                 // key = value
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,                         // a JWT
        #"(?m)^\s*(?=[\w-]*\d)(?=[\w-]*[A-Za-z])(?![a-z0-9]+(?:-[a-z0-9]+){2,}\s*$)[A-Za-z0-9_-]{32,}\s*$"#,  // a line that is one long token (not a-slug-like-this)
        #"(?m)^\D{0,24}\b(\d{4}[ -]?){3}\d{1,7}\b\D{0,24}$"#,                                         // a card number
        #"^\s*(\d{6}|\d{3}[ -]\d{3}|\d{8})\s*$"#,                                                     // a one-time code alone
    ]

    static func secretRules(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    static func isSecret(_ s: String, _ rules: [NSRegularExpression]) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        for rx in rules where rx.firstMatch(in: s, range: r) != nil {
            // a card pattern counts only when the digits pass the Luhn check (an order number does not)
            if rx.pattern == defaultSecrets[7] {
                guard let m = rx.firstMatch(in: s, range: r), let rr = Range(m.range, in: s) else { continue }
                if luhn(String(s[rr])) { return true } else { continue }
            }
            return true
        }
        return false
    }

    static func luhn(_ s: String) -> Bool {
        let d = s.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(d.count) else { return false }
        var sum = 0
        for (i, v) in d.reversed().enumerated() { let x = i % 2 == 1 ? v * 2 : v; sum += x > 9 ? x - 9 : x }
        return sum % 10 == 0
    }

    // MARK: instant rewrites (no model)

    static let tracking: Set<String> = ["fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "mc_cid", "mc_eid",
                                        "igshid", "igsh", "_hsenc", "_hsmi", "mkt_tok", "ref_src", "ref_url", "si", "trk", "spm",
                                        "vero_id", "oly_enc_id", "oly_anon_id", "__s", "s_cid", "twclid", "ttclid", "li_fat_id"]

    /// A link without its tracking parameters (utm_*, fbclid, gclid, si…); other parameters and the fragment stay.
    static func cleanLink(_ link: String) -> String {
        guard var c = URLComponents(string: link), let items = c.queryItems, !items.isEmpty else { return link }
        let kept = items.filter { q in let n = q.name.lowercased(); return !n.hasPrefix("utm_") && !tracking.contains(n) }
        if kept.count == items.count { return link }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.string ?? link
    }

    /// Plain text: no markdown marks, no invisible characters, links without tracking, no trailing spaces.
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"[​-‍⁠﻿­]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[   ]"#, with: " ", options: .regularExpression)
        // [words](link) -> words (link); the same words as the link -> the link
        t = t.replacingOccurrences(of: #"\[([^\]\n]+)\]\((https?://[^)\s]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(https?://[^\s()]+) \(\1\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__)(\S(?:.*?\S)?)\1"#, with: "$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![\w*])\*(\S(?:[^*\n]*?\S)?)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`([^`\n]+)`"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
        let rx = try! NSRegularExpression(pattern: #"https?://[^\s<>()"']+"#)
        let ns = t as NSString
        var out = "", at = 0
        for m in rx.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += cleanLink(ns.substring(with: m.range))
            at = m.range.location + m.range.length
        }
        out += ns.substring(from: at)
        return out.components(separatedBy: "\n").map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line: the lines joined with a space, runs of space as one.
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ").replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    /// As a quote: "> " before each line (an empty line gets ">").
    static func quote(_ s: String) -> String {
        s.trimmingCharacters(in: .newlines).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    static func local(_ id: String, _ s: String) -> String? {
        switch id { case "plain": return plain(s); case "oneline": return oneLine(s); case "quote": return quote(s); default: return nil }
    }

    /// The shown form of a clip: 0 is the text as copied, 1...forms its written forms; ← and → wrap.
    static func stepForm(_ i: Int, by d: Int, forms n: Int) -> Int {
        guard n > 0 else { return 0 }
        return ((i + d) % (n + 1) + (n + 1)) % (n + 1)
    }

    // MARK: the picker (picker round, 15 November 2026): one window for ⌃⌥V (full) and ⌘⇧V held (quick)

    /// The quick form's rows (⌘⇧V held), as indices into `items`: the newest copies, never a picture or a pin (a
    /// tap-and-release puts the newest text copy in, as the switcher did).
    static func quickRows(_ items: [QuickItem], count: Int) -> [Int] {
        Array(items.indices.filter { items[$0].kind == .copied && !items[$0].image && !items[$0].pinned }.prefix(count))
    }
    /// A step through the quick form's rows: V and → go on, ← back, both wrap.
    static func wrap(_ i: Int, by d: Int, count n: Int) -> Int {
        guard n > 0 else { return 0 }
        return ((i + d) % n + n) % n
    }

    /// What the chosen row is, for its buttons.
    struct PickerRow: Equatable {
        var clip = ClipKind.text
        var target: ClipKind? = nil      // a text holding a link or a path
        var forms = 0                    // written forms besides the text as copied (FoundRules.quickForms)
        var image = false
        var picture = false              // a picture row with its stored file
        var pinned = false
        // clip kinds round (17 November 2026)
        var shape: ClipShape? = nil
        var formatted = false            // a text kept with its formatting: ← → steps to "Text", ↵ puts the form shown
    }
    /// One glyph button on the picker's foot: the key small under the glyph, the word its tip and VoiceOver name.
    struct PickerButton: Equatable {
        let id: String, glyph: String, key: String, word: String
        var primary = false
    }

    /// The chosen row's buttons, in groups (hairlines between). Every button is a key the picker already has; the pill
    /// only shows them. quick: the held chord (⌘ let go puts, V next, ← → forms, a letter searches, esc).
    static func buttons(_ r: PickerRow?, quick: Bool, rework: Bool = false, result: Bool = false) -> [[PickerButton]] {
        if quick {
            var step = [PickerButton(id: "next", glyph: "chevron-down", key: "V", word: "Next copy")]
            if (r?.forms ?? 0) > 0 { step.append(PickerButton(id: "form", glyph: "arrows-left-right", key: "← →", word: "Written form")) }
            return [[PickerButton(id: "put", glyph: "corner-down-left", key: "⌘", word: "Let go to paste", primary: r != nil)], step,
                    [PickerButton(id: "search", glyph: "search", key: "A–Z", word: "Search everything"),
                     PickerButton(id: "close", glyph: "close", key: "esc", word: "Close")]]
        }
        if rework {
            let back = PickerButton(id: "back", glyph: "arrow-back-up", key: "⌫", word: "Back to the text")
            let list = PickerButton(id: "list", glyph: "arrow-left", key: "esc", word: "Back to the list")
            if result {
                return [[PickerButton(id: "put", glyph: "corner-down-left", key: "↵", word: "Paste the new text", primary: true),
                         PickerButton(id: "copy", glyph: "copy", key: "⌘C", word: "Copy the new text")], [back, list]]
            }
            return [[PickerButton(id: "run", glyph: "sparkle", key: "↵", word: "Rewrite", primary: true)], [list]]
        }
        guard let r else { return [[PickerButton(id: "close", glyph: "close", key: "esc", word: "Close")]] }
        let keep = [PickerButton(id: "pin", glyph: "bookmark", key: "⌘P", word: r.pinned ? "Unpin" : "Pin"),
                    PickerButton(id: "remove", glyph: "trash", key: "⌘⌫", word: "Remove from history")]
        if r.image && !r.picture { return [keep] }   // only its size was kept: nothing to put
        var out: [[PickerButton]] = []
        switch r.clip {
        case .image:
            out.append([PickerButton(id: "put", glyph: "corner-down-left", key: "↵", word: r.shape == .pdf ? "Paste PDF" : "Paste", primary: true),
                        PickerButton(id: "withText", glyph: "text", key: "⇧↵", word: "Paste with its text"),
                        PickerButton(id: "copy", glyph: "copy", key: "⌘C", word: "Copy")])
        case .file:
            out.append([PickerButton(id: "put", glyph: "corner-down-left", key: "↵", word: r.shape == .files ? "Paste files" : "Paste file", primary: true)])
        default:
            if r.formatted {
                out.append([PickerButton(id: "put", glyph: "corner-down-left", key: "↵", word: "Paste the form shown", primary: true),
                            PickerButton(id: "copy", glyph: "copy", key: "⌘C", word: "Copy")])
            } else {
                out.append([PickerButton(id: "put", glyph: "corner-down-left", key: "↵", word: "Paste", primary: true),
                            PickerButton(id: "copy", glyph: "copy", key: "⌘C", word: "Copy")])
            }
            var change: [PickerButton] = []
            if r.forms > 0 { change.append(PickerButton(id: "form", glyph: "arrows-left-right", key: "← →", word: "Written form")) }
            change.append(PickerButton(id: "rewrite", glyph: "sparkle", key: "⇥", word: "Rewrite"))
            if r.clip == .text { change.append(PickerButton(id: "pick", glyph: "scissors", key: "⌘E", word: "Pick parts")) }
            out.append(change)
        }
        let own = r.clip == .text ? r.target.map { ClipRules.actions(.text, target: $0) } ?? [] : ClipRules.actions(r.clip)
        let kind = own.filter { $0.id != "paste" && $0.id != "withText" }.map { PickerButton(id: $0.id, glyph: actionGlyph($0.id), key: $0.key, word: $0.word.prefix(1).uppercased() + $0.word.dropFirst()) }
        if !kind.isEmpty { out.append(kind) }
        out.append(keep)
        return out
    }
    /// The line glyph of a row's own action (ClipRules.actions ids).
    static func actionGlyph(_ id: String) -> String {
        switch id {
        case "open": return "external"; case "markdown": return "markdown"; case "untracked": return "filter"
        case "reveal": return "folder"; case "path": return "clipboard"; case "copyFile": return "copy"; case "text": return "clipboard"; case "save": return "download"
        default: return "more"
        }
    }

    /// The second line of a row: the app it came from and how long ago ("Safari · 4m"), then what only that kind has
    /// (a link's host, a file's size and folder, a picture's size).
    static func meta(app: String, at: Double, now: Double, extra: [String] = []) -> String {
        ([app.isEmpty ? "" : app, ago(at, now: now)] + extra).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: row parts

    /// "now", "4m", "3h", "2d" up to 99 days, then "12.10".
    static func ago(_ t: Double, now: Double) -> String {
        let s = max(0, now - t)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 100 * 86400 { return "\(Int(s / 86400))d" }
        let c = Calendar(identifier: .gregorian).dateComponents([.day, .month], from: Date(timeIntervalSince1970: t))
        return String(format: "%d.%02d", c.day ?? 0, c.month ?? 0)
    }

    // MARK: the global key

    /// The full picker's own key: none since keys round two (17 November 2026; ⌘⇧V held, then Space or a letter,
    /// opens it). ⌃⌥V may still be set in Settings (`suggestedKey`).
    static let defaultKey = ""
    static let suggestedKey = "⌃⌥V"
    /// ⌃⌥Space and ⌘Space (Spotlight and other launchers): never taken.
    static let reserved = ["⌃⌥Space", "⌘Space"]
    static let codes: [String: Int] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14,
        "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "L": 37, "J": 38, "'": 39, "K": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "N": 45, "M": 46, ".": 47, "`": 50, "SPACE": 49, "RETURN": 36, "TAB": 48,
    ]

    /// "⌃⌥V", "ctrl+opt+v", "⌘⇧Space" -> the key and its modifiers. nil: empty (off), unknown, no ⌃/⌥/⌘, or reserved.
    static func hotkey(_ s: String) -> QuickHotkey? {
        var rest = s.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        var ctrl = false, alt = false, cmd = false, shift = false
        let words: [(String, (inout Bool, inout Bool, inout Bool, inout Bool) -> Void)] = [
            ("⌃", { c, _, _, _ in c = true }), ("ctrl+", { c, _, _, _ in c = true }), ("control+", { c, _, _, _ in c = true }),
            ("⌥", { _, a, _, _ in a = true }), ("opt+", { _, a, _, _ in a = true }), ("alt+", { _, a, _, _ in a = true }), ("option+", { _, a, _, _ in a = true }),
            ("⌘", { _, _, m, _ in m = true }), ("cmd+", { _, _, m, _ in m = true }), ("command+", { _, _, m, _ in m = true }),
            ("⇧", { _, _, _, h in h = true }), ("shift+", { _, _, _, h in h = true }),
        ]
        var moved = true
        while moved {
            moved = false
            for (w, set) in words where rest.lowercased().hasPrefix(w) {
                rest = String(rest.dropFirst(w.count)); set(&ctrl, &alt, &cmd, &shift); moved = true
            }
        }
        guard ctrl || alt || cmd, let code = codes[rest.uppercased()] else { return nil }
        let k = QuickHotkey(code: code, ctrl: ctrl, alt: alt, cmd: cmd, shift: shift)
        if reserved.contains(where: { hotkeyRaw($0) == k }) { return nil }
        return k
    }

    private static func hotkeyRaw(_ s: String) -> QuickHotkey? {
        var rest = s, c = false, a = false, m = false, h = false
        while let f = rest.first, "⌃⌥⌘⇧".contains(f) {
            switch f { case "⌃": c = true; case "⌥": a = true; case "⌘": m = true; default: h = true }
            rest.removeFirst()
        }
        return codes[rest.uppercased()].map { QuickHotkey(code: $0, ctrl: c, alt: a, cmd: m, shift: h) }
    }
}

// MARK: the two keys, as events (fix round, 14 November 2026)

/// One event from the tap, reduced to what the keys need: modifiers as the side-independent flags (left and right
/// set the same bit), caps lock and fn left out, and the key by its code (the V key is 9 on every layout).
struct QuickKeyEvent {
    enum Kind { case down, up, flags }
    var kind: Kind
    var code = -1
    var ctrl = false, alt = false, cmd = false, shift = false
    var autorepeat = false
    var at = 0.0                     // seconds since 1970 (the swap window after a switcher paste)
    static func down(_ code: Int, _ mods: String = "", repeat r: Bool = false) -> QuickKeyEvent {
        QuickKeyEvent(kind: .down, code: code, ctrl: mods.contains("⌃"), alt: mods.contains("⌥"), cmd: mods.contains("⌘"), shift: mods.contains("⇧"), autorepeat: r)
    }
    static func up(_ code: Int, _ mods: String = "") -> QuickKeyEvent { var e = down(code, mods); e.kind = .up; return e }
    static func flags(_ mods: String) -> QuickKeyEvent { var e = down(-1, mods); e.kind = .flags; return e }
}

enum QuickKeyAction: Equatable {
    case pass, swallow
    case togglePanel                 // the panel's key
    case openSwitch, step(Int), put, cancel
    case toPanel(Int)                // a letter or digit (key code) while the switcher is held: into the panel with it; Space: into it empty
    case voiceAgain                  // `againKey` if set (keys round): the last voice take in again
    case swap                        // ⌘⇧V again right after a switcher paste: the next older copy replaces it
    case openFull                    // ⌘⇧V (17 November 2026, the user: "always open the full version"): the full picker
    case next                        // ⌘⇧V again while the full picker is open: the next row down
    case form(Int)                   // wire round: ← → step through the chosen clip's written forms before the paste
}

/// Which key does what. Before 14 November the switcher was marked open only once the main queue ran `open()`: a
/// quick ⌘⇧V tap released ⌘ before that, the release was missed, the strip stayed open with nothing held, and the
/// next key the user typed - a letter, or ⌃⌥V itself, which the strip read as "V: next" whatever the modifiers - was taken by
/// it. So every panel open in the log came through the switcher, and ⌃⌥V never opened the panel while a strip hung.
/// Here the state changes on the event itself, the modifiers are compared exactly, and a key that comes while the
/// chord's modifiers are no longer down ends the switcher first (a missed release) and is then read afresh.
struct QuickKeys {
    var panelKey: QuickHotkey?
    var switchKey: QuickHotkey?
    private(set) var switching = false
    var panelOpen = false
    /// Keys round (14 November): the last voice take again (setting `againKey`, "" = off).
    var againKey: QuickHotkey? = nil
    /// The held quick form on ⌘⇧V (until 17 November 2026; setting `switchQuickForm`, off): release puts the chosen
    /// copy in. Off: ⌘⇧V opens the full picker at once, ↑ ↓ or ⌘⇧V again choose, ← → the written form, ↵ puts in.
    var quickForm = false
    /// Until when ⌘⇧V swaps the text a switcher paste just put in (0 = not armed). Armed by the app after a paste of
    /// text with an older text copy behind it; any other key, a click, the time or the swap itself ends it.
    private(set) var swapUntil = 0.0

    /// Wire round (15 November 2026): how many written forms the chosen clip has (FoundRules.quickForms; set by the
    /// app when the choice changes). With forms, ← and → step through them in the panel and in the switcher (the
    /// switcher's V still moves to the next copy); without, the keys do what they did.
    var forms = 0

    mutating func armSwap(until t: Double) { swapUntil = t }
    mutating func disarmSwap() { swapUntil = 0 }

    static let space = 49
    static let letterCodes: Set<Int> = Set(QuickRules.codes.filter { $0.key.count == 1 && ($0.key.first!.isLetter || $0.key.first!.isNumber) }.map(\.value))

    static func exact(_ e: QuickKeyEvent, _ k: QuickHotkey?) -> Bool {
        guard let k else { return false }
        return e.code == k.code && e.ctrl == k.ctrl && e.alt == k.alt && e.cmd == k.cmd && e.shift == k.shift
    }
    /// The chord is still held while any of its ⌘ ⌃ ⌥ is down (⇧ may go first, or last).
    private func held(_ e: QuickKeyEvent) -> Bool {
        guard let k = switchKey else { return false }
        return (k.cmd && e.cmd) || (k.ctrl && e.ctrl) || (k.alt && e.alt) || (!k.cmd && !k.ctrl && !k.alt && e.shift)
    }

    mutating func cancelSwitch() { switching = false }

    mutating func route(_ e: QuickKeyEvent) -> [QuickKeyAction] {
        if switching {
            switch e.kind {
            case .up: return [.pass]
            case .flags:
                if !held(e) { switching = false; return [.put] }
                return [.pass]
            case .down:
                if !held(e) { switching = false; return [.put] + route(e) }   // the release was missed: put, then read the key
                if e.autorepeat { return [.swallow] }
                if forms > 0, e.code == 124 || e.code == 123 { return [.form(e.code == 124 ? 1 : -1)] }
                if e.code == switchKey?.code || e.code == 124 { return [.step(1)] }
                if e.code == 123 { return [.step(-1)] }
                if e.code == 53 { switching = false; return [.cancel] }
                if Self.letterCodes.contains(e.code) { switching = false; return [.toPanel(e.code)] }
                if e.code == Self.space { switching = false; return [.toPanel(e.code)] }   // Space: the full picker, empty search
                return [.swallow]
            }
        }
        guard e.kind == .down else { return [.pass] }   // a modifier change keeps the swap armed
        if swapUntil > 0, !panelOpen, Self.exact(e, switchKey), !e.autorepeat, e.at <= swapUntil {
            swapUntil = 0                                   // one step; the app arms it again for the next one
            return [.swap]
        }
        swapUntil = 0
        if Self.exact(e, panelKey) { return [e.autorepeat ? .swallow : .togglePanel] }
        if Self.exact(e, againKey) { return [e.autorepeat ? .swallow : .voiceAgain] }
        if panelOpen, forms > 0, e.code == 124 || e.code == 123, !e.ctrl, !e.alt, !e.cmd, !e.shift { return [.form(e.code == 124 ? 1 : -1)] }
        if !quickForm, Self.exact(e, switchKey) {
            if e.autorepeat { return [.swallow] }
            return [panelOpen ? .next : .openFull]
        }
        if !panelOpen, Self.exact(e, switchKey) {
            if e.autorepeat { return [.swallow] }
            switching = true
            return [.openSwitch]
        }
        return [.pass]
    }
}
