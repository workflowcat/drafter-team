// More kinds of copies (clip kinds round, 17 November 2026; the user: "copying more types of files"). Pure: no AppKit,
// no files. Which picture type a copy came in and its file extension (kept as given, never all PNG), several files as
// one row, what else a text is (ClipShape: a colour, a table, code, formatted text), a table's size from its cells or
// its HTML, a language guess by simple signals, a colour value read from hex/rgb/hsl, a link's title from the anchor
// the copy carried. Capture: app/History.swift; drawing: app/ClipDraw.swift and app/QuickView.swift. Tested by
// tests/clip_kind_rules.swift with made-up values only.
import Foundation

enum ClipKindRules {
    // MARK: pictures in their own type

    static let imageExts: [String: String] = ["public.png": "png", "public.jpeg": "jpg", "public.tiff": "tiff", "public.heic": "heic",
                                              "com.compuserve.gif": "gif", "org.webmproject.webp": "webp"]
    /// The picture type a copy came in: the first picture type in the pasteboard's own order (the app lists its
    /// original first; TIFF is only what AppKit adds for a PNG, so a PNG or JPEG next to it wins).
    static func imageType(_ ordered: [String]) -> String? {
        let pics = ordered.filter { imageExts[$0] != nil }
        if pics.first == "public.tiff", let other = pics.first(where: { $0 != "public.tiff" }) { return other }
        return pics.first
    }
    static func ext(forType t: String) -> String { imageExts[t] ?? "png" }
    /// A stored file's pasteboard type from its extension ("c-1f.jpg" -> public.jpeg); nil: not a picture.
    static func type(forName name: String) -> String? {
        let e = (name as NSString).pathExtension.lowercased()
        if e == "jpeg" { return "public.jpeg" }
        return imageExts.first { $0.value == e }?.key
    }

    // MARK: files

    static func isPDF(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "pdf" }
    /// The shape of a file copy: several files, one PDF, else nil (one file as before).
    static func fileShape(_ paths: [String]) -> ClipShape? {
        if paths.count > 1 { return .files }
        return paths.first.map(isPDF) == true ? .pdf : nil
    }
    /// "3 files · 12 MB" (the size of the files that are not folders; no size when none was read).
    static func filesLine(count: Int, bytes: Int) -> String {
        let n = count == 1 ? "1 file" : "\(count) files"
        return bytes > 0 ? n + " · " + ClipRules.bytes(bytes) : n
    }
    /// The names, in order, cut to `max` with "+ N more".
    static func names(_ paths: [String], max: Int = 4) -> String {
        let n = paths.map { ($0 as NSString).lastPathComponent }
        let shown = n.prefix(max).joined(separator: ", ")
        return n.count > max ? shown + " + \(n.count - max) more" : shown
    }

    // MARK: what a text is

    static let colorType = "com.apple.cocoa.pasteboard.color"
    /// The shape of a text copy, from its types, its plain text and its HTML (nil: plain text as before). A colour
    /// value first, then a table (2 × 2 or more), then code, then formatted text.
    static func textShape(types: Set<String>, text: String, html: String?) -> ClipShape? {
        if color(text) != nil { return .color }
        if table(text: text, html: html) != nil { return .table }
        if language(text) != nil { return .code }
        return ClipRules.rich(types) ? .rich : nil
    }

    // MARK: tables

