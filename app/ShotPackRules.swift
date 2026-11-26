// The shot pack (screenshot tool, 15 November 2026; design: docs/research/2026-11-15-screenshot-tool.md): one capture
// ready to hand off - data/shots/<id>/ holds shot.png (as handed off), original.png (only when marked), shot.json
// (this model) and shot.md (the text an agent reads). Pure (Foundation and CoreGraphics only), tested in
// tests/shot_pack_rules.swift. Writing the files and the hand-off: app/Capture*.swift; the journal reads shot.json.
import Foundation
import CoreGraphics

/// One mark as data, in shot.png pixels (origin top-left). `n` is the pin number (pins only, 1-based).
struct ShotMark: Codable, Equatable {
    var kind: String                  // "pin", "arrow", "pen", "box", "highlight", "text", "blur"
    var x: Int, y: Int                // pin: the point; arrow: the tail; others: the top-left corner
    var w = 0, h = 0                  // box, highlight, text, blur: the size
    var toX: Int? = nil, toY: Int? = nil   // arrow: the head
    var n: Int? = nil
    var text = ""
    var points: [[Int]]? = nil        // pen: the stroke's points [x, y] (x, y, w, h: its box)
}

/// One picture of a set (several captures in one hand-off, look round 15 November 2026). The first picture is also
/// kept in the pack's own fields (width, height, marks, crop) so a single shot and an older shot.json read as before.
struct ShotPicture: Codable, Equatable {
    var file: String                  // "shot.png", "shot-2.png", … in the pack's folder
    var width: Int, height: Int
    var marks: [ShotMark] = []
    var crop: [Int]? = nil
    var original: String? = nil       // "original-2.png" once it was marked
    var caption: String? = nil        // the capture deck (17 November 2026): what the user said or typed under this card
    init(file: String, width: Int, height: Int, marks: [ShotMark] = [], crop: [Int]? = nil, original: String? = nil, caption: String? = nil) {
        self.file = file; self.width = width; self.height = height; self.marks = marks; self.crop = crop; self.original = original
        self.caption = caption
    }
}

/// Where a shot was passed on (the list after ⇥, and the record in shot.json).
enum ShotTarget: String, Codable, CaseIterable {
    case field, clipboard, file, claude, codex, claudeCode, ask
    /// A target that is gone (a private app of the first user, or Person, a chat draft, before 26 November 2026) in an old
    /// shot.json reads as Clipboard, so the shot still loads.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ShotTarget(rawValue: raw) ?? .clipboard
    }
    /// The word in the send-to list.
    var word: String {
        switch self {
        case .field: return "Put in"; case .clipboard: return "Clipboard"; case .file: return "File"
        case .claude: return "Claude"; case .codex: return "Codex"; case .claudeCode: return "Claude Code"
        case .ask: return "Ask Claude here"
        }
    }
    /// Leaves the Mac when the user picks it (a cloud mark on the entry).
    var cloud: Bool { self == .ask }
}

struct ShotSent: Codable, Equatable {
    var to: ShotTarget
    var t: Double
    var detail = ""                   // a file's name, a chat's title
}

struct ShotPack: Codable, Equatable {
    var v = 1
    var id: String
    var t: Double                     // seconds since 1970, the capture
    var app = ""
    var window = ""
    var width: Int, height: Int       // shot.png in pixels
    var note = ""
    var noteVia = "typed"             // "typed" or "voice"
    var marks: [ShotMark] = []
    var crop: [Int]? = nil            // [x, y, w, h] in original.png pixels, when cropped
    var read = ""                     // the text read on the picture (OCR, this Mac)
    var found: [String] = []          // links, dates, emails found in `read` (the detector)
    var sent: [ShotSent] = []
    var answer: String? = nil         // "Ask Claude here": the answer
    var pictures: [ShotPicture]? = nil   // a set of two or more; nil for one picture (the fields above)

    static let readMax = 1500

    // MARK: the set (one picture or several)

