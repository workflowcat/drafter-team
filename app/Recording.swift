// A recorded call or long note as one document (2026-10-30, the user: "more like Granola: the text, search all of the
// conversations for a quick overview, send it to the agents quickly"). Built from the recording folder (meta.json,
// lines.json or transcript.txt, shots.json) and the note the engine saved for it (data/notes/*.md, its "Запис:" line
// points back here). Pure Foundation: tests/recording_docs.swift builds it with Transcript.swift alone.
import Foundation

struct Turn: Identifiable, Hashable {
    let id: Int
    let who: String        // "Я", "Вони", or "" in a long note
    let start: Double?     // seconds on the audio timeline, when the reading kept times (lines.json)
    let text: String
}

/// The summary part of a saved note.
struct NoteFile {
    var path = ""
    var title = ""
    var people: [String] = []
    var points: [String] = []
    var followups: [String] = []

    /// data/notes/*.md as notes.py writes it -> (the recording folder it belongs to, its parts).
    static func parse(_ text: String, path: String) -> (audio: String, note: NoteFile)? {
        var n = NoteFile(path: path), audio = "", section = ""
        for raw in text.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("# "), n.title.isEmpty {
                n.title = String(l.dropFirst(2)).replacingOccurrences(of: "Дзвінок: ", with: "").trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("## ") { section = String(l.dropFirst(3))
            } else if l.hasPrefix("Про: "), n.people.isEmpty {
                n.people = l.dropFirst(5).components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if l.hasPrefix("Запис: ") { audio = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("- ") {
                if section == "Головне" { n.points.append(String(l.dropFirst(2))) }
                if section == "Фоловапи" { n.followups.append(String(l.dropFirst(2))) }
            }
        }
        return audio.isEmpty ? nil : (audio, n)
    }
}

struct CallDoc: Identifiable, Hashable {
    /// The user's own keys among a calendar event's people (never shown as a person): set at launch from the local
    /// config, the e-mail name and own names, lower case.
    static var me: Set<String> = []
    let id: String          // the folder path
    var call = false
    var started = Date(timeIntervalSince1970: 0)
    var secs: Double = 0
    var app = ""
    var file = ""           // a transcribed file: its name (meta "file", FileTranscribe)
    var inPerson = false    // meeting notes with no call app (meta "inPerson", app/MeetingNotes.swift)
    var event = ""          // the calendar event's title
    var title = ""
    var people: [String] = []
    var points: [String] = []
    var todos: [String] = []
    var turns: [Turn] = []
    var shots: [Shot] = []
    // details the user can edit on the page (meta.json, 17 November 2026): their title, place, project and notes, the call app
    var titleSet = false        // the title is the user's own (meta "title")
    var place = ""
    var project = ""
    var details = ""
    var calendar = ""           // the calendar event's calendar
    var eventStart: Double?     // the event's start and end (unix s)
    var eventEnd: Double?
    var speakers: [String: String] = [:]   // a speaker label ("Вони", "Speaker 2") -> the person the user named
    var merged: [String] = []   // a combined recording: the recordings and takes it was made from
    var mergedInto: String?     // this one was combined into another recording
    var mine = ""           // the user's own notes typed in the recording window (my-notes.md, app/RecordWindow.swift)
    var note = ""           // the note file with the summary, when there is one
    var live = false        // still recording (raw .pcm, no .wav yet)
    var hasAudio = false
    var meSecs: Double = 0      // each side's audio on disk (a side can be far shorter: 3 November, 1.7 s of 51 min)
    var themSecs: Double = 0
    var read = false            // a reading finished: transcript.txt or lines.json is there
    var unread = false          // the .unread marker: closed, its reading not finished (Unread, the calls round)
    var unreadTries = 0         // readings started after a restart
    var timed: Bool { turns.contains { $0.start != nil } }
    var dir: URL { URL(fileURLWithPath: id) }

    static func == (a: CallDoc, b: CallDoc) -> Bool {
        a.id == b.id && a.title == b.title && a.turns.count == b.turns.count && a.points == b.points && a.live == b.live
            && a.read == b.read && a.unread == b.unread && a.secs == b.secs && a.mine == b.mine
            && a.place == b.place && a.project == b.project && a.details == b.details && a.app == b.app && a.speakers == b.speakers
            && a.mergedInto == b.mergedInto
    }

    /// Why a finished recording shows no words, one line each, the problems first marked as such (13 November: it said
    /// only "No words in this recording"). `warnings` are the side warnings logged while it ran.
    func whyEmpty(warnings: [String]) -> [(problem: Bool, text: String)] {
        guard turns.isEmpty, !live else { return [] }
        var out: [(Bool, String)] = []
        if !read {
            if unread && unreadTries >= Unread.maxAttempts { out.append((true, "Reading stopped \(unreadTries) times before it finished")) }
            else if unread { out.append((true, "Reading stopped before it finished")) }
            else { out.append((false, "Not read yet")) }
        } else { out.append((true, "Read, and no words were found")) }
        if call, themSecs == 0 { out.append((true, "Other side not captured, or silent the whole time")) }
        if hasAudio, meSecs < 3 || (themSecs > 60 && meSecs < themSecs * 0.2) {
            out.append((true, call && themSecs > 0 ? "Your microphone recorded \(CallDoc.length(meSecs)) of \(CallDoc.length(themSecs))"
                                                     : "Your microphone recorded only \(CallDoc.length(meSecs))"))
        }
        for w in warnings where !out.contains(where: { $0.1 == w }) { out.append((true, w)) }
        return out
    }
    func hash(into h: inout Hasher) { h.combine(id) }

    // MARK: reading a folder

    static func load(_ d: URL, notes: [String: NoteFile]) -> CallDoc {
        let fm = FileManager.default
        func file(_ n: String) -> URL { d.appendingPathComponent(n) }
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file("meta.json")))) as? [String: Any] ?? [:]
        var c = CallDoc(id: d.path)
        c.call = meta["call"] as? Bool ?? false
        c.started = Date(timeIntervalSince1970: meta["started"] as? Double ?? 0)
        c.app = meta["app"] as? String ?? ""
        c.file = meta["file"] as? String ?? ""
        c.inPerson = meta["inPerson"] as? Bool ?? false
        c.place = meta["place"] as? String ?? ""
        c.project = meta["project"] as? String ?? ""
        c.details = meta["details"] as? String ?? ""
        c.speakers = meta["speakers"] as? [String: String] ?? [:]
        c.merged = meta["merged"] as? [String] ?? []
        c.mergedInto = (meta["mergedInto"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let ev = meta["event"] as? [String: Any]
        c.calendar = ev?["calendar"] as? String ?? ""
        c.eventStart = ev?["start"] as? Double; c.eventEnd = ev?["end"] as? Double
        if c.place.isEmpty { c.place = ev?["place"] as? String ?? "" }
        c.event = (ev?["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        c.live = fm.fileExists(atPath: file("me.pcm").path) && !fm.fileExists(atPath: file("me.wav").path)
        c.hasAudio = fm.fileExists(atPath: file("me.wav").path)
        func seconds(_ u: URL, header: Int) -> Double {
            let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
            return size > header ? Double(size - header) / 32000 : 0
        }
        c.meSecs = c.live ? seconds(file("me.pcm"), header: 0) : seconds(file("me.wav"), header: 44)
        c.themSecs = c.live ? seconds(file("them.pcm"), header: 0) : seconds(file("them.wav"), header: 44)
        c.secs = max(c.meSecs, c.themSecs)
        c.read = fm.fileExists(atPath: file("transcript.txt").path) || fm.fileExists(atPath: file("lines.json").path)
        let mark = file(Unread.marker)
        c.unread = fm.fileExists(atPath: mark.path)
        c.unreadTries = c.unread ? Int((try? String(contentsOf: mark, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 : 0
        c.shots = Shot.load(d)
        c.mine = ((try? String(contentsOf: file("my-notes.md"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let rows = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file("lines.json")))) as? [[String: Any]], !c.live {
            c.turns = merge(rows.map { ($0["who"] as? String ?? "", $0["start"] as? Double, $0["text"] as? String ?? "") })
        } else {
            let text = (c.live ? nil : try? String(contentsOf: file("transcript.txt"), encoding: .utf8))
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? (try? String(contentsOf: file("live.txt"), encoding: .utf8)) ?? ""
            c.turns = turns(text, call: c.call && !c.live)
        }
        let n = notes[d.path] ?? notes[d.standardizedFileURL.path]
        c.note = n?.path ?? ""
        c.points = n?.points ?? []
        // the user's own edits in place (stream round, 23 November 2026): points the user rewrote, transcript lines the user fixed; the
        // note file and lines.json stay as the engine wrote them
        if let own = meta["points"] as? [String], !own.isEmpty { c.points = own }
        if let edits = meta["lineEdits"] as? [[String: Any]] { c.turns = applyLineEdits(c.turns, edits) }
        c.todos = n?.followups ?? []
        c.people = n?.people ?? []
        if c.people.isEmpty { c.people = (ev?["people"] as? [String] ?? []).filter { !CallDoc.me.contains($0.lowercased()) && !$0.isEmpty } }
        let own = (meta["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        c.titleSet = !own.isEmpty
        c.title = !own.isEmpty ? own : c.event.isEmpty ? (n?.title ?? "") : c.event
        if c.title.isEmpty { c.title = c.turns.first.map { first($0.text, words: 7) } ?? "" }
        if c.title.isEmpty { c.title = c.call ? "Call" : "Note" }
        return c
    }

    /// Transcript lines the user changed: each edit names the line, what it said and what it says now. An edit whose line no
    /// longer says what it did (the recording was read again) is left out.
    static func applyLineEdits(_ turns: [Turn], _ edits: [[String: Any]]) -> [Turn] {
        var out = turns
        for e in edits {
            guard let i = e["i"] as? Int, i >= 0, i < out.count, let was = e["was"] as? String, let now = e["now"] as? String,
                  out[i].text == was else { continue }
            out[i] = Turn(id: out[i].id, who: out[i].who, start: out[i].start, text: now)
        }
        return out
    }
    /// The edits with one line set (a second edit of the same line keeps its first `was`).
    static func lineEdit(_ edits: [[String: Any]], index: Int, was: String, now: String) -> [[String: Any]] {
        var out = edits.filter { ($0["i"] as? Int) != index }
        if now != was { out.append(["i": index, "was": was, "now": now]) }
        return out
    }
    /// What a line said before the user first changed it.
    static func originalLine(_ edits: [[String: Any]], index: Int) -> String? {
        edits.first { ($0["i"] as? Int) == index }?["was"] as? String
    }

    /// Every note file that names a recording folder, by that folder.
    static func notesIndex(_ folder: URL) -> [String: NoteFile] {
        var out: [String: NoteFile] = [:]
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {   // the newest note for a folder wins (a recording read again gets a new note)
            guard let t = try? String(contentsOf: f, encoding: .utf8), t.contains("Запис: "), let (audio, n) = NoteFile.parse(t, path: f.path) else { continue }
            out[audio] = n
        }
        return out
    }

    /// Lines of the same speaker run together into one turn (a few sentences), as people read a conversation.
    static func merge(_ rows: [(String, Double?, String)]) -> [Turn] {
        var out: [Turn] = []
        var cur: (who: String, start: Double?, text: String)?
        func flush() { if let c = cur, !c.text.isEmpty { out.append(Turn(id: out.count, who: c.who, start: c.start, text: c.text)) }; cur = nil }
        for (who, start, text) in rows {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let c = cur, c.who == who, c.text.count + t.count < 420 { cur?.text += " " + t }
            else { flush(); cur = (who, start, t) }
        }
        flush()
        return out
    }

    /// transcript.txt without times: "Я: …" / "Вони: …" lines for a call, a running text for a note (cut into short
    /// paragraphs at sentence ends).
    static func turns(_ text: String, call: Bool) -> [Turn] {
        if call {
            return merge(text.components(separatedBy: "\n").compactMap { l in
                let l = l.trimmingCharacters(in: .whitespaces)
                guard !l.isEmpty else { return nil }
                for who in ["Я", "Вони"] where l.hasPrefix(who + ": ") { return (who, nil, String(l.dropFirst(who.count + 2))) }
                return ("", nil, l)
            })
        }
        var paras: [String] = [], cur = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            cur += (cur.isEmpty ? "" : " ") + s
            if cur.count > 280 { paras.append(cur); cur = "" }
        }
        if !cur.isEmpty { paras.append(cur) }
        return paras.enumerated().map { Turn(id: $0.offset, who: "", start: nil, text: $0.element) }
    }

    static func first(_ s: String, words n: Int) -> String {
        let w = s.split(separator: " ")
        return w.prefix(n).joined(separator: " ") + (w.count > n ? "…" : "")
    }

    // MARK: search

    static func terms(_ q: String) -> [String] { q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// Every search word somewhere in the recording (title, people, summary, what was said, app).
    func matches(_ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let all = ([title, event, app, people.joined(separator: " "), mine, place, project, details] + Array(speakers.values) + points + todos + turns.map(\.text)).joined(separator: "\n").lowercased()
        return terms.allSatisfy { all.contains($0) }
    }

    /// The turns that hold a search word, the ones with more of the words first, then in time order.
    func hits(_ terms: [String]) -> [Turn] {
        guard !terms.isEmpty else { return [] }
        var scored: [(turn: Turn, n: Int)] = []
        for t in turns {
            let low = t.text.lowercased()
            let n = terms.filter { low.contains($0) }.count
            if n > 0 { scored.append((t, n)) }
        }
        scored.sort { a, b in a.n != b.n ? a.n > b.n : a.turn.id < b.turn.id }
        return scored.map { $0.turn }
    }

    /// A short piece of a turn around the first search word.
    static func snippet(_ text: String, _ terms: [String], width: Int = 120) -> String {
        let low = text.lowercased()
        guard let r = terms.compactMap({ low.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return String(text.prefix(width)) }
        let at = low.distance(from: low.startIndex, to: r.lowerBound)
        let from = max(0, at - width / 3), chars = Array(text)
        let to = min(chars.count, from + width)
        return (from > 0 ? "…" : "") + String(chars[from..<to]).trimmingCharacters(in: .whitespaces) + (to < chars.count ? "…" : "")
    }

    // MARK: words for people and agents

    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMMM yyyy, HH:mm"; return f }()
    static func length(_ s: Double) -> String { s >= 60 ? "\(Int((s / 60).rounded())) min" : "\(Int(s)) s" }
    static func who(_ w: String) -> String { w == "Я" ? "me" : w == "Вони" ? "them" : w }
    /// A speaker as shown: the person the user named for that label, else me / them / the label.
    func name(_ w: String) -> String { speakers[w].flatMap { $0.isEmpty ? nil : $0 } ?? CallDoc.who(w) }
    /// The speaker labels in this recording, in order of first turn.
    var labels: [String] { var seen: [String] = []; for t in turns where !t.who.isEmpty && !seen.contains(t.who) { seen.append(t.who) }; return seen }
    /// The language most of it is in ("uk", "en"), from the words.
    var language: String? { Transcript.language(turns.prefix(80).map(\.text).joined(separator: " ")) }

    /// Changes keys of meta.json in place (nil or "" removes one), the others kept.
    static func saveMeta(_ dir: URL, _ set: [String: Any?]) throws {
        let url = dir.appendingPathComponent("meta.json")
        var meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        for (k, v) in set {
            if let v, !((v as? String)?.trimmingCharacters(in: .whitespaces).isEmpty ?? false), !((v as? [String: String])?.isEmpty ?? false) { meta[k] = v }
            else { meta[k] = nil }
        }
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    var kind: String { live ? "Recording now" : call ? "Call" : !file.isEmpty ? "File" : inPerson ? MeetingRules.inPersonLabel : "Note" }

    /// Title, date, people, summary and to-dos as Markdown (Copy notes).
    func notesMarkdown() -> String {
        var out = ["# \(title)", "\(kind) · \(CallDoc.day.string(from: started)) · \(CallDoc.length(secs))" + (people.isEmpty ? "" : " · with \(people.joined(separator: ", "))"), ""]
        if !points.isEmpty { out += ["## Summary"] + points.map { "- " + $0 } + [""] }
        if !todos.isEmpty { out += ["## To-dos"] + todos.map { "- [ ] " + $0 } + [""] }
        if !mine.isEmpty { out += ["## My notes", mine, ""] }
        if !details.isEmpty { out += ["## Details", details, ""] }
        if points.isEmpty && todos.isEmpty { out += turns.prefix(6).map { (name($0.who).isEmpty ? "" : name($0.who) + ": ") + $0.text } }
        return out.joined(separator: "\n")
    }

    /// The line that hands this recording to an agent: where the brief and the note are.
    func handoff() -> String {
        var out = "\(call ? "A call" : "A note") I recorded: «\(title)», \(CallDoc.day.string(from: started)), \(CallDoc.length(secs))"
            + (people.isEmpty ? "" : ", with \(people.joined(separator: ", "))") + "."
        if live { out += "\nStill recording. What was heard so far (live text, rough): " + dir.appendingPathComponent("live.txt").path
            + (shots.isEmpty ? "" : "\nScreenshots so far: " + dir.appendingPathComponent("shots").path + "/") }
        else { out += "\nEverything said, in time order" + (shots.isEmpty ? "" : ", with \(shots.count) screenshots where they were taken (open the images it points to)")
            + ": " + dir.appendingPathComponent("brief.md").path }
        if !note.isEmpty { out += "\nSummary and to-dos: " + note }
        return out
    }

    /// Rows for brief.md when the folder has none yet (a recording without screenshots, or an older one).
    var briefRows: [Brief.Row] { turns.map { Brief.Row(who: $0.who, start: $0.start ?? 0, text: $0.text) } }
}
