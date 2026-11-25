// What a picture is, at a glance (pictures round, 24 November 2026; Andrii: "a quick classifier on the images at least
// to know what we are looking for"). A kept picture is read once on this Mac (its text, History.readClip) and named
// once by Vision (VNClassifyImageRequest labels, PictureLook); these rules turn the two into one kind and one line,
// so a row reads "Code · func main()" instead of "Image · 900 × 703". Pure (Foundation), tests/picture_look_rules.swift.
import Foundation

enum PictureLookRules {
    enum Kind: String, CaseIterable { case code, terminal, chat, table, text, chart, drawing, photo, screen }

    /// The word a row shows first.
    static func word(_ k: Kind) -> String {
        switch k {
        case .code: return "Code"; case .terminal: return "Terminal"; case .chat: return "Chat"; case .table: return "Table"
        case .text: return "Text"; case .chart: return "Chart"; case .drawing: return "Drawing"; case .photo: return "Photo"
        case .screen: return "Screen"
        }
    }

    static let screenLabels: Set<String> = ["screenshot", "document", "printed_page", "receipt"]
    static let chartLabels: Set<String> = ["chart", "diagram", "map"]
    static let drawingLabels: Set<String> = ["art", "illustrations", "drawing", "handwriting", "whiteboard", "cartoon"]
    static let codeStarts = ["func ", "def ", "let ", "var ", "const ", "import ", "return", "class ", "struct ", "if (", "if ",
                             "for ", "while ", "public ", "private ", "#include", "//", "/*", "fn ", "async ", "await ",
                             "export ", "from ", "package ", "type ", "interface ", "enum ", "case ", "guard ", "</", "<div"]

