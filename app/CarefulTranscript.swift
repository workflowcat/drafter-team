// The second transcript (17 November 2026): a finished call or long note read again on the team server with a bigger
// Whisper (bench/jobs.py, kind "careful"). It comes back as careful.json beside the recording, one list per side:
// {model, at, me: [{start, end, text}], them: [...]}. Here the sides are merged the way the first reading merges them
// (TalkRecord.transcribe): his mic's echo of them taken out, "Я" / "Вони" for a call, time order, same-speaker lines run
// together. The recording page switches between the two (Recordings.swift, `carefulOn`). Pure Foundation:
// tests/careful_transcript.swift.
import Foundation

enum CarefulTranscript {
    static let file = "careful.json"

    /// careful.json's data -> (turns, model); nil when it does not parse or holds no words.
    static func turns(_ data: Data, call: Bool, solo: String = "") -> (turns: [Turn], model: String)? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let a = j["me"] as? [[String: Any]] ?? [], b = j["them"] as? [[String: Any]] ?? []
        let mine = call ? Transcript.echoless(a, b) : a
        let rows = mine.map { (call ? "Я" : solo, $0) } + b.map { ("Вони", $0) }
        let ordered = rows.sorted { ($0.1["start"] as? Double ?? 0) < ($1.1["start"] as? Double ?? 0) }
        let t = CallDoc.merge(ordered.map { ($0.0, $0.1["start"] as? Double ?? 0, $0.1["text"] as? String ?? "") })
        return t.isEmpty ? nil : (t, j["model"] as? String ?? "")
    }

    static func load(_ dir: URL, call: Bool, solo: String = "") -> (turns: [Turn], model: String)? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return nil }
        return turns(d, call: call, solo: solo)
    }
}

extension CallDoc {
    /// The same document with the careful turns in place of the first reading's (search, play-along and copy follow).
    func withCareful() -> CallDoc {
        guard !careful.isEmpty else { return self }
        var c = self; c.turns = careful; return c
    }
}
