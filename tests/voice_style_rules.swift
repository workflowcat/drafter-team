// swiftc -O -parse-as-library app/VoiceStyleRules.swift tests/voice_style_rules.swift -o app/build/voice-style-rules-test && app/build/voice-style-rules-test
// Voice style per app (plan A1). Made-up lines only.
import Foundation

@main struct Checks {
    static func main() {
        // pick: the app's override, then its kind, then the defaults, then formal
        precondition(VoiceStyleRules.pick(kind: "chat", bundle: "x.chat", byKind: [:], byApp: [:]) == .casual)
        precondition(VoiceStyleRules.pick(kind: "mail", bundle: "x.mail", byKind: [:], byApp: [:]) == .formal)
        precondition(VoiceStyleRules.pick(kind: "chat", bundle: "x.chat", byKind: ["chat": "veryCasual"], byApp: [:]) == .veryCasual)
        precondition(VoiceStyleRules.pick(kind: "chat", bundle: "x.chat", byKind: ["chat": "veryCasual"], byApp: ["x.chat": "formal"]) == .formal)
        precondition(VoiceStyleRules.pick(kind: "odd", bundle: "", byKind: ["odd": "nonsense"], byApp: [:]) == .formal)

        let table: [(String, VoiceStyle, String, Set<String>)] = [
            // formal: capitals, a final dot on 3+ words
            ("ok see you at 5", .formal, "Ok see you at 5.", []),
            ("ok", .formal, "Ok", []),
            ("is it ready?", .formal, "Is it ready?", []),
            ("привіт, буду о п'ятій", .formal, "Привіт, буду о п'ятій.", []),
            ("the link is example.com/page", .formal, "The link is example.com/page", []),
            ("plan:\n1. First thing\n2. Second thing", .formal, "Plan:\n1. First thing\n2. Second thing", []),
            // casual: no final dot on one or two sentences; ? and ! stay
            ("Ok, see you at 5.", .casual, "Ok, see you at 5", []),
            ("Sure. See you at 5.", .casual, "Sure. See you at 5", []),
            ("One. Two. Three.", .casual, "One. Two. Three.", []),
            ("Are you in?", .casual, "Are you in?", []),
            ("Wait...", .casual, "Wait...", []),
            // very casual: small first letters, no final dot
            ("Ok, see you at 5.", .veryCasual, "ok, see you at 5", []),
            ("Sure. See you there. Bring the cake.", .veryCasual, "sure. see you there. bring the cake", []),
            ("Привіт, як справи?", .veryCasual, "привіт, як справи?", []),
            ("I will be late.", .veryCasual, "I will be late", []),
            ("Ira will call you.", .veryCasual, "Ira will call you", ["Ira"]),
            ("Ліна передзвонить.", .veryCasual, "Ліна передзвонить", ["Ліна Квітка"]),
            ("NASA called. DataKit works.", .veryCasual, "NASA called. DataKit works", []),
            ("Mixed text. Добре, see you.", .veryCasual, "mixed text. добре, see you", []),
            ("Plan:\n1. First thing\n2. Second thing", .veryCasual, "plan:\n1. First thing\n2. Second thing", []),
        ]
        for (input, style, want, keep) in table {
            let got = VoiceStyleRules.apply(input, style, keep: keep)
            precondition(got == want, "\(style) «\(input)» -> «\(got)», want «\(want)»")
            precondition(VoiceStyleRules.apply(got, style, keep: keep) == got, "not idempotent: \(style) «\(got)»")
        }
        // a snippet value at the end is never given a dot or re-cased
        precondition(VoiceStyleRules.apply("Here: Https://example.test/x", .formal, verbatim: ["Https://example.test/x"]) == "Here: Https://example.test/x")
        precondition(VoiceStyleRules.apply("Example Value. Thanks.", .veryCasual, verbatim: ["Example Value."]) == "Example Value. thanks")
        // live typing: only the end changes
        precondition(VoiceStyleRules.apply("ok see you at 5", .formal, endOnly: true) == "ok see you at 5.")
        precondition(VoiceStyleRules.apply("Ok, see you.", .veryCasual, endOnly: true) == "Ok, see you")
        print("PASS voice style rules (\(table.count) rows)")
    }
}
