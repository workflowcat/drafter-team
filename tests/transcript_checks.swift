import Foundation

// swiftc app/Transcript.swift tests/transcript_checks.swift -o app/build/transcript-test && app/build/transcript-test
@main struct TranscriptChecks {
    static func main() {
        var count = 0
        func check(_ ok: @autoclosure () -> Bool, _ name: String) {
            precondition(ok(), name); count += 1
        }

        // the live text's language (Whisper fallback only)
        check(Transcript.language("Так, я почав малювати, я ще там трошки підчищу, зараз покажу.") == "uk", "Ukrainian live text")
        check(Transcript.language("Take a look at what we've had there for the tourism automation.") == "en", "English live text")
        check(Transcript.language("ok") == "en", "Short English")
        check(Transcript.language("так") == "uk", "Short Ukrainian")
        check(Transcript.language("зроби review у GitHub для DataKit") == "uk", "Long English terms do not outvote Ukrainian words")
        check(Transcript.language("перевір цей pull request") == "uk", "Half Ukrainian")
        check(Transcript.language("а б в one two three four five six seven") == "uk", "Exactly thirty percent")
        check(Transcript.language("а б one two three four five six seven eight") == nil, "Mixed below thirty stays unknown")
        check(Transcript.language("123 !?") == nil, "Numbers do not vote")
        check(Transcript.language("café déjà") == "en", "Latin accents")
        check(Transcript.language("сімʼя GitHub") == "uk", "Apostrophe within a word")
        check(Transcript.language("文字文字") == nil, "Other scripts stay unknown")

        // echo: lines from the 2026-10-22 call, as both sides heard them
        let them: [[String: Any]] = [
            ["start": 28.0, "end": 29.0, "text": "Привіт, привіт, привіт."],
            ["start": 33.0, "end": 42.0, "text": "Поступово, в принципі, можемо там почти все, що треба вговорення і так далі, там колеги поступово будуть доєднуватися, бо не всі одночасно можуть."],
        ]
        let me: [[String: Any]] = [
            ["start": 17.0, "end": 19.0, "text": "Так, я почав малювати."],
            ["start": 28.0, "end": 29.0, "text": "Привіт-привіт."],
            ["start": 32.0, "end": 36.0, "text": "Поступово, в принципі, можемо там починати все, що треба вговорення і так далі."],
            ["start": 36.0, "end": 39.0, "text": "Там колеги поступово буде доєднуватися."],
            ["start": 120.0, "end": 122.0, "text": "Привіт, як справи?"],
        ]
        let mine = Transcript.echoless(me, them)
        let kept = mine.compactMap { $0["text"] as? String }
        check(kept.contains("Так, я почав малювати."), "His own line before they spoke stays")
        check(!kept.contains("Привіт-привіт."), "Their greeting heard through his mic is dropped")
        check(!kept.contains { $0.hasPrefix("Поступово") } && !kept.contains { $0.hasPrefix("Там колеги") }, "Their long lines heard through his mic are dropped")
        check(kept.contains("Привіт, як справи?"), "The same word much later is his own")
        check(Transcript.echoless(me, []).count == me.count, "No other side: nothing dropped")

        // the brief: speech and screenshots on one timeline
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drafter-brief-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shots = [Shot(t: 0.9, file: "shots/001-00m00s.jpg", app: "Figma", title: "Board"),
                     Shot(t: 31.0, file: "shots/002-00m31s.jpg", app: "Dia", title: "Meet [x]")]
        try! JSONEncoder().encode(shots).write(to: dir.appendingPathComponent("shots.json"))
        check(Shot.load(dir).count == 2, "Screenshots load back from shots.json")
        let rows = [Brief.Row(who: "Я", start: 17, text: "Так, я почав малювати."),
                    Brief.Row(who: "Я", start: 20, text: "Я ще там трошки підчищу."),
                    Brief.Row(who: "Вони", start: 28, text: "Привіт, привіт."),
                    Brief.Row(who: "Вони", start: 33, text: "Поступово можемо починати.")]
        let meta: [String: Any] = ["call": true, "app": "Dia", "started": 1792670435.0,
                                   "event": ["title": "Weekly sync", "people": ["Mila", "Sava"]]]
        let line = Brief.write(dir: dir, rows: rows, shots: Shot.load(dir), meta: meta, minutes: 6.6)
        let md = try! String(contentsOf: dir.appendingPathComponent("brief.md"), encoding: .utf8)
        check(md.hasPrefix("# Call · "), "Brief title says call")
        check(md.contains("Meeting: Weekly sync · with Mila, Sava"), "Calendar event and people in the brief")
        check(md.contains("**[00:17] Я:** Так, я почав малювати. Я ще там трошки підчищу."), "One paragraph per speaker")
        let first = md.range(of: "001-00m00s.jpg")!.lowerBound, said = md.range(of: "[00:17]")!.lowerBound
        let second = md.range(of: "002-00m31s.jpg")!.lowerBound, after = md.range(of: "[00:33]")!.lowerBound
        check(first < said && md.range(of: "[00:28]")!.lowerBound < second && second < after, "Screenshots sit where they were taken")
        check(md.contains("Meet (x)") && !md.contains("Meet [x]"), "A ] in a window title cannot break the image link")
        check(line.contains(dir.appendingPathComponent("brief.md").path) && line.contains("2 screenshots") && line.contains("7 min"), "Hand-off line points at the brief")
        let solo = Brief.write(dir: dir, rows: [Brief.Row(who: "", start: 2, text: "This screen is the board.")], shots: shots,
                               meta: ["call": false, "started": 0.0], minutes: 1)
        let md2 = try! String(contentsOf: dir.appendingPathComponent("brief.md"), encoding: .utf8)
        check(md2.hasPrefix("# Walkthrough · ") && md2.contains("**[00:02]** This screen is the board.") && solo.hasPrefix("A walkthrough"), "A long note is a walkthrough")
        print("transcript checks: \(count) passed")
    }
}
