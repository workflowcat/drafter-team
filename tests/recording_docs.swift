import Foundation

// swiftc -parse-as-library app/Transcript.swift app/Recording.swift app/MeetingRules.swift app/CarefulTranscript.swift app/CaptureRules.swift tests/recording_docs.swift -o app/build/recording-docs-test && app/build/recording-docs-test
@main
struct RecordingDocChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    static func main() {
        // a note as notes.py writes it
        let md = """
        # Дзвінок: Weekly sync

        Про: Mila Synthetic, Sava

        ## Головне
        - Agreed on the plan
        - Demo on Friday

        ## Розшифровка
        Я: - not a bullet
        Вони: ok

        ## Фоловапи
        - Mila: send the act

        Запис: /tmp/calls/x
        """
        guard let (audio, n) = NoteFile.parse(md, path: "/n.md") else { check(false, "note parses"); return }
        check(audio == "/tmp/calls/x", "note points at its recording")
        check(n.title == "Weekly sync" && n.people == ["Mila Synthetic", "Sava"], "title and people")
        check(n.points == ["Agreed on the plan", "Demo on Friday"] && n.followups == ["Mila: send the act"], "summary and follow-ups only from their sections")

        // a folder with timed lines and a screenshot
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rec-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["call": true, "app": "Zoom", "started": 1_800_000_000.0, "event": ["title": "Weekly sync", "people": ["alex", "mila"]]]
        try! JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        let rows: [[String: Any]] = [["who": "Я", "start": 1.0, "text": "Привіт."], ["who": "Я", "start": 2.5, "text": "Покажу схему."],
                                     ["who": "Вони", "start": 4.0, "text": "Бачу схему, а де акт?"], ["who": "Я", "start": 9.0, "text": "Акт надішлю ввечері."]]
        try! JSONSerialization.data(withJSONObject: rows).write(to: dir.appendingPathComponent("lines.json"))
        try! Data(count: 44 + 32000 * 90).write(to: dir.appendingPathComponent("me.wav"))
        let d = CallDoc.load(dir, notes: [dir.path: n])
        check(d.title == "Weekly sync" && d.call && d.hasAudio && !d.live, "event title names it")
        check(d.turns.count == 3 && d.turns[0].text == "Привіт. Покажу схему." && d.turns[0].start == 1.0, "same speaker lines run together")
        check(abs(d.secs - 90) < 0.1, "length from the audio")
        check(d.people == ["Mila Synthetic", "Sava"] && d.points.count == 2 && d.todos.count == 1, "summary from the note")
        CallDoc.me = ["alex"]
        check(CallDoc.load(dir, notes: [:]).people == ["mila"], "the user's own key is not a person (local config)")

        // search
        let t = CallDoc.terms("акт схем")
        check(d.matches(t) && !d.matches(CallDoc.terms("бюджет")), "all words somewhere in it")
        check(d.hits(t).first?.id == 1, "the turn with both words first")
        check(CallDoc.snippet(String(repeating: "слово ", count: 40) + "акт тут", ["акт"], width: 40).hasPrefix("…"), "snippet starts near the word")
        check(d.handoff().contains("Summary and to-dos: /n.md"), "one recording handoff points at the note")

        // edits in place from the stream (23 November 2026): points and one line, kept in meta.json; the note and
        // lines.json stay as written, and an edit whose line changed since is left out
        let e1 = CallDoc.lineEdit([], index: 1, was: "Бачу схему, а де акт?", now: "Бачу схему. Де акт?")
        check(CallDoc.originalLine(e1, index: 1) == "Бачу схему, а де акт?" && CallDoc.lineEdit(e1, index: 1, was: "Бачу схему, а де акт?", now: "Бачу схему, а де акт?").isEmpty, "line edit set and dropped")
        try! CallDoc.saveMeta(dir, ["points": ["Plan agreed", "Demo Friday", "Act tonight"], "lineEdits": e1 + [["i": 2, "was": "not this", "now": "x"]]])
        let ed = CallDoc.load(dir, notes: [dir.path: n])
        check(ed.points == ["Plan agreed", "Demo Friday", "Act tonight"], "his points over the note's")
        check(ed.turns[1].text == "Бачу схему. Де акт?" && ed.turns[2].text == "Акт надішлю ввечері.", "his line edit; a stale one is left out")
        try! CallDoc.saveMeta(dir, ["points": nil, "lineEdits": nil])
        check(CallDoc.load(dir, notes: [dir.path: n]).points == ["Agreed on the plan", "Demo on Friday"], "undo: the note's points again")

