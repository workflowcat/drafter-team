import Foundation

// swiftc -parse-as-library app/IdeaRules.swift tests/idea_rules.swift -o app/build/idea-rules-test && app/build/idea-rules-test
// Made-up lines only.
@main
struct IdeaRuleChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    static func main() {
        for s in ["[12/11/2026, 15:32:05] Sample Person: see you at the station tomorrow",
                  "[1/2/26, 9:05 AM] Sample: ok",
                  "12.11.26, 15:32 - Sample Person: see you there",
                  "Sample Person, [12.11.2026 15:32]",
                  "[15:32, 12/11/2026] Sample: hi",
                  "first line\n[12/11/2026, 15:32:05] Sample: second"] {
            check(IdeaRules.chatExport(s), "chat export: \(s)")
        }
        for s in ["meeting at 15:32 tomorrow, ok?", "12/11 works for me", "[draft] notes for friday", "Ratio 3:2, see [1]"] {
            check(!IdeaRules.chatExport(s), "typed, not an export: \(s)")
        }
        let export = "[12/11/2026, 15:32:05] Sample Person: the parcel arrives on thursday morning"
        let typed = "Thanks, I will look at it today and come back."
        let copied = "Here is the address of the sample office building."
        let sent = Array(repeating: export, count: 4) + Array(repeating: typed, count: 3) + Array(repeating: copied + " See you.", count: 3)
            + [String(repeating: "long pasted text. ", count: 30)] + Array(repeating: "Sample sentence that is quite long. Another one.", count: 3)
        let ideas = IdeaRules.ideas(sent: sent, clipboard: ["some other copy", "  here is the ADDRESS of the sample   office building. "],
                                    have: ["sample sentence that is quite long."], hidden: [], limit: 10)
        let texts = ideas.map(\.text)
        check(texts.contains(typed), "a typed phrase sent three times is offered: \(texts)")
        check(!texts.contains { $0.contains("15:32") || $0.contains("parcel") }, "a chat export line is never offered")
        check(!texts.contains(copied), "a sentence found in the clipboard is not offered")
        check(!texts.contains { $0.contains("long pasted") }, "a very long line is not offered")
        check(!texts.contains("Sample sentence that is quite long."), "an existing shortcut is not offered")
        check(texts.contains("Another one.") == false, "under 20 characters is not a phrase")
        check(ideas.first { $0.text == typed }?.count == 3, "counted three times")
        let hidden = IdeaRules.ideas(sent: sent, clipboard: [], have: [], hidden: [typed.lowercased()], limit: 10)
        check(!hidden.map(\.text).contains(typed), "a hidden phrase stays hidden")
        print("idea rules: all checks passed")
    }
}
