// What a copy is (round three, 14 November 2026): text, link, file or image, read from the pasteboard's types; how
// each one shows, searches and what its keys do; which stored pictures go when the history is trimmed. Pure: no
// AppKit, tested in tests/quick_rules.swift with made-up rows. Storage and capture live in History.swift and Capture.swift.
import Foundation

enum ClipKind: String { case text, link, file, image }
/// What else a copy is, beside its kind (clip kinds round, 17 November 2026; rules in app/ClipKindRules.swift). Kept in
/// the row as "shape"; a row without it (every row before this round) looks and pastes as before.
/// files: several files at once · pdf: a PDF file or PDF data, with a first-page thumbnail · rich: formatted text kept
/// · table: a table (cells by tab, or an HTML table) · code: a language guess · color: a colour value with a swatch.
enum ClipShape: String { case files, pdf, rich, table, code, color }

enum ClipRules {
    static let fileTypes: Set<String> = ["public.file-url", "NSFilenamesPboardType"]
    static let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif", "org.webmproject.webp"]
    static let pdfTypes: Set<String> = ["com.adobe.pdf"]
    static let richTypes: Set<String> = ["public.rtf", "public.html", "com.apple.flat-rtfd", "public.rtfd"]

    /// The kind, from the pasteboard's types and its plain text. Files win (Finder also puts an icon picture and the
    /// name as text); then a picture without text; then one line that is an http(s) address; else text.
    static func kind(types: Set<String>, string: String?) -> ClipKind {
        if !types.isDisjoint(with: fileTypes) { return .file }
        let s = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s.isEmpty, !types.isDisjoint(with: imageTypes) || !types.isDisjoint(with: pdfTypes) { return .image }
        if link(s) != nil { return .link }
        return .text
    }
    static func rich(_ types: Set<String>) -> Bool { !types.isDisjoint(with: richTypes) }

    // MARK: links

