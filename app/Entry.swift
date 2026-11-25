import Foundation

struct Entry: Identifiable, Hashable {
    let id: String
    let when: Date
    let app: String
    let text: String
    let audio: String
    var secs: Double = 0
    var title = ""
    var raw = ""
    var outcome = ""
    var drafts: [String] = []   // Typed: the drafts this message grew out of, oldest first (TypedList)
    var touched: Date?          // Typed: the last draft or line of this message, when later than `when`
    var started: Date?          // Typed: the first key of this message (a row's "t0"), else its first kept draft
    var est = false             // Typed: the draft's start is an estimate ("est": true, DraftCaptureRules.resolve)
    var sent = false            // Typed: the row stands for a sent line (typed.jsonl), not only drafts
    // Clipboard rows (round three): what the copy is, a link's title, the size, the stored picture and its read text
    var clip = ClipKind.text
    var clipTitle = "", bytes = 0, picture = "", ocr = ""
    var look: [String]?         // a kept picture's Vision labels (nil until named; History.clipLabels, PictureLookRules)
    var shot = ""               // a capture kept as a shot pack: its id (data/shots/<id>/, app/ShotJournal.swift)

    /// A kept picture's kind from its read text and labels (pictures round, 24 November 2026); nil for other rows and PDFs.
    var pictureKind: PictureLookRules.Kind? {
        guard clip == .image, !picture.isEmpty, !text.hasPrefix("PDF") else { return nil }
        return PictureLookRules.kind(ocr: ocr, labels: look ?? [])
    }
    /// The row's line for a picture: "Code · func main()"; nil for other rows.
    var pictureLine: String? {
        pictureKind.map { PictureLookRules.line(kind: $0, ocr: ocr, labels: look ?? [], size: text.replacingOccurrences(of: "Image · ", with: "")) }
    }
    /// What search finds a picture by besides its text: its kind and labels.
    var pictureWords: String { pictureKind.map { PictureLookRules.searchWords(kind: $0, labels: look ?? []) } ?? "" }

    var incomplete: Bool { outcome == "timeout" || outcome == "incomplete" }
    var audioOnly: Bool { text.isEmpty && raw.isEmpty && !incomplete }
    var originalLabel: String { incomplete ? "Last live preview" : "Before cleanup" }
    var summary: String {
        if !text.isEmpty { return text }
        if !raw.isEmpty { return raw }
        return "Audio only · no transcript"
    }
    var notice: String {
        if outcome == "timeout" { return "Transcription timed out. The live preview may be incomplete." }
        if outcome == "incomplete" { return "No final transcript returned. The live preview may be incomplete." }
        return "No final transcript. Play the saved recording to review it."
    }

    func matches(_ query: String) -> Bool {
        let content = [text, raw, app, title, ClipRules.searchExtra(clip, text: text, title: clipTitle, ocr: ocr), pictureWords].joined(separator: "\n").lowercased()
        return query.lowercased().split(whereSeparator: { $0.isWhitespace }).allSatisfy { content.contains($0) }
    }

    /// Old rows remain readable. Keep original-only and playable audio-only takes visible too.
    static func voice(_ row: [String: Any], audioExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Entry? {
        let text = row["text"] as? String ?? "", raw = row["raw"] as? String ?? ""
        let audio = row["audio"] as? String ?? ""
        guard !text.isEmpty || !raw.isEmpty || (!audio.isEmpty && audioExists(audio)) else { return nil }
        var entry = Entry(id: row["id"] as? String ?? "take-\(row["t"] as? Double ?? 0)-\(audio)",
                          when: Date(timeIntervalSince1970: row["t"] as? Double ?? 0),
                          app: row["app"] as? String ?? "", text: text, audio: audio,
                          secs: row["secs"] as? Double ?? 0)
        entry.raw = raw == text ? "" : raw
        entry.outcome = row["outcome"] as? String ?? ""
        entry.title = entry.incomplete ? "Incomplete" : text.isEmpty ? "No transcript" : ""
        return entry
    }
}

/// The Typed page (2026-11-13, window round: the same line showed three or four times as "draft" while it was being
/// typed). One row per message: drafts that the later text of the same app grew out of (or repeats) within 30 minutes
/// fold into it. The row is the sent line when there is one, else the longest draft; the drafts it swallowed stay on the
/// row, oldest first, for the detail. Only the list is built this way: typed.jsonl and drafts.jsonl stay as they are.
enum TypedList {
    static let window: TimeInterval = 30 * 60, sameDay: TimeInterval = 24 * 3600

