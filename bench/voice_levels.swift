// swiftc -O -parse-as-library app/Words.swift app/Rules.swift app/SnippetRules.swift app/SpokenSnippetRules.swift app/VoiceStyleRules.swift app/VoiceShapeRules.swift app/VoicePipeline.swift app/VoiceModeRules.swift bench/voice_levels.swift -o app/build/voice-levels-bench && app/build/voice-levels-bench
// Added latency per voice level (research item 3) on 20 made-up takes: Raw (as heard) and Clean (Tidy, Rules, shape,
// style), in this process; Polished is measured through the live engine (bench/voice_polish.py). Made-up lines only.
import Foundation

enum Home { static let words = URL(fileURLWithPath: NSTemporaryDirectory() + "drafter-bench-words.json") }

@main
struct VoiceLevelsBench {
    static let takes = [
        "um so can we move the the call to thursday at ten", "I think uh the invoice is ready, scratch that, almost ready",
        "please send the drawings to the station team before lunch", "ok so first the order form second the check mark third the map",
        "hmm let me think, the strip on both sides looks off", "можемо перенести дзвінок на четвер на десяту",
        "e-e я думаю що рахунок вже готовий", "send it to the whole team and copy me please",
        "so the the plan is simple we ship on friday", "new line thanks for the notes yesterday",
        "the station map needs one more check before we print it", "uh can you look at the order form again",
        "let's keep the old drawings and add the new ones at the end", "so um the meeting moved to monday morning",
        "I'll call you after the review tomorrow", "please fix the check mark on page two and three",
        "ok the invoice and the drawings both go out today", "um we look at the strip again on both sides",
        "send the notes to Mila and Sava after the sync", "so overall the plan works but the dates are tight",
    ]

    static func pct(_ xs: [Double], _ p: Double) -> Double { let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))] }

    static func main() {
        try? "{}".write(to: Home.words, atomically: true, encoding: .utf8)
        var raw: [Double] = [], clean: [Double] = []
        let ctx = VoiceContext(kind: "chat", bundle: "com.example.chat", style: .casual)
        for t in takes {
            var a = Date(); var r = ""
            for _ in 0..<20 { r = t.trimmingCharacters(in: .whitespacesAndNewlines) }   // Raw: what finish() does
            raw.append(Date().timeIntervalSince(a) * 1000 / 20)
            a = Date(); var c = ""
            for i in 0..<20 {
                let v = VoicePipeline.run(t + String(repeating: " ", count: i + 1), ctx, tidy: Tidy.marked)   // a new string each time: no memo hit
                c = VoicePipeline.render(v.text, ctx)
            }
            clean.append(Date().timeIntervalSince(a) * 1000 / 20)
            _ = r; _ = c
        }
        print(String(format: "raw   p50 %.3f ms  p90 %.3f ms", pct(raw, 0.5), pct(raw, 0.9)))
        print(String(format: "clean p50 %.3f ms  p90 %.3f ms", pct(clean, 0.5), pct(clean, 0.9)))
    }
}
