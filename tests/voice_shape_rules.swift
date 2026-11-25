// swiftc -O -parse-as-library app/VoiceStyleRules.swift app/VoiceShapeRules.swift tests/voice_shape_rules.swift -o app/build/voice-shape-rules-test && app/build/voice-shape-rules-test
// Voice shape per app (plan A3). Made-up lines only.
import Foundation

@main struct Checks {
    static func main() {
        let mail: [(String, String)] = [
            ("Hi Ira, thanks for the file. I will read it tonight. Best regards, Alex.",
             "Hi Ira,\n\nThanks for the file. I will read it tonight.\n\nBest regards,\nAlex"),
            ("Привіт, Оксано! Дякую за файл. З повагою, Олег.", "Привіт,\n\nОксано! Дякую за файл.\n\nЗ повагою,\nОлег"),
            ("Добрий день, надсилаю акт. Дякую!", "Добрий день,\n\nНадсилаю акт.\n\nДякую!"),
            // "hi" inside a sentence stays; no listed closing, no sign-off
            ("I said hi to them, then we left.", "I said hi to them, then we left."),
            ("The file is ready, see you on Monday.", "The file is ready, see you on Monday."),
            // a long greeting clause is not a greeting
            ("Hello and welcome to the long meeting notes, here they are.", "Hello and welcome to the long meeting notes, here they are."),
        ]
        for (input, want) in mail {
            let got = VoiceShapeRules.shape(input, kind: "mail", canBreak: true, chatLines: false, emptyField: true)
            precondition(got == want, "mail «\(input)» -> «\(got)»")
        }
        // a reply under text already there (or a subject line with text before it): no greeting lines
        let reply = VoiceShapeRules.shape("Hi Ira, thanks. Best, Alex.", kind: "mail", canBreak: true, chatLines: false, emptyField: false)
        precondition(reply == "Hi Ira, thanks. Best, Alex.", reply)
        // spoken breaks where lines are allowed
        precondition(VoiceShapeRules.shape("first part new paragraph second part", kind: "other", canBreak: true, chatLines: false, emptyField: false)
                     == "first part.\n\nSecond part")
        precondition(VoiceShapeRules.shape("купи хліб, новий рядок молоко", kind: "other", canBreak: true, chatLines: false, emptyField: false)
                     == "купи хліб.\nМолоко")
        // a chat: lines only with the setting, and never when a break cannot be safe (live typing)
        let chat = "Sure. I will be there at 5. Bring the cake."
        precondition(VoiceShapeRules.shape(chat, kind: "chat", canBreak: true, chatLines: false, emptyField: true) == chat)
        precondition(VoiceShapeRules.shape(chat, kind: "chat", canBreak: true, chatLines: true, emptyField: true) == "Sure.\nI will be there at 5.\nBring the cake.")
        precondition(VoiceShapeRules.shape(chat, kind: "chat", canBreak: false, chatLines: true, emptyField: true) == chat)
        precondition(VoiceShapeRules.shape("Hi Ira, thanks. Best, Alex.", kind: "mail", canBreak: false, chatLines: false, emptyField: true) == "Hi Ira, thanks. Best, Alex.")
        // an AI box: as said, even "new line"
        precondition(VoiceShapeRules.shape("fix it new line now", kind: "ai", canBreak: true, chatLines: true, emptyField: true) == "fix it new line now")
        // a list keeps its lines
        let list = "Hi team, the plan:\n1. First thing\n2. Second thing"
        precondition(VoiceShapeRules.shape(list, kind: "mail", canBreak: true, chatLines: false, emptyField: true) == "Hi team,\n\nThe plan:\n1. First thing\n2. Second thing")
        // paragraphs: a long body breaks after 3 sentences and 300 characters
        let s = String(repeating: "This sentence is a made-up line for the paragraph rule and it runs long. ", count: 6).trimmingCharacters(in: .whitespaces)
        let long = VoiceShapeRules.shape("Hi Ira, " + s + " Thanks.", kind: "mail", canBreak: true, chatLines: false, emptyField: true)
        precondition(long.components(separatedBy: "\n\n").count == 4, long)
        print("PASS voice shape rules")
    }
}