    /// Columns and rows: an HTML table's (<tr> rows, the most <td>/<th> in one), else tab-separated lines. nil under 2 × 2.
    static func table(text: String, html: String?) -> (cols: Int, rows: Int)? {
        if let h = html, let t = htmlTable(h) { return t }
        return tsvTable(text)
    }
    static func htmlTable(_ html: String) -> (cols: Int, rows: Int)? {
        let s = html.prefix(400_000).lowercased()
        guard s.contains("<table") else { return nil }
        let rows = s.components(separatedBy: "<tr").dropFirst()
        var cols = 0, n = 0
        for r in rows {
            let body = r.components(separatedBy: "</tr").first ?? ""
            let c = body.components(separatedBy: "<td").count - 1 + body.components(separatedBy: "<th").count - 1
            if c > 0 { n += 1; cols = max(cols, c) }
        }
        return cols >= 2 && n >= 2 ? (cols, n) : nil
    }
    /// Lines whose cells are split by tabs: at least 2 lines, most of them with the same number of cells (2 or more),
    /// and the first cell filled (an indented code line starts with a tab and is not a table).
    static func tsvTable(_ text: String) -> (cols: Int, rows: Int)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard lines.count >= 2, lines.count <= 100_000 else { return nil }
        let counts = lines.map { $0.components(separatedBy: "\t").count }
        guard let common = Dictionary(grouping: counts, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key, common >= 2 else { return nil }
        let same = counts.filter { $0 == common }.count
        let filledFirst = lines.filter { !($0.components(separatedBy: "\t").first ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard Double(same) >= 0.8 * Double(lines.count), Double(filledFirst) >= 0.8 * Double(lines.count) else { return nil }
        return (counts.max() ?? common, lines.count)
    }
    /// The top-left cells for a small grid (at most `rows` × `cols`, each cut to `chars`).
    static func cells(_ text: String, rows: Int = 4, cols: Int = 4, chars: Int = 14) -> [[String]] {
        text.split(separator: "\n", omittingEmptySubsequences: true).prefix(rows).map { l in
            l.components(separatedBy: "\t").prefix(cols).map { c in
                let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.count > chars ? String(t.prefix(chars - 1)) + "…" : t
            }
        }
    }
    static func tableLine(cols: Int, rows: Int) -> String { "Table · \(cols) × \(rows)" }

    // MARK: code

    /// A language by simple signals (nil: not code). JSON when it parses; HTML by its tags; else the language with
    /// the most of its own signals, at least 2, and more than any other.
    static func language(_ s0: String) -> String? {
        let s = String(s0.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 4 else { return nil }
        if (s.hasPrefix("{") && s.hasSuffix("}")) || (s.hasPrefix("[") && s.hasSuffix("]") && s.contains("\n")),
           (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])) != nil { return "JSON" }
        if s.hasPrefix("<"), s.contains("</") || s.contains("/>"),
           has(s, #"<(html|head|body|div|span|p|a|ul|ol|li|table|tr|td|section|article|nav|header|footer|script|style|img|br|h[1-6]|button|input|form)[\s>/]"#) {
            return "HTML"
        }
        var score: [(String, Int)] = []
        func count(_ name: String, _ signals: [String]) { score.append((name, signals.filter { has(s, $0) }.count)) }
        count("Swift", [#"\bfunc \w+\([^)]*\)\s*(->|\{|throws|async)"#, #"\b(guard let|if let|guard .* else)\b"#, #"\bimport (Foundation|SwiftUI|AppKit|UIKit|Combine)\b"#,
                        #"\b(struct|enum|extension|protocol) \w+[^{\n]*\{"#, #"\bvar \w+: [A-Z]\w*"#, #"\blet \w+ = "#, #"\bself\."#, #"@(State|Published|MainActor|objc|main)\b"#])
        count("Python", [#"(?m)^\s*def \w+\(.*\):\s*$"#, #"(?m)^\s*(import \w+|from [\w.]+ import )"#, #"(?m)^\s*(if|for|while|elif|else|try|except|with|class)\b.*:\s*$"#,
                         #"\bself[,)]"#, #"\bprint\("#, #"\b(None|True|False)\b"#, #"\belif\b"#, #"(?m)^\s*@\w+"#])
        count("JavaScript", [#"\b(const|let) \w+ = "#, #"\bfunction\s*\w*\("#, #"=>"#, #"\bconsole\.log\("#, #"\brequire\(['"]"#,
                             #"(?m)^\s*import .* from ['"]"#, #"(?m)^\s*export (default|const|function|class)\b"#, #"===|!=="#, #"\bdocument\.|\bwindow\."#])
        count("TypeScript", [#"\binterface \w+ \{"#, #"(?m)^\s*(export )?type \w+ = "#, #":\s*(string|number|boolean|any|void)\b"#, #"\bas const\b"#,
                             #"(?m)^\s*import .* from ['"]"#, #"\b(const|let) \w+: \w+"#, #"=>"#])
        count("Go", [#"(?m)^package \w+"#, #"(?m)^func (\(\w+ \*?\w+\) )?\w+\("#, #":="#, #"\bfmt\.\w+\("#, #"(?m)^import \("#, #"\berr != nil\b"#, #"\bchan\b|\bgo func\b"#])
        count("Rust", [#"\bfn \w+(<[^>]*>)?\("#, #"\blet mut\b"#, #"\bimpl\b"#, #"\bpub (fn|struct|enum|mod)\b"#, #"\w+!\("#, #"\buse (std|crate)::"#, #"&(str|mut)\b"#, #"\bmatch \w+ \{"#])
        count("SQL", [#"(?i)^\s*(select|insert|update|delete|create|alter|drop|with)\b"#, #"(?i)\b(from|into|set|table|where|values|join|group by|order by)\b"#,
                      #"(?i)\bselect\b[\s\S]*\bfrom\b"#])
        count("Shell", [#"^#!/(usr/)?bin/(env )?(ba|z)?sh"#, #"(?m)^\s*\$ \w"#,
                        #"(?m)^\s*(git|cd|ls|npm|npx|pnpm|yarn|brew|curl|wget|sudo|export|echo|grep|chmod|mkdir|rm|cp|mv|ssh|pip3?|python3|swiftc?|zsh|bash|launchctl|docker|kubectl|cargo|defaults|open|find|sed|awk|tar|xcodebuild) [-\w./~$"']"#,
                        #" --?[a-z][\w-]*"#, #"\$\{?\w+\}?"#, #" (&&|\|\|) | \| "#])
        count("CSS", [#"(?m)^\s*[.#]?[\w-]+(\s*[,>+~ ]\s*[.#]?[\w-:]+)*\s*\{"#, #"(?m)^\s*[\w-]+\s*:\s*[^;{}]+;\s*$"#, #"\b\d+(px|rem|em|vh|vw|%)\b"#, #"@media\b|:root\b|var\(--"#])
        // a sentence is not code: prose with code words (", if let us know", "select from the list") stays text
        let words = s.split(whereSeparator: { $0.isWhitespace }).count
        let marks = s.filter { "{}[]();=<>$#_|&*`\\:".contains($0) }.count
        if words >= 6, Double(marks) / Double(max(1, s.count)) < 0.02, !s.contains("\n") { return nil }
        // SQL needs its start; Shell may be one command line
        score = score.map { n, c in n == "SQL" && !has(s, #"(?i)^\s*(select|insert|update|delete|create|alter|drop|with)\b"#) ? (n, 0) : (n, c) }
        // TypeScript is JavaScript with types: only its own signals make it TypeScript
        if let ts = score.first(where: { $0.0 == "TypeScript" }), let js = score.first(where: { $0.0 == "JavaScript" }), ts.1 >= 1,
           has(s, #"\binterface \w+ \{|(?m)^\s*(export )?type \w+ = |:\s*(string|number|boolean|any|void)\b|\b(const|let) \w+: \w+"#) {
            score = score.map { $0.0 == "TypeScript" ? ($0.0, max($0.1, js.1 + 1)) : $0 }
        }
        let sorted = score.sorted { $0.1 > $1.1 }
        guard let best = sorted.first, best.1 >= 2, sorted.count < 2 || sorted[1].1 < best.1 else { return nil }
        return best.0
    }
    private static func has(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    // MARK: colours

    struct RGBA: Equatable { var r, g, b, a: Double }
    /// One colour value: #rgb, #rgba, #rrggbb, #rrggbbaa (always with #), rgb()/rgba() (0-255 or %), hsl()/hsla().
    /// nil for anything else.
    static func color(_ s0: String) -> RGBA? {
        let s = s0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ";", with: "")
        guard s.count <= 40, !s.contains("\n") else { return nil }
        if s.hasPrefix("#") {
            let h = Array(s.dropFirst())
            guard [3, 4, 6, 8].contains(h.count), h.allSatisfy(\.isHexDigit) else { return nil }
            let full = h.count <= 4 ? h.flatMap { [$0, $0] } : h
            func byte(_ i: Int) -> Double { Double(Int(String(full[i * 2...i * 2 + 1]), radix: 16) ?? 0) / 255 }
            return RGBA(r: byte(0), g: byte(1), b: byte(2), a: full.count == 8 ? byte(3) : 1)
        }
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let fn = s[..<open].trimmingCharacters(in: .whitespaces)
        let args = s[s.index(after: open)..<s.index(before: s.endIndex)]
            .replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init)
        guard args.count == 3 || args.count == 4 else { return nil }
        func num(_ a: String, scale: Double) -> Double? {
            if a.hasSuffix("%") { return Double(a.dropLast()).map { $0 / 100 } }
            return Double(a.replacingOccurrences(of: "deg", with: "")).map { $0 / scale }
        }
        let alpha = args.count == 4 ? num(args[3], scale: 1) : 1
        guard let al = alpha, (0...1).contains(al) else { return nil }
        switch fn {
        case "rgb", "rgba":
            let v = args.prefix(3).compactMap { num($0, scale: 255) }
            guard v.count == 3, v.allSatisfy({ (0...1).contains($0) }) else { return nil }
            return RGBA(r: v[0], g: v[1], b: v[2], a: al)
        case "hsl", "hsla":
            guard let h = num(args[0], scale: 1).map({ args[0].hasSuffix("%") ? $0 * 360 : $0 }),
                  let sat = num(args[1], scale: 100), let l = num(args[2], scale: 100),
                  (0...1).contains(sat), (0...1).contains(l) else { return nil }
            let c = (1 - abs(2 * l - 1)) * sat, hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
            let (r, g, b): (Double, Double, Double) = hh < 1 ? (c, x, 0) : hh < 2 ? (x, c, 0) : hh < 3 ? (0, c, x) : hh < 4 ? (0, x, c) : hh < 5 ? (x, 0, c) : (c, 0, x)
            return RGBA(r: r + m, g: g + m, b: b + m, a: al)
        default: return nil
        }
    }
    /// "#RRGGBB", or "#RRGGBBAA" when not opaque.
    static func hex(_ c: RGBA) -> String {
        func b(_ v: Double) -> String { String(format: "%02X", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + b(c.r) + b(c.g) + b(c.b) + (c.a < 0.999 ? b(c.a) : "")
    }

    // MARK: links

    /// The words of the one link in a copied piece of HTML, when it points at `url` (a browser's "Copy link" or a
    /// link selected on a page). Only what the copy carried: nothing is fetched.
    static func anchorTitle(html: String, url: String) -> String? {
        let h = String(html.prefix(20_000))
        guard let rx = try? NSRegularExpression(pattern: #"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, options: [.caseInsensitive]) else { return nil }
        let ms = rx.matches(in: h, range: NSRange(h.startIndex..., in: h))
        guard ms.count == 1, let m = ms.first, let hr = Range(m.range(at: 1), in: h), let tr = Range(m.range(at: 2), in: h) else { return nil }
        let href = entities(String(h[hr]))
        guard href == url || href.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return nil }
        let t = entities(String(h[tr]).replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return t.isEmpty || t == url ? nil : String(t.prefix(300))
    }
    static func entities(_ s: String) -> String {
        var t = s
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}
