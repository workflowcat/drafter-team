// swiftc -O -parse-as-library app/Rules.swift app/SnippetRules.swift app/SpokenSnippetRules.swift app/VoiceStyleRules.swift app/VoiceShapeRules.swift app/VoicePipeline.swift tests/voice_pipeline.swift -o app/build/voice-pipeline-test && app/build/voice-pipeline-test
// The voice pipeline (plan: one pure way from heard to the field). Made-up takes only. Tidy reads the dictionary
// file, so a stand-in drops "uh"/"um" and counts them; Rules are the real ones.
import Foundation

@main struct Checks {
    static func tidy(_ s: String) -> (text: String, fillers: Int, repeats: Int) {
        var words: [String] = [], f = 0, r = 0
        for w in s.split(separator: " ").map(String.init) {
            let bare = w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",."))
            if ["uh", "um", "е-е"].contains(bare) { f += 1; continue }
            if let last = words.last, last.lowercased() == w.lowercased() { r += 1; continue }
            words.append(w)
        }
        var t = words.joined(separator: " ")
        if let c = t.first { t = c.uppercased() + t.dropFirst() }
        return (t, f, r)
    }

    static func main() {
        let names = ["Ліна", "Sava", "Mila"]
        // golden: the neutral text is the old finish (names(apply(clean(x)))) byte for byte
        let takes = ["давай зустрінемось о 2, ні тобто о 3", "send it to Sava, I mean to Mila please",
                     "купи хліб. Купи молоко, scratch that. Купи сир", "план такий: перше зробити звіт, друге надіслати звіт, третє запланувати дзвінок",
                     "напиши Ліно що буду о 5", "Can you check please? Yeah, thank you. Yeah.", "Is this okay", "uh so the the plan is ready",
                     "What I mean is that we need more time", "meet at 2.30, no wait, at 3", "Mm-hmm. Yeah.", "", "ok"]
        let plain = VoiceContext(names: names)
        for t in takes {
            let old = Rules.names(Rules.apply(tidy(t).text), names)
            let new = VoicePipeline.run(t, plain, tidy: tidy).text
            precondition(old == new, "golden «\(t)»: «\(old)» vs «\(new)»")
        }
        // marks: counts per take, a note only when something was removed or added
        func marks(_ t: String, _ c: VoiceContext = plain) -> CleanMarks { VoicePipeline.run(t, c, tidy: tidy).marks }
        precondition(marks("uh so the the plan is ready um").note() == "Cleaned: 2 fillers · 1 repeat")
        precondition(marks("send it to Sava, I mean to Mila please").note() == "Cleaned: 1 correction")
        precondition(marks("купи хліб. Купи молоко, scratch that. Купи сир").note() == "Cleaned: 1 correction")
        precondition(marks("Can you check please? Yeah.").note() == "Cleaned: 1 closing word")
        precondition(marks("план такий: перше звіт, друге дзвінок").note() == "list")
        precondition(marks("All good here").note() == nil)
        precondition(marks("").note() == nil)
        precondition(CleanMarks(fillers: 3, repeats: 1, corrections: 2, closing: 1).note() == "Cleaned: 3 fillers · 2 corrections · 1 repeat")
        precondition(CleanMarks(fillers: 1).log == "f=1 r=0 c=0 s=0 t=0 l=0 n=0")

        // render: the same neutral text, three apps
        let snippets = [";linkedin": "https://example.test/in/someone"]
        var c = VoiceContext(spoken: SpokenSnippetRules.cues(snippets: snippets, meta: [:]), snippets: snippets)
        let r = VoicePipeline.run("uh here is the link, my LinkedIn.", c, tidy: tidy)
        precondition(r.text == "Here is the link, https://example.test/in/someone" && r.keys == [";linkedin"] && r.marks.snippets == 1, r.text)
        precondition(r.marks.note() == "Cleaned: 1 filler · 1 snippet", r.marks.note() ?? "nil")
        c.verbatim = r.values
        c.kind = "chat"; c.style = .veryCasual
        precondition(VoicePipeline.render(r.text, c) == "here is the link, https://example.test/in/someone")
        c.kind = "mail"; c.style = .formal; c.emptyField = true
        precondition(VoicePipeline.render(r.text, c) == "Here is the link, https://example.test/in/someone")   // no dot after a link
        // the three takes of the round's report
        let demo: [(String, String, VoiceStyle, Bool, String)] = [
            ("um ok so I'll be there at 5. yeah.", "chat", .veryCasual, false, "ok so I'll be there at 5"),
            ("hi Ira, thanks for the the file. I will send the act on Monday, no wait, on Tuesday. best regards, Alex", "mail", .formal, true,
             "Hi Ira,\n\nThanks for the file. I will send the act on Tuesday.\n\nBest regards,\nAlex"),
            ("привіт, е-е скинь мені акт. Окей.", "chat", .casual, false, "Привіт, скинь мені акт"),
        ]
        for (heard, kind, style, empty, want) in demo {
            let ctx = VoiceContext(kind: kind, style: style, emptyField: empty)
            let got = VoicePipeline.render(VoicePipeline.run(heard, ctx, tidy: tidy).text, ctx)
            precondition(got == want, "demo «\(heard)» -> «\(got)»")
        }
        // live typing: no lines, no snippets, only the final mark
        let live = VoiceContext(kind: "mail", style: .formal, live: true, emptyField: true, spoken: c.spoken, snippets: snippets)
        precondition(VoicePipeline.run("My LinkedIn.", live, tidy: tidy).keys.isEmpty)
        precondition(VoicePipeline.render("Hi Ira, thanks. Best regards, Alex", live) == "Hi Ira, thanks. Best regards, Alex.")
        print("PASS voice pipeline (\(takes.count) golden takes)")
    }
}