    /// Is `b` (later, same app) the same message as draft `a`? The same words within a day (he left the field and came
    /// back); within 30 minutes also when it grew out of `a`, he cut it back (not to a stub), or most of it is the same
    /// start with an edit near the end.
    static func same(_ a: String, _ b: String, _ dt: TimeInterval) -> Bool {
        if a == b { return dt <= sameDay }
        guard dt <= window else { return false }
        if b.hasPrefix(a) { return true }
        if a.hasPrefix(b) { return b.count >= max(3, a.count / 2) }
        let k = zip(a, b).prefix { $0 == $1 }.count
        return k >= max(16, Int(Double(min(a.count, b.count)) * 0.6))
    }

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{A0}", with: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Rows as the files hold them ({t, text, app}); newest first out.
    static func build(sent: [[String: Any]], drafts: [[String: Any]]) -> [Entry] {
        struct Item { var e: Entry; let n: String; let sent: Bool }
        func item(_ r: [String: Any], _ kind: String) -> Item? {
            guard let t = r["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let when = r["t"] as? Double ?? 0
            var e = Entry(id: "\(kind)\(when)", when: Date(timeIntervalSince1970: when), app: r["app"] as? String ?? "", text: t, audio: "")
            e.title = kind == "draft" ? "draft" : ""
            if let t0 = r["t0"] as? Double, t0 > 0, t0 <= when { e.started = Date(timeIntervalSince1970: t0) }   // since 2026-11-14 (window round two)
            e.est = (r["est"] as? Bool) == true
            e.sent = kind == "sent"
            return Item(e: e, n: norm(t), sent: kind == "sent")
        }
        let items = (sent.compactMap { item($0, "sent") } + drafts.compactMap { item($0, "draft") }).sorted { $0.e.when < $1.e.when }
        // each draft goes into the next item of the same app that grew out of it (or says the same); a sent line ends
        // a message, so nothing folds past it into a later one
        var into = Array(repeating: -1, count: items.count)
        for i in items.indices where !items[i].sent {
            var j = i + 1
            while j < items.count, items[j].e.when.timeIntervalSince(items[i].e.when) <= sameDay {
                if items[j].e.app == items[i].e.app, same(items[i].n, items[j].n, items[j].e.when.timeIntervalSince(items[i].e.when)) { into[i] = j; break }
                j += 1
            }
        }
        // follow each chain to its end: the row that stands for the message
        func root(_ i: Int) -> Int { var k = i; while into[k] >= 0 { k = into[k] }; return k }
        var groups: [Int: [Int]] = [:]
        for i in items.indices { groups[root(i), default: []].append(i) }
        var out: [Entry] = []
        for (r, members) in groups {
            // the sent line if the chain ends in one; else the longest draft (the latest of equals)
            let rep = items[r].sent ? r : members.max { (items[$0].e.text.count, $0) < (items[$1].e.text.count, $1) }!
            var e = items[rep].e
            e.drafts = members.filter { $0 != rep }.map { items[$0].e.text }
            e.est = items[rep].e.est   // the row shown carries its own mark
            // the newest moment of the message, so it sorts where it was last touched
            if let last = members.map({ items[$0].e.when }).max(), last > e.when { e.touched = last }
            // how long it took: from the first key a row kept ("t0"), else from its first kept draft
            let firsts = members.map { items[$0].e.started ?? items[$0].e.when }
            if let first = firsts.min(), members.count > 1 || items[rep].e.started != nil { e.started = first }
            out.append(e)
        }
        return out.sorted { ($0.touched ?? $0.when) > ($1.touched ?? $1.when) }
    }
}
