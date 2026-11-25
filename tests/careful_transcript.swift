import Foundation

// swiftc -parse-as-library app/Transcript.swift app/Recording.swift app/MeetingRules.swift app/CaptureRules.swift app/CarefulTranscript.swift tests/careful_transcript.swift -o app/build/careful-transcript-test && app/build/careful-transcript-test
// careful.json (the server's second reading, bench/jobs.py) -> turns, merged like the first reading. Made-up lines only.
@main
struct CarefulChecks {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL", what) } }

    static func main() {
        let call = """
        {"model": "large-v3", "at": 1, "me": [{"start": 0.5, "end": 2, "text": "Добрий день, це вигаданий рядок."},
          {"start": 4.0, "end": 5.5, "text": "Send the deck on Friday"}, {"start": 9, "end": 10, "text": "Домовились."}],
         "them": [{"start": 3.8, "end": 5.6, "text": "Send the deck on Friday"}, {"start": 6, "end": 8, "text": "Sure, before noon."}]}
        """
        guard let r = CarefulTranscript.turns(Data(call.utf8), call: true) else { check(false, "call parses"); return done() }
        check(r.model == "large-v3", "model kept")
        check(r.turns.map(\.who) == ["Я", "Вони", "Я"], "echo taken out, sides in time order: \(r.turns.map(\.who))")
        check(r.turns[1].text == "Send the deck on Friday Sure, before noon.", "same speaker runs together: \(r.turns[1].text)")
        check(r.turns[0].start == 0.5, "times kept")

        let note = #"{"model": "large-v3", "me": [{"start": 0, "end": 3, "text": "A made-up long note."}, {"start": 3, "end": 6, "text": "Second line."}]}"#
        let n = CarefulTranscript.turns(Data(note.utf8), call: false)
        check(n?.turns.count == 1 && n?.turns[0].who == "", "a note is one speaker with no name")

        check(CarefulTranscript.turns(Data(#"{"me": [], "them": []}"#.utf8), call: true) == nil, "no words: nil")
        check(CarefulTranscript.turns(Data("not json".utf8), call: true) == nil, "bad file: nil")

        var d = CallDoc(id: "/tmp/x"); d.turns = [Turn(id: 0, who: "Я", start: 0, text: "first")]
        check(d.withCareful().turns.first?.text == "first", "no careful: the first reading stays")
        d.careful = r.turns
        check(d.withCareful().turns.count == 3, "careful replaces the turns")
        done()
    }
    static func done() { print(failed == 0 ? "careful transcript: all passed" : "careful transcript: \(failed) failed"); exit(failed == 0 ? 0 : 1) }
}