        // details he edits on the page, speaker names, combined recordings (17 November 2026)
        try! CallDoc.saveMeta(dir, ["title": "Plan review", "place": "Room 4", "project": "Atlas", "details": "", "app": "Microsoft Teams",
                                    "speakers": ["Вони": "Mila Synthetic"]])
        let de = CallDoc.load(dir, notes: [dir.path: n])
        check(de.title == "Plan review" && de.titleSet, "his own title wins over the event's")
        check(de.place == "Room 4" && de.project == "Atlas" && de.details.isEmpty && de.app == "Microsoft Teams", "details and the corrected app")
        check(de.event == "Weekly sync", "the event stays known beside his title")
        check(de.name("Вони") == "Mila Synthetic" && de.name("Я") == "me" && de.name("Speaker 2") == "Speaker 2", "a named speaker, the rest as before")
        check(de.labels == ["Я", "Вони"], "speaker labels in order")
        check(de.matches(CallDoc.terms("atlas mila")), "search finds the project and the person")
        check(de != d, "the page sees the edit")
        let meta2 = (try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as! [String: Any]
        check(meta2["details"] == nil && meta2["call"] as? Bool == true && meta2["event"] != nil, "an empty value is removed, other keys kept")
        try! CallDoc.saveMeta(dir, ["title": "", "place": nil, "project": nil, "speakers": [String: String](), "app": "Zoom", "mergedInto": dir.path + "-merged"])
        let dr = CallDoc.load(dir, notes: [dir.path: n])
        check(dr.title == "Weekly sync" && !dr.titleSet && dr.speakers.isEmpty, "his title and names taken off")
        check(dr.mergedInto == dir.path + "-merged", "a combined source knows where it went")
        try! CallDoc.saveMeta(dir, ["mergedInto": nil, "app": "Zoom"])


        check(d.mine.isEmpty && !d.notesMarkdown().contains("## My notes"), "no notes file: nothing of his own")
        try! "Ask about the pin\n".write(to: dir.appendingPathComponent("my-notes.md"), atomically: true, encoding: .utf8)
        let dm = CallDoc.load(dir, notes: [dir.path: n])
        check(dm.mine == "Ask about the pin", "his notes are read, trimmed")
        check(dm.notesMarkdown().contains("## My notes\nAsk about the pin"), "Copy notes carries his notes")
        check(dm.matches(CallDoc.terms("pin")) && dm != d, "search finds his notes; the page sees the change")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("my-notes.md"))

        // transcript.txt without times, and a long note
        let old = CallDoc.turns("Я: Hello.\nВони: Привит.\nВони: Як справи?\n", call: true)
        check(old.count == 2 && old[1].who == "Вони" && old[1].start == nil, "old call transcript reads as turns")
        let note = CallDoc.turns(String(repeating: "Це одне речення про план. ", count: 30), call: false)
        check(note.count >= 2 && note.allSatisfy { $0.who.isEmpty }, "a long note is cut into paragraphs")

        // brief without times shows no 00:00
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("brief.md"))
        Brief.write(dir: dir, rows: old.map { Brief.Row(who: $0.who, start: 0, text: $0.text) }, shots: [], meta: meta, minutes: 1)
        let brief = (try? String(contentsOf: dir.appendingPathComponent("brief.md"), encoding: .utf8)) ?? ""
        check(brief.contains("**Я:** Hello.") && !brief.contains("[00:00]"), "brief without times")
        try? FileManager.default.removeItem(at: dir)

        // a call with audio and no words (3 November: 1.7 s of microphone, 51 min of the other side, never read)
        let empty = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rec-empty-\(getpid())")
        try? FileManager.default.removeItem(at: empty)
        try! FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: ["call": true, "app": "Zoom", "started": 1_800_000_000.0]).write(to: empty.appendingPathComponent("meta.json"))
        try! Data(count: 44 + 32000 * 2).write(to: empty.appendingPathComponent("me.wav"))
        try! Data(count: 44 + 32000 * 120).write(to: empty.appendingPathComponent("them.wav"))
        var e = CallDoc.load(empty, notes: [:])
        check(abs(e.secs - 120) < 0.1 && abs(e.meSecs - 2) < 0.1, "length from the longer side, so the recording is listed")
        var why = e.whyEmpty(warnings: ["Your microphone gives only silence (muted or taken by another app?)"]).map(\.text)
        check(why == ["Not read yet", "Your microphone recorded 2 s of 2 min", "Your microphone gives only silence (muted or taken by another app?)"], "why: \(why)")
        try! "1".write(to: empty.appendingPathComponent(Unread.marker), atomically: true, encoding: .utf8)
        try! FileManager.default.removeItem(at: empty.appendingPathComponent("them.wav"))
        e = CallDoc.load(empty, notes: [:])
        why = e.whyEmpty(warnings: []).map(\.text)
        check(e.unread && why.first == "Reading stopped before it finished" && why.contains("Other side not captured, or silent the whole time"), "unread and no other side: \(why)")
        try! "2".write(to: empty.appendingPathComponent(Unread.marker), atomically: true, encoding: .utf8)
        check(CallDoc.load(empty, notes: [:]).whyEmpty(warnings: []).first?.text == "Reading stopped 2 times before it finished", "gave up after two tries")
        try! "".write(to: empty.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try! FileManager.default.removeItem(at: empty.appendingPathComponent(Unread.marker))
        check(CallDoc.load(empty, notes: [:]).whyEmpty(warnings: []).first?.text == "Read, and no words were found", "read and empty")
        check(d.whyEmpty(warnings: ["x"]).isEmpty, "a recording with words has no why")
        // meeting notes without a call app (17 November 2026): the page says "In person"; a plain note stays a note
        try! JSONSerialization.data(withJSONObject: ["call": false, "app": "In person", "inPerson": true, "started": 1_800_000_000.0]).write(to: empty.appendingPathComponent("meta.json"))
        let ip = CallDoc.load(empty, notes: [:])
        check(ip.inPerson && ip.kind == "In person" && !ip.call, "in person: kind \(ip.kind)")
        try! JSONSerialization.data(withJSONObject: ["call": false, "app": "Notes", "started": 1_800_000_000.0]).write(to: empty.appendingPathComponent("meta.json"))
        check(CallDoc.load(empty, notes: [:]).kind == "Note", "a plain long note stays a Note")
        try? FileManager.default.removeItem(at: empty)
        print("recording docs: ok")
    }
}
