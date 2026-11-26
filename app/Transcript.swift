// Pure parts of a finished recording, kept apart from the app so tests can build them alone
// (tests/transcript_checks.swift): screenshot records, the brief for an agent, the user's microphone's echo of the other side,
// the live text's language.
import Foundation

/// One screenshot kept while a long note or call recorded (Shots.swift takes them).
struct Shot: Codable {
    let t: Double        // seconds on the recording's audio timeline
    let file: String     // "shots/001-00m12s.jpg", relative to the recording folder
    let app: String
    let title: String

    /// What a finished (or recovered) recording kept.
    static func load(_ recording: URL) -> [Shot] {
        guard let d = try? Data(contentsOf: recording.appendingPathComponent("shots.json")) else { return [] }
        return (try? JSONDecoder().decode([Shot].self, from: d)) ?? []
    }
}

enum Transcript {
    /// Same word vote as voice_language.py: >=30% Cyrillic is Ukrainian;
    /// mixed text below that stays unknown, English requires no Cyrillic.
    static func language(_ text: String) -> String? {
        let text = text.precomposedStringWithCanonicalMapping
        let words = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’ʼ][\p{L}\p{N}]+)*"#)
        let cyrillic = try! NSRegularExpression(pattern: #"\p{Cyrillic}"#)
        let latin = try! NSRegularExpression(pattern: #"\p{Latin}"#)
        var count = 0, cyr = 0, english = true
        for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let word = (text as NSString).substring(with: match.range)
            guard word.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) && $0.value != 0x02BC }) else { continue }
            count += 1
            let range = NSRange(word.startIndex..., in: word)
            if cyrillic.firstMatch(in: word, range: range) != nil { cyr += 1 }
            let letters = word.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.value != 0x02BC }
            if letters.contains(where: { u in
                let s = String(u)
                return latin.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil
            }) { english = false }
        }
        if count > 0, cyr * 10 >= count * 3 { return "uk" }
        return count > 0 && cyr == 0 && english ? "en" : nil
    }

    /// The user's microphone also hears the other side through the speakers: a line of the user's that repeats what they said at the
    /// same moment is their voice, not the user's (2026-10-22 call: "Привіт, привіт" and three more lines on both sides).
    static func echoless(_ me: [[String: Any]], _ them: [[String: Any]]) -> [[String: Any]] {
        func words(_ s: Any?) -> [String] {
            ((s as? String) ?? "").lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 2 }
        }
        let theirs = them.map { (s: $0["start"] as? Double ?? 0, e: $0["end"] as? Double ?? 0, w: Set(words($0["text"]))) }
        return me.filter { m in
            let w = words(m["text"]), s = m["start"] as? Double ?? 0, e = m["end"] as? Double ?? s
            guard !w.isEmpty else { return true }
            let near = theirs.filter { $0.s <= e + 3 && $0.e >= s - 3 }.reduce(into: Set<String>()) { $0.formUnion($1.w) }
            let shared = w.filter { near.contains($0) }.count
            return Double(shared) / Double(w.count) < 0.6
        }
    }

}

/// The brief an agent reads: what was said in time order, each screenshot where it was taken.
enum Brief {
    /// Who "Я" is in a call brief: the user's first name from the local config (set at launch), "the user" without one.
    static var me = "the user"
    struct Row { let who: String; let start: Double; let text: String }

    static func stamp(_ t: Double) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }

    /// Writes <recording>/brief.md and returns the line to hand to an agent.
    @discardableResult
    static func write(dir: URL, rows: [Row], shots: [Shot], meta: [String: Any], minutes: Double) -> String {
        let started = Date(timeIntervalSince1970: meta["started"] as? Double ?? Date().timeIntervalSince1970)
        let f = DateFormatter(); f.dateFormat = "d MMMM yyyy, HH:mm"; f.locale = Locale(identifier: "en_GB")
        let call = meta["call"] as? Bool ?? false
        var out = ["# \(call ? "Call" : "Walkthrough") · \(f.string(from: started)) · \(Int(minutes.rounded())) min · \(shots.count) screenshots", ""]
        if let ev = meta["event"] as? [String: Any], let title = ev["title"] as? String, !title.isEmpty {
            let people = (ev["people"] as? [String] ?? []).joined(separator: ", ")
            out.append("Meeting: \(title)" + (people.isEmpty ? "" : " · with \(people)"))
        }
        if let app = meta["app"] as? String, !app.isEmpty { out.append("Recorded in: \(app)") }
        out.append("Folder: \(dir.path)")
        out += ["", "What was said, in time order" + (call ? " (Я = \(me); Вони, Speaker 2, Speaker 3… or a name = the other side; unknown = not placed on anyone)" : "")
                + "; each screenshot sits where it was taken. Open the image files to see them.", ""]
        // speech and pictures on one timeline; one paragraph per speaker until the next picture or speaker
        enum Item { case row(Row), shot(Shot) }
        let items = (rows.map { (t: $0.start, i: Item.row($0)) } + shots.map { (t: $0.t, i: Item.shot($0)) }).sorted { $0.t < $1.t }
        var para: (who: String, start: Double, words: [String])?
        let timed = !shots.isEmpty || rows.contains { $0.start > 0 }   // an older recording kept no times: no 00:00 on every line
        func flush() {
            guard let p = para else { return }
            let head = (timed ? "[\(stamp(p.start))]" : "") + (p.who.isEmpty ? "" : (timed ? " " : "") + p.who + ":")
            out.append((head.isEmpty ? "" : "**\(head)** ") + p.words.joined(separator: " ")); out.append("")
            para = nil
        }
        for (_, item) in items {
            switch item {
            case .row(let r):
                if let p = para, p.who == r.who, p.words.count < 12 { para?.words.append(r.text) }
                else { flush(); para = (r.who, r.start, [r.text]) }
            case .shot(let s):
                flush()
                let label = [stamp(s.t), s.app, s.title].filter { !$0.isEmpty }.joined(separator: " · ")
                out.append("![\(label.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")"))](\(s.file))"); out.append("")
            }
        }
        flush()
        let url = dir.appendingPathComponent("brief.md")
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return handoff(dir: dir, shots: shots.count, minutes: minutes, call: call)
    }

    static func handoff(dir: URL, shots: Int, minutes: Double, call: Bool) -> String {
        "\(call ? "A call" : "A walkthrough") I recorded while showing my screen (\(Int(minutes.rounded())) min, \(shots) screenshots): "
            + dir.appendingPathComponent("brief.md").path
            + " - read it and open the screenshots it points to (in \(dir.appendingPathComponent("shots").path)/)."
    }
}