    /// One line, no spaces, http or https with a host.
    static func link(_ s: String) -> URL? {
        guard s.count < 4000, !s.contains(where: { $0.isWhitespace || $0.isNewline }),
              let u = URL(string: s), let sc = u.scheme?.lowercased(), sc == "http" || sc == "https",
              let h = u.host, h.contains(".") || h == "localhost" else { return nil }
        return u
    }
    /// Host without "www.", and the last part of the path (without a file extension's noise kept as is).
    static func parts(_ s: String) -> (host: String, last: String, path: String) {
        guard let u = URL(string: s), let h = u.host else { return (s, "", "") }
        let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        let comps = u.path.split(separator: "/").map(String.init)
        let last = (comps.last ?? "").removingPercentEncoding ?? comps.last ?? ""
        return (host, last, comps.joined(separator: " "))
    }
    /// Display only: drop generated trailing IDs. Short version numbers and model names stay intact.
    static func cleanSlug(_ slug: String, prose: Bool = false) -> String {
        let raw = (slug.removingPercentEncoding ?? slug).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.contains("/") else { return raw }
        let id = #"(?:[0-9a-f]{32}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9]{6,})"#
        if raw.range(of: "^" + id + "$", options: [.regularExpression, .caseInsensitive]) != nil { return "" }
        let clean = raw.replacingOccurrences(of: "[-_]" + id + "$", with: "", options: [.regularExpression, .caseInsensitive])
        guard prose || clean != raw || !clean.contains(where: \.isNumber) else { return clean }
        return clean.replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Fetched titles win. Repository/model paths keep their technical spelling; Notion IDs never become titles.
    static func linkTitle(_ url: String, title: String = "") -> String {
        let fetched = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fetched.isEmpty { return fetched }
        let p = parts(url), host = p.host.lowercased()
        if ["github.com", "gitlab.com", "bitbucket.org", "huggingface.co"].contains(host), let u = URL(string: url) {
            let path = u.path.split(separator: "/")
            if path.count == 2 { return path.joined(separator: "/") }
            return p.last.isEmpty ? p.host : p.last
        }
        let notion = host == "notion.so" || host.hasSuffix(".notion.so") || host == "notion.site" || host.hasSuffix(".notion.site")
        let clean = cleanSlug(p.last, prose: notion)
        return clean.isEmpty ? p.host : clean
    }
    /// Query keys that only track who clicked; everything else stays.
    static let trackers: Set<String> = ["fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "mc_cid", "mc_eid",
                                        "igshid", "igsh", "_hsenc", "_hsmi", "mkt_tok", "vero_id", "oly_enc_id", "oly_anon_id",
                                        "ref_src", "ref_url", "s_cid", "si", "spm", "trk", "trkCampaign", "sc_cid"]
    static func untracked(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return s }
        if let q = c.queryItems {
            let keep = q.filter { i in !(i.name.lowercased().hasPrefix("utm_") || trackers.contains(i.name)) }
            c.queryItems = keep.isEmpty ? nil : keep
        }
        return c.string ?? s
    }
    /// [title](address); without a title: host and last path part.
    static func markdown(_ s: String, title: String) -> String {
        let p = parts(s)
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = p.last.isEmpty ? p.host : "\(p.host) · \(p.last)" }
        t = t.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(t)](\(s))"
    }

    // MARK: files

    /// The file's name and its folder, the home folder shown as ~.
    static func fileParts(_ path: String, home: String = NSHomeDirectory()) -> (name: String, folder: String) {
        let u = URL(fileURLWithPath: path)
        var f = u.deletingLastPathComponent().path
        if f == home { f = "~" } else if f.hasPrefix(home + "/") { f = "~" + f.dropFirst(home.count) }
        return (u.lastPathComponent, f)
    }
    static func bytes(_ n: Int) -> String {
        if n < 1000 { return "\(n) B" }
        if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded())) KB" }
        if n < 1_000_000_000 { return String(format: "%.1f MB", Double(n) / 1_000_000) }
        return String(format: "%.1f GB", Double(n) / 1_000_000_000)
    }

    /// In a text: the first http(s) link, else the first absolute or ~ path; nil when there is neither.
    static func firstTarget(in text: String) -> (kind: ClipKind, value: String)? {
        let words = text.prefix(4000).split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]\"'«»,;"))
        }
        if let l = words.first(where: { link($0) != nil }) { return (.link, l) }
        if let p = words.first(where: { ($0.hasPrefix("/") || $0.hasPrefix("~/")) && $0.count > 2 && $0.dropFirst().contains(where: { $0 != "/" }) }) {
            return (.file, p)
        }
        return nil
    }

    /// What search looks at beyond the text: host, path and title; name and folder; the read text of a picture.
    static func searchExtra(_ kind: ClipKind, text: String, title: String, ocr: String) -> String {
        switch kind {
        case .link: let p = parts(text); return [p.host, p.path, title].joined(separator: " ")
        case .file:
            return text.split(separator: "\n").prefix(50).map { let p = fileParts(String($0)); return p.name + " " + p.folder }.joined(separator: " ")
        case .image: return String(ocr.prefix(2000))
        case .text: return ""
        }
    }

    /// The unfolded row's keys (at most 4): key label, word, action id.
    struct Action: Equatable { let key: String; let word: String; let id: String }
    static func actions(_ kind: ClipKind, target: ClipKind? = nil) -> [Action] {
        switch kind {
        case .link: return [.init(key: "↵", word: "paste", id: "paste"), .init(key: "⌘O", word: "open", id: "open"),
                            .init(key: "⌘M", word: "markdown", id: "markdown"), .init(key: "⌘T", word: "clean", id: "untracked")]
        case .file: return [.init(key: "↵", word: "paste file", id: "paste"), .init(key: "⌘R", word: "reveal", id: "reveal"),
                            .init(key: "⌘C", word: "copy file", id: "copyFile"), .init(key: "⌥⌘C", word: "copy path", id: "path")]
        case .image: return [.init(key: "↵", word: "paste", id: "paste"), .init(key: "⇧↵", word: "with its text", id: "withText"),
                             .init(key: "⌘T", word: "copy text", id: "text"),
                             .init(key: "⌘S", word: "save to Desktop", id: "save")]
        case .text:
            guard let t = target else { return [] }
            return actions(t).filter { !["paste", "text", "path", "copyFile", "withText"].contains($0.id) }   // ⌘C stays "copy" on a text
        }
    }

    /// The row key a chord means (keys round three, row 10): the action whose key has exactly these modifiers and this
    /// key (key codes are the US positions, the same in every layout). ⌥⌘C is not ⌘C.
    static let keyCodes: [Character: Int] = ["O": 31, "M": 46, "T": 17, "R": 15, "S": 1, "C": 8]
    static func rowAction(_ list: [Action], code: Int, cmd: Bool, alt: Bool, ctrl: Bool, shift: Bool) -> Action? {
        list.first { a in
            var k = Substring(a.key), c = false, o = false, m = false, h = false
            while let f = k.first, "⌃⌥⇧⌘".contains(f) {
                switch f { case "⌃": c = true; case "⌥": o = true; case "⌘": m = true; default: h = true }
                k = k.dropFirst()
            }
            guard k.count == 1, let want = keyCodes[k.first!] else { return false }
            return want == code && c == ctrl && o == alt && m == cmd && h == shift
        }
    }

    // MARK: stored pictures

    struct Stored: Equatable { let name: String; let bytes: Int; let t: Double }
    /// Pictures to delete: those no history row points at, then the oldest while the rest is over `total` bytes.
    static func prune(_ files: [Stored], live: Set<String>, total: Int) -> [String] {
        var gone = files.filter { !live.contains($0.name) }.map(\.name)
        var kept = files.filter { live.contains($0.name) }.sorted { $0.t > $1.t }
        var sum = kept.reduce(0) { $0 + $1.bytes }
        while sum > total, let last = kept.popLast() { sum -= last.bytes; gone.append(last.name) }
        return gone
    }
    /// A stored picture's file name from its bytes: the same picture copied twice is one file and one row.
    static func clipName(_ data: Data, ext: String = "png") -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data.prefix(256 * 1024) { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        h = (h ^ UInt64(data.count)) &* 0x100000001b3
        return "c-" + String(h, radix: 16) + "." + ext
    }
    /// The row's text for a picture, and the text history de-duplicates it by (two pictures of one size stay two rows).
    static func imageText(_ w: Int, _ h: Int) -> String { "Image · \(w) × \(h)" }
    /// A row's one note for its shape (clip kinds round): the code's language, the colour's hex, a table's "4 × 12",
    /// a PDF's "3 pages"; "" when none.
    static func note(_ r: [String: Any]) -> String {
        if let l = r["lang"] as? String, !l.isEmpty { return l }
        if let c = r["color"] as? String, !c.isEmpty { return c }
        if let t = r["table"] as? [Int], t.count == 2 { return "\(t[0]) × \(t[1])" }
        if let p = r["page"] as? [Int], p.count == 3, p[2] > 1 { return "\(p[2]) pages" }
        return ""
    }
    static func shape(_ r: [String: Any]) -> ClipShape? { (r["shape"] as? String).flatMap(ClipShape.init(rawValue:)) }
    static func dedupeKey(text: String, clip: String?) -> String { clip.map { text + "\u{1}" + $0 } ?? text }
}
