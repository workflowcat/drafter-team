// swiftc -parse-as-library app/TranscriptFormats.swift tests/transcript_formats.swift -o app/build/transcript-formats-test && app/build/transcript-formats-test
// Made-up lines only.
import Foundation

@main
struct TranscriptFormatsChecks {
    static var failed = 0, passed = 0
    static func check(_ ok: Bool, _ what: String) { if ok { passed += 1 } else { print("FAIL: " + what); failed += 1 } }

    struct Cue { var n: Int; var a: Double; var b: Double; var text: String }
    static func secs(_ s: String) -> Double {
        let p = s.split(whereSeparator: { $0 == ":" || $0 == "," }).map { Double($0)! }
        return p[0] * 3600 + p[1] * 60 + p[2] + p[3] / 1000
    }
    static func parse(_ srt: String) -> [Cue] {
        srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { block in
            let l = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let t = l[1].components(separatedBy: " --> ")
            return Cue(n: Int(l[0]) ?? -1, a: secs(t[0]), b: secs(t[1]), text: l[2...].joined(separator: "\n").trimmingCharacters(in: .newlines))
        }
    }
    static func near(_ a: Double, _ b: Double, _ e: Double = 0.002) -> Bool { abs(a - b) <= e }

    static func main() {
        // stamps
        for (t, want) in [(0.0, "00:00"), (5.4, "00:05"), (65, "01:05"), (3599.9, "59:59"), (3600, "1:00:00"), (3725, "1:02:05"), (36000, "10:00:00")] {
            check(TranscriptFormats.stamp(t) == want, "stamp \(t) -> \(TranscriptFormats.stamp(t)), want \(want)")
        }
        check(TranscriptFormats.srtTime(3725.25) == "01:02:05,250", "srtTime hours")
        check(TranscriptFormats.srtTime(0) == "00:00:00,000", "srtTime zero")

        let lines = [
            CueLine(who: "Mila", start: 0, text: "Agree on the plan."),
            CueLine(who: "Ostap", start: 4, text: "Fine, I send the draft on Friday."),
            CueLine(who: "", start: 4.3, text: "Yes."),
            CueLine(who: "Mila", start: 12, text: "Good, see you then."),
        ]

        // plain text
        let txt = TranscriptFormats.text(lines)
        check(txt.hasPrefix("[00:00] Mila: Agree on the plan.\n[00:04] Ostap: Fine,"), "text shape: \(txt)")
        check(txt.contains("\n[00:04] Yes.\n"), "text without who")
        check(TranscriptFormats.text([CueLine(who: "", start: nil, text: "Just words.")]) == "Just words.\n", "text without time or who")
        check(TranscriptFormats.text([]) == "", "empty text")

        // SRT numbering, format, ends
        let srt = TranscriptFormats.srt(lines)
        let cues = parse(srt)
        check(cues.map(\.n) == [1, 2, 3, 4], "numbering \(cues.map(\.n))")
        check(srt.hasPrefix("1\n00:00:00,000 --> 00:00:03,950\nMila: Agree on the plan.\n\n2\n"), "first cue shape: \(srt.prefix(80))")
        check(cues.count == 4 && near(cues[0].b, 3.95), "end = next start - 0.05")
        check(cues.count == 4 && near(cues[1].b, 4.5), "end never before start + 0.5 (\(cues.count > 1 ? cues[1].b : -1))")
        check(cues.count == 4 && cues[2].text == "Yes.", "no prefix without who")
        check(cues.count == 4 && near(cues[3].b, 12 + 1.4), "last end = start + 4 words * 0.35")
        check(srt.hasSuffix("then.\n"), "ends with one newline")
        let r = Set(srt.components(separatedBy: "\n").filter { $0.contains("-->") }.map { $0.range(of: #"^\d\d:\d\d:\d\d,\d\d\d --> \d\d:\d\d:\d\d,\d\d\d$"#, options: .regularExpression) != nil })
        check(r == [true], "every time line matches HH:MM:SS,mmm --> HH:MM:SS,mmm")

        // last cue bounds: 1 s minimum, 7 s maximum, total caps
        check(near(parse(TranscriptFormats.srt([CueLine(who: "", start: 2, text: "Hi.")]))[0].b, 3), "last cue at least 1 s")
        let wordy = Array(repeating: "word", count: 30).joined(separator: " ")
        let w = parse(TranscriptFormats.srt([CueLine(who: "", start: 0, text: wordy)]))
        check(near(w.last!.b, 7), "last cue at most 7 s (\(w.last!.b))")
        check(near(parse(TranscriptFormats.srt([CueLine(who: "", start: 10, text: "Thanks a lot, everyone.")], total: 10.8))[0].b, 10.8), "total caps the last end")

        // splitting a long line at sentence ends
        let long = CueLine(who: "Ostap", start: 20, text: "We start with the warehouse list on Monday. Then the prices go to the client, and the client picks the date. After that we book the van.")
        let sp = parse(TranscriptFormats.srt([long, CueLine(who: "", start: 40, text: "Okay.")]))
        check(sp.count >= 4, "long line split into \(sp.count - 1) cues")
        check(sp.dropLast().allSatisfy { $0.text.count <= 84 + "Ostap: ".count }, "each part at most 84 characters")
        check(sp.dropLast().allSatisfy { $0.text.hasPrefix("Ostap: ") }, "who on every part")
        check(near(sp[0].a, 20) && near(sp[sp.count - 2].b, 39.95), "parts span the line's time")
        check(zip(sp, sp.dropFirst()).allSatisfy { $0.b <= $1.a + 0.0001 && $0.a < $0.b }, "parts in order, no overlap")
        check(sp.dropLast().allSatisfy { $0.b - $0.a <= 7.01 }, "no part longer than 7 s: \(sp.map { $0.b - $0.a })")
        check(sp[0].text.hasSuffix("Monday."), "split at a sentence end: \(sp[0].text)")
        // longer text gets more time
        let p0 = sp[0], p1 = sp[1]
        check((p0.b - p0.a) / Double(p0.text.count) > 0.05 && (p1.b - p1.a) / Double(p1.text.count) > 0.05, "times shared by length")

        // a single long sentence splits at commas
        let commas = CueLine(who: "", start: 0, text: "Bring the keys, the two signed copies of the agreement, the stamp for the delivery note, and the spare cable for the scanner")
        let cs = parse(TranscriptFormats.srt([commas, CueLine(who: "", start: 6, text: "Sure.")]))
        check(cs.count >= 3 && cs.dropLast().allSatisfy { $0.text.count <= 84 }, "comma split: \(cs.map(\.text))")
        check(cs[0].text.hasSuffix(","), "comma split ends at a comma")

        // short line lasting long: splits by time when it has sentences
        let slow = parse(TranscriptFormats.srt([CueLine(who: "", start: 0, text: "Right. Let me think. Okay, yes."), CueLine(who: "", start: 20, text: "Go on.")]))
        check(slow.count >= 3, "20 s cue splits at sentences: \(slow.map(\.text))")

        // untimed lines follow at reading pace
        let un = parse(TranscriptFormats.srt([
            CueLine(who: "A", start: nil, text: "One two three four."),
            CueLine(who: "B", start: nil, text: "Five six."),
            CueLine(who: "A", start: nil, text: "Seven."),
        ]))
        check(un.count == 3 && near(un[0].a, 0) && near(un[1].a, 1.4) && near(un[2].a, 2.4), "untimed starts \(un.map(\.a))")
        check(un.count == 3 && near(un[0].b, 1.35) && near(un[2].b, 3.4), "untimed ends \(un.map(\.b))")
        // an untimed line after a timed one
        let mix = parse(TranscriptFormats.srt([CueLine(who: "", start: 30, text: "Hello there."), CueLine(who: "", start: nil, text: "Hi.")]))
        check(near(mix[1].a, 31), "untimed after timed starts at reading pace: \(mix[1].a)")
        check(TranscriptFormats.srt([]) == "", "empty srt")
        check(parse(TranscriptFormats.srt([CueLine(who: "", start: 1, text: "  "), CueLine(who: "", start: 2, text: "Ok.")])).map(\.n) == [1], "blank lines dropped")

        // hours in SRT
        check(TranscriptFormats.srt([CueLine(who: "", start: 3725.5, text: "Late.")]).contains("01:02:05,500 --> 01:02:06,500"), "srt past an hour")

        // markdown
        let md = TranscriptFormats.markdown(title: "Plan call", meta: "18 November 2026 · 12 min", summary: ["Plan agreed."], todos: ["Send the draft"], lines: lines)
        check(md.hasPrefix("# Plan call\n\n18 November 2026 · 12 min\n\n## Summary\n\n- Plan agreed.\n\n## To-dos\n\n- [ ] Send the draft\n\n## Transcript\n\n"), "markdown head: \(md.prefix(160))")
        check(md.contains("**Mila** [00:00] Agree on the plan.\n\n**Ostap** [00:04] Fine,"), "markdown paragraphs")
        check(md.contains("\n\n[00:04] Yes.\n\n"), "markdown line without who")
        check(md.hasSuffix("see you then.\n"), "markdown ends with one newline")
        let bare = TranscriptFormats.markdown(title: "Note", meta: "", summary: [], todos: [" "], lines: [CueLine(who: "", start: nil, text: "Words.")])
        check(bare == "# Note\n\n## Transcript\n\nWords.\n", "empty parts left out: \(bare.debugDescription)")
        check(TranscriptFormats.markdown(title: "", meta: "", summary: [], todos: [], lines: []) == "", "all empty")
        check(TranscriptFormats.markdown(title: "T", meta: "", summary: [], todos: [], lines: [CueLine(who: "A", start: 3700, text: "x")]).contains("**A** [1:01:40] x"), "markdown hours")

        print(failed == 0 ? "transcript formats: \(passed) checks pass" : "transcript formats: \(failed) failed, \(passed) pass")
        exit(failed == 0 ? 0 : 1)
    }
}