    static func lines(_ ocr: String) -> [String] {
        ocr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A clock on its own ("12:34", "9:05 PM"): chats and mail lists carry many.
    static func isTime(_ s: String) -> Bool {
        s.range(of: #"^\d{1,2}:\d{2}(\s?[AaPp][Mm])?$"#, options: .regularExpression) != nil
    }
    static func isCode(_ s: String) -> Bool {
        let l = s.lowercased()
        if codeStarts.contains(where: { l.hasPrefix($0) }) { return true }
        if let c = s.last, "{};".contains(c) { return true }
        return s.contains(" = ") && (s.contains("(") || s.contains("[")) || s.contains("=>") || s.contains("->") || s.contains("::")
    }
    static func isPrompt(_ s: String) -> Bool {
        if s.hasPrefix("$ ") || s.hasPrefix("% ") || s.hasPrefix("❯") || s.hasPrefix("➜") || s.hasPrefix("> ") { return true }
        if s.hasPrefix("Last login") { return true }
        // user@host dir %, ~/path $
        return s.range(of: #"^\S+@\S+.*[%$#]\s"#, options: .regularExpression) != nil || s.range(of: #"~/\S*\s?[%$❯]"#, options: .regularExpression) != nil
    }
    static func isNumeric(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber).count, letters = s.filter(\.isLetter).count
        return digits >= 2 && digits >= letters
    }
    static func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    /// The kind from the read text first (most kept pictures are screens, and Vision calls them all "screenshot"),
    /// then Vision's labels for pictures with little text.
    static func kind(ocr: String, labels: [String]) -> Kind {
        let ls = lines(ocr), chars = ls.reduce(0) { $0 + $1.count }
        let lab = Set(labels)
        if chars < 25 {
            if !lab.isDisjoint(with: chartLabels) { return .chart }
            if !lab.isDisjoint(with: drawingLabels) { return .drawing }
            if !lab.isDisjoint(with: screenLabels) || labels.isEmpty { return .screen }
            return .photo
        }
        let n = Double(ls.count)
        let prompts = Double(ls.filter(isPrompt).count), code = Double(ls.filter(isCode).count)
        let times = ls.filter(isTime).count, numeric = Double(ls.filter(isNumeric).count)
        let avgWords = Double(ls.reduce(0) { $0 + words($1) }) / max(1, n)
        if prompts >= 2 || (prompts >= 1 && n <= 6) { return .terminal }
        if ls.count >= 3, code / n >= 0.3 { return .code }
        if ls.count >= 6, numeric / n >= 0.45 { return .table }
        if times >= 2, avgWords < 12 { return .chat }
        if !lab.isDisjoint(with: chartLabels), lab.isDisjoint(with: ["screenshot"]) { return .chart }
        if chars >= 300, avgWords >= 5.5 { return .text }
        if lab.isDisjoint(with: screenLabels), !lab.isDisjoint(with: drawingLabels) { return .drawing }
        return .screen
    }

    /// The line that says most about it: the first of the top lines with four words (a sentence, a title), else three words and some letters (not a clock,
    /// not a row of numbers); for code, the first code line. Cut at 90 characters.
    static func headline(_ ocr: String, kind: Kind) -> String {
        let ls = Array(lines(ocr).prefix(16))
        func good(_ s: String) -> Bool {
            let letters = s.filter(\.isLetter).count
            return words(s) >= 3 && s.count >= 12 && Double(letters) >= Double(s.count) * 0.5 && !isTime(s)
        }
        let pick: String?
        switch kind {
        case .code: pick = ls.first(where: { isCode($0) && $0.count >= 8 }) ?? ls.first(where: good)
        case .terminal: pick = (ls.first(where: { isPrompt($0) && !$0.hasPrefix("Last login") }) ?? ls.first(where: isPrompt)).map { p in
            // the command after the prompt
            if let r = p.range(of: #"[%$❯➜#>]\s+"#, options: .regularExpression) { let c = String(p[r.upperBound...]); return c.isEmpty ? p : c }
            return p
        } ?? ls.first(where: good)
        default: pick = ls.first(where: { good($0) && words($0) >= 4 && $0.count >= 20 }) ?? ls.first(where: good)
        }
        let s = pick ?? ls.first(where: { $0.filter(\.isLetter).count >= 3 }) ?? ""
        return s.count > 90 ? String(s.prefix(89)) + "…" : s
    }

    /// Vision's own words, readable: "blue_sky" → "blue sky"; screen words left out (they say nothing).
    static func labelWords(_ labels: [String]) -> [String] {
        labels.filter { !screenLabels.contains($0) }.prefix(3).map { $0.replacingOccurrences(of: "_", with: " ") }
    }

    /// The row's line: "Code · func main()", "Photo · people, outdoor", "Screen · 900 × 703".
    static func line(kind: Kind, ocr: String, labels: [String], size: String) -> String {
        let h = headline(ocr, kind: kind)
        let rest: String
        switch kind {
        case .photo, .drawing, .chart:
            let w = labelWords(labels).joined(separator: ", ")
            rest = !h.isEmpty && kind == .chart ? h : w.isEmpty ? size : w
        default: rest = h.isEmpty ? size : h
        }
        return rest.isEmpty ? word(kind) : word(kind) + " · " + rest
    }

    /// What search finds a picture by besides its text: the kind's word (and "screenshot"/"image") and Vision's labels.
    static func searchWords(kind: Kind, labels: [String]) -> String {
        ([word(kind).lowercased(), "picture", "image"] + labels.map { $0.replacingOccurrences(of: "_", with: " ") }).joined(separator: " ")
    }

    // MARK: the sidecar (data/clips/<name>.look): line 1 the version, line 2 the labels, comma-separated

    static let version = "1"
    static func sidecar(labels: [String]) -> String { version + "\n" + labels.joined(separator: ",") + "\n" }
    /// The labels from a sidecar; nil when missing or written by an older version (then it is made again).
    static func labels(sidecar s: String) -> [String]? {
        let p = s.split(separator: "\n", omittingEmptySubsequences: false)
        guard p.count >= 2, p[0] == version else { return nil }
        return p[1].split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}