    /// The pictures in order: `pictures` for a set, else the one in the pack's own fields (its caption is the note).
    var pics: [ShotPicture] {
        if let p = pictures, !p.isEmpty { return p }
        return [ShotPicture(file: ShotPack.pictureFile(0), width: width, height: height, marks: marks, crop: crop,
                            original: marks.isEmpty && crop == nil ? nil : ShotPack.originalFile(0), caption: note.isEmpty ? nil : note)]
    }
    /// Every picture's caption in order ("" where none).
    var captions: [String] { pics.map { ($0.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines) } }
    var count: Int { pics.count }
    /// The set changed: kept in `pictures` (nil for one), the first picture mirrored into the pack's own fields.
    mutating func setPictures(_ ps: [ShotPicture]) {
        var ps = ps
        for i in ps.indices { ps[i].file = ShotPack.pictureFile(i); if ps[i].original != nil { ps[i].original = ShotPack.originalFile(i) } }
        pictures = ps.count > 1 ? ps : nil
        if let f = ps.first { width = f.width; height = f.height; marks = f.marks; crop = f.crop }
        if ps.count == 1, let c = ps[0].caption { note = c }
    }
    /// File names in the pack's folder: shot.png, shot-2.png, …; original.png, original-2.png, ….
    static func pictureFile(_ i: Int) -> String { i == 0 ? "shot.png" : "shot-\(i + 1).png" }
    static func originalFile(_ i: Int) -> String { i == 0 ? "original.png" : "original-\(i + 1).png" }
    /// The paths of every picture, given shot.png's path.
    func paths(_ first: String) -> [String] {
        let dir = (first as NSString).deletingLastPathComponent
        return pics.map { (dir as NSString).appendingPathComponent($0.file) }
    }
    /// Free names for every picture in a folder ("File"): macOS's name, then " (2)", " (3)" for the rest.
    static func fileNames(_ t: Double, count: Int, taken: Set<String>) -> [String] {
        var taken = taken, out: [String] = []
        for _ in 0..<max(1, count) { let n = freeName(fileName(t), taken: taken); taken.insert(n); out.append(n) }
        return out
    }

    // MARK: names

    /// "20261115-104207-3fa1": time, then 4 hex digits so two shots in one second never meet.
    static func makeId(_ t: Double, random r: UInt16) -> String {
        stamp(t, "yyyyMMdd-HHmmss") + "-" + String(format: "%04x", r)
    }
    /// The file name macOS would give: "Screenshot 2026-11-15 at 10.42.07.png".
    static func fileName(_ t: Double) -> String { "Screenshot " + stamp(t, "yyyy-MM-dd 'at' HH.mm.ss") + ".png" }
    /// A name not taken in the folder: "… 10.42.07.png", then "… 10.42.07 (2).png".
    static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var i = 2
        while taken.contains("\(base) (\(i)).\(ext)") { i += 1 }
        return "\(base) (\(i)).\(ext)"
    }
    private static func stamp(_ t: Double, _ f: String) -> String {
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.dateFormat = f
        return d.string(from: Date(timeIntervalSince1970: t))
    }
    /// "Safari «Page»"; a window titled like its app ("Claude «Claude»") gives the app alone.
    static func place(app: String, window: String) -> String {
        let w = window.trimmingCharacters(in: .whitespaces)
        let same = w.isEmpty || w.caseInsensitiveCompare(app) == .orderedSame
        return [app, same ? "" : "«\(w)»"].filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// "15 November 2026 10:42" for the agent text.
    static func when(_ t: Double) -> String { stamp(t, "d MMMM yyyy HH:mm") }

    // MARK: the agent text (shot.md, and the text pasted after the picture)

    /// One line per mark, pins first by number, then the rest in the order drawn.
    static func markLines(_ marks: [ShotMark]) -> [String] {
        let pins = marks.filter { $0.kind == "pin" }.sorted { ($0.n ?? 0) < ($1.n ?? 0) }
        let rest = marks.filter { $0.kind != "pin" }
        func q(_ s: String) -> String { s.isEmpty ? "" : " - \"\(s)\"" }
        var out: [String] = []
        for p in pins { out.append("\(p.n ?? 0). pin at \(p.x),\(p.y)\(q(p.text))") }
        for m in rest {
            switch m.kind {
            case "arrow": out.append("- arrow \(m.x),\(m.y) → \(m.toX ?? m.x),\(m.toY ?? m.y)\(q(m.text))")
            case "blur": out.append("- blurred \(m.x),\(m.y) to \(m.x + m.w),\(m.y + m.h) (hidden on purpose)")
            case "text": out.append("- text at \(m.x),\(m.y)\(q(m.text))")
            case "pen": out.append("- " + PenRules.line(points: m.points?.count ?? 0, x0: m.x, y0: m.y, x1: m.x + m.w, y1: m.y + m.h) + q(m.text))
            default: out.append("- \(m.kind) \(m.x),\(m.y) to \(m.x + m.w),\(m.y + m.h)\(q(m.text))")
            }
        }
        return out
    }

    /// The text an agent reads. `path`: shot.png's absolute path, nil when the picture itself goes along (pasted).
    /// The screen text (OCR) only where the agent may not look at the picture (shot.md, a terminal): with the picture
    /// it was too much (the user, 15 November: "it gives too much information").
    func agentText(path: String?, screenText: Bool? = nil) -> String {
        var where_ = ShotPack.place(app: app, window: window)
        if !where_.isEmpty { where_ = ", " + where_ }
        let pics = self.pics
        var lines: [String] = []
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if pics.count == 1 {
            lines.append(path.map { "Screenshot: \($0) (\(width)×\(height) px\(where_), \(ShotPack.when(t)))" }
                ?? "Screenshot attached (\(width)×\(height) px\(where_), \(ShotPack.when(t)))")
            if !n.isEmpty { lines.append("Note: " + n) }
            let ml = ShotPack.markLines(marks)
            if !ml.isEmpty { lines.append("Marks (pixels in the picture, origin top-left):"); lines += ml }
        } else {
            let w = where_.isEmpty ? "" : String(where_.dropFirst(2)) + ", "
            lines.append((path == nil ? "Screenshots attached: " : "Screenshots: ") + "\(pics.count) pictures (\(w)\(ShotPack.when(t)))")
            if !n.isEmpty { lines.append("Note: " + n) }
            let ps = path.map(paths)
            for (i, p) in pics.enumerated() {
                let at = ps.map { ": " + $0[i] } ?? ""
                lines.append("Picture \(i + 1) of \(pics.count)\(at) (\(p.width)×\(p.height) px)")
                let c = (p.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { lines.append("Caption: " + c) }
                let ml = ShotPack.markLines(p.marks)
                if !ml.isEmpty { lines.append("Marks (pixels in picture \(i + 1), origin top-left):"); lines += ml }
            }
        }
        let r = read.trimmingCharacters(in: .whitespacesAndNewlines)
        if screenText ?? (path != nil), !r.isEmpty {
            lines.append("Screen text (OCR, first 1,500 characters):")
            lines.append(String(r.prefix(ShotPack.readMax)))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: the send-to list

    /// The list after ⇥: the last target used first, then the fixed order. `field` is ↵, never in the list.
    static func order(last: ShotTarget?) -> [ShotTarget] {
        let all = ShotTarget.allCases.filter { $0 != .field }
        guard let l = last, l != .field, all.contains(l) else { return all }
        return [l] + all.filter { $0 != l }
    }

    // MARK: the hand-off (capture side, 15 November 2026)

    /// What the strip's ⇥ list does with a key: digits 1-8 pick that row, ↑↓ move, ↵ picks the chosen row, esc goes back.
    enum ListKey: Equatable { case pick(Int), move(Int), back, none }
    static let digitCodes = [18, 19, 20, 21, 23, 22, 26, 28]   // 1-8 on any layout
    static func listKey(code: Int, sel: Int, count: Int) -> ListKey {
        if let d = digitCodes.firstIndex(of: code) { return d < count ? .pick(d) : .none }
        switch code {
        case 125: return count == 0 ? .none : .move(min(count - 1, sel + 1))
        case 126: return count == 0 ? .none : .move(max(0, sel - 1))
        case 36, 76: return sel < count ? .pick(sel) : .none
        case 53: return .back
        default: return .none
        }
    }

    /// Terminals (Claude Code runs in one), by bundle id.
    static let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                            "dev.warp.Warp", "com.github.wez.wezterm"]
    static let claudeApp = "com.anthropic.claudefordesktop", codexApp = "com.openai.codex"

    /// How ↵ puts the shot into the field the user was in.
    enum FieldWay: Equatable { case agent, terminal, other }
    static func fieldWay(bundle: String, ai: [String]) -> FieldWay {
        if terminals.contains(bundle) { return .terminal }
        if ai.contains(bundle) { return .agent }
        return .other
    }
    /// A paste is allowed in this app: never a skipped one (password managers, Drafter itself), except a terminal,
    /// where the user pressed ↵ to put the line in themselves.
    static func mayPaste(bundle: String, skip: [String]) -> Bool { terminals.contains(bundle) || !skip.contains(bundle) }

    /// One line for a terminal: never a line break (a shell without bracketed paste would run each line, and the read
    /// text could hold anything), the path to the picture and to shot.md, then the user's note.
    func terminalLine(path: String, md: String) -> String {
        var where_ = ShotPack.place(app: app, window: window)
        if !where_.isEmpty { where_ = ", " + where_ }
        var s = "Screenshot \(path) (\(width)×\(height) px\(where_)); its note, marks and screen text: \(md)"
        if count > 1 { s = "Screenshots \(paths(path).joined(separator: " ")) (\(count) pictures\(where_)); their note, marks and screen text: \(md)" }
        let n = ShotPack.oneLine(note)
        if !n.isEmpty { s += ". Note: " + n }
        if count > 1 {
            let cs = captions.enumerated().compactMap { i, c in c.isEmpty ? nil : "\(i + 1) - " + ShotPack.oneLine(c) }
            if !cs.isEmpty { s += ". Captions: " + cs.joined(separator: "; ") }
        }
        return s
    }
    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            .unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(String.init).joined()
    }

    /// What ↵ puts in: the picture or not, then the text (nil = none). `path`: shot.png, `md`: shot.md.
    struct Put: Equatable { let picture: Bool; let text: String? }
    func fieldPut(_ way: FieldWay, path: String, md: String) -> Put {
        switch way {
        case .agent: return Put(picture: true, text: agentText(path: nil))
        case .terminal: return Put(picture: false, text: terminalLine(path: path, md: md))
        case .other:
            let n = deckText
            return Put(picture: true, text: n.isEmpty ? nil : n)
        }
    }

    /// The text after the pictures in an ordinary field: one picture, its note; a deck, the note (if any) and every
    /// caption numbered by its picture ("2. the total"), pictures without one left out.
    var deckText: String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 1 else { return n }
        let cs = captions.enumerated().compactMap { i, c in c.isEmpty ? nil : "\(i + 1). " + c }
        return ([n].filter { !$0.isEmpty } + cs).joined(separator: "\n")
    }

    /// The journal card's line: the note, else a deck's captions in order ("a · b").
    var summary: String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? captions.filter { !$0.isEmpty }.joined(separator: " · ") : n
    }

    /// The app a target brings forward (claude, codex); nil for the others.
    static func appBundle(_ t: ShotTarget) -> String? {
        switch t { case .claude: return claudeApp; case .codex: return codexApp; default: return nil }
    }
    /// Claude Code: the frontmost terminal when one runs (`running`: running apps, the front one first), else the Claude
    /// app (its Code tab).
    static func claudeCodeApp(running: [String]) -> String { running.first { terminals.contains($0) } ?? claudeApp }

    /// Ask Claude here: `claude -p` reads shot.md on stdin, only the Read tool allowed (the picture is beside it).
    static let askTail = "Answer what the note asks about this screenshot. Short."
    static func askInput(_ md: String) -> String { md + "\n\n" + askTail }
    static let askArgs = ["-p", "--allowedTools", "Read", "--output-format", "text"]
    static let askTimeout = 180.0

    /// The found things kept in shot.json: links, e-mails, phones, dates and money, never a sensitive one, each once,
    /// at most 20. `items`: the detector's kind, value and sensitive flag (app/DetectRules.swift), in text order.
    static let foundKinds: Set<String> = ["link", "email", "phone", "date", "dateRange", "money", "address", "path", "issue", "tracking"]
    static func foundValues(_ items: [(kind: String, value: String, sensitive: Bool)]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for i in items where !i.sensitive && foundKinds.contains(i.kind) && !i.value.isEmpty && seen.insert(i.value).inserted {
            out.append(i.value)
            if out.count == 20 { break }
        }
        return out
    }

    /// The pack as written again after a change made elsewhere: what was sent and the answer are never lost.
    func merged(onDisk old: ShotPack?) -> ShotPack {
        guard let old, old.id == id else { return self }
        var p = self
        if p.sent.count < old.sent.count { p.sent = old.sent }
        if p.answer == nil { p.answer = old.answer }
        return p
    }
}
