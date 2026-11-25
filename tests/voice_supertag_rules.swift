// swiftc -O -parse-as-library app/VoiceSupertagRules.swift tests/voice_supertag_rules.swift -o app/build/voice-supertag-rules-test && app/build/voice-supertag-rules-test
// Voice-driven Supertag routing cues (Wave 8C). Synthetic test strings only.
import Foundation

@main struct Checks {
    static func main() {
        precondition(VoiceSupertagKind.allCases == [.task, .idea, .remember, .note])

        struct Case {
            let input: String
            let kind: VoiceSupertagKind
            let person: String?
            let body: String
            let journal: String
            let pill: String
        }

        let positive: [Case] = [
            // English Task
            Case(input: "Task: send the outline tomorrow", kind: .task, person: nil,
                 body: "Send the outline tomorrow", journal: "[Task] Send the outline tomorrow", pill: "Saved as Task"),
            Case(input: "Task — book train tickets", kind: .task, person: nil,
                 body: "Book train tickets", journal: "[Task] Book train tickets", pill: "Saved as Task"),
            Case(input: "Task - check latency numbers", kind: .task, person: nil,
                 body: "Check latency numbers", journal: "[Task] Check latency numbers", pill: "Saved as Task"),
            Case(input: "Task. Ship the patch", kind: .task, person: nil,
                 body: "Ship the patch", journal: "[Task] Ship the patch", pill: "Saved as Task"),
            Case(input: "Task\nUpdate changelog", kind: .task, person: nil,
                 body: "Update changelog", journal: "[Task] Update changelog", pill: "Saved as Task"),
            Case(input: "Todo: buy coffee beans", kind: .task, person: nil,
                 body: "Buy coffee beans", journal: "[Task] Buy coffee beans", pill: "Saved as Task"),
            Case(input: "Todo buy coffee beans", kind: .task, person: nil,
                 body: "Buy coffee beans", journal: "[Task] Buy coffee beans", pill: "Saved as Task"),
            Case(input: "To do: write migration guide", kind: .task, person: nil,
                 body: "Write migration guide", journal: "[Task] Write migration guide", pill: "Saved as Task"),
            Case(input: "To do, write migration guide", kind: .task, person: nil,
                 body: "Write migration guide", journal: "[Task] Write migration guide", pill: "Saved as Task"),
            Case(input: "To-do: clean up scratch files", kind: .task, person: nil,
                 body: "Clean up scratch files", journal: "[Task] Clean up scratch files", pill: "Saved as Task"),
            // Ukrainian Task
            Case(input: "Задача: оновити документацію", kind: .task, person: nil,
                 body: "Оновити документацію", journal: "[Task] Оновити документацію", pill: "Saved as Task"),
            Case(input: "Завдання — перевірити тести", kind: .task, person: nil,
                 body: "Перевірити тести", journal: "[Task] Перевірити тести", pill: "Saved as Task"),
            // English & Ukrainian Idea
            Case(input: "Idea: zoomable timeline", kind: .idea, person: nil,
                 body: "Zoomable timeline", journal: "[Idea] Zoomable timeline", pill: "Saved as Idea"),
            Case(input: "Idea. Split view for notes", kind: .idea, person: nil,
                 body: "Split view for notes", journal: "[Idea] Split view for notes", pill: "Saved as Idea"),
            Case(input: "Idea: iOS companion widget", kind: .idea, person: nil,
                 body: "iOS companion widget", journal: "[Idea] iOS companion widget", pill: "Saved as Idea"),
            Case(input: "Ідея: масштабована шкала часу", kind: .idea, person: nil,
                 body: "Масштабована шкала часу", journal: "[Idea] Масштабована шкала часу", pill: "Saved as Idea"),
            Case(input: "Ідея — темна тема для графіків", kind: .idea, person: nil,
                 body: "Темна тема для графіків", journal: "[Idea] Темна тема для графіків", pill: "Saved as Idea"),
            // English & Ukrainian Remember / Follow-up for person
            Case(input: "Remember for Mila: check contrast in dark mode", kind: .remember, person: "Mila",
                 body: "Check contrast in dark mode", journal: "[For Mila] Check contrast in dark mode", pill: "Note for Mila"),
            Case(input: "Remind for Alex, ask about Thursday", kind: .remember, person: "Alex",
                 body: "Ask about Thursday", journal: "[For Alex] Ask about Thursday", pill: "Note for Alex"),
            Case(input: "Remember for anna marie — send slides", kind: .remember, person: "Anna Marie",
                 body: "Send slides", journal: "[For Anna Marie] Send slides", pill: "Note for Anna Marie"),
            Case(input: "Remember for Anna-Marie: review layout", kind: .remember, person: "Anna-Marie",
                 body: "Review layout", journal: "[For Anna-Marie] Review layout", pill: "Note for Anna-Marie"),
            Case(input: "Remember for J. Smith: share benchmarks", kind: .remember, person: "J. Smith",
                 body: "Share benchmarks", journal: "[For J. Smith] Share benchmarks", pill: "Note for J. Smith"),
            Case(input: "Remember for Mila. Check the export flow", kind: .remember, person: "Mila",
                 body: "Check the export flow", journal: "[For Mila] Check the export flow", pill: "Note for Mila"),
            Case(input: "Remember for O'Connor - confirm schedule", kind: .remember, person: "O'Connor",
                 body: "Confirm schedule", journal: "[For O'Connor] Confirm schedule", pill: "Note for O'Connor"),
            Case(input: "Remember for Maria Clara Silva: send agenda", kind: .remember, person: "Maria Clara Silva",
                 body: "Send agenda", journal: "[For Maria Clara Silva] Send agenda", pill: "Note for Maria Clara Silva"),
            Case(input: "Нагадай для Олени: надіслати макети", kind: .remember, person: "Олени",
                 body: "Надіслати макети", journal: "[For Олени] Надіслати макети", pill: "Note for Олени"),
            Case(input: "Запам'ятай для Тараса, перевірити збірку", kind: .remember, person: "Тараса",
                 body: "Перевірити збірку", journal: "[For Тараса] Перевірити збірку", pill: "Note for Тараса"),
            Case(input: "Запам’ятай для Міли — оновити палітру", kind: .remember, person: "Міли",
                 body: "Оновити палітру", journal: "[For Міли] Оновити палітру", pill: "Note for Міли"),
            Case(input: "Запамʼятай для Міли: перевірити шрифт", kind: .remember, person: "Міли",
                 body: "Перевірити шрифт", journal: "[For Міли] Перевірити шрифт", pill: "Note for Міли"),
            // English & Ukrainian Quick Note
            Case(input: "Quick note: dark mode contrast looks off", kind: .note, person: nil,
                 body: "Dark mode contrast looks off", journal: "[Note] Dark mode contrast looks off", pill: "Saved as Note"),
            Case(input: "Quick note test on smaller screen", kind: .note, person: nil,
                 body: "Test on smaller screen", journal: "[Note] Test on smaller screen", pill: "Saved as Note"),
            Case(input: "Note to self: bring power adapter", kind: .note, person: nil,
                 body: "Bring power adapter", journal: "[Note] Bring power adapter", pill: "Saved as Note"),
            Case(input: "Note to self bring power adapter", kind: .note, person: nil,
                 body: "Bring power adapter", journal: "[Note] Bring power adapter", pill: "Saved as Note"),
            Case(input: "Нотатка: перевірити резервну копію", kind: .note, person: nil,
                 body: "Перевірити резервну копію", journal: "[Note] Перевірити резервну копію", pill: "Saved as Note"),
        ]

        for c in positive {
            guard let m = VoiceSupertagRules.parse(c.input) else {
                preconditionFailure("expected supertag match for «\(c.input)»")
            }
            precondition(m.kind == c.kind, "kind mismatch for «\(c.input)»: got \(m.kind), want \(c.kind)")
            precondition(m.targetPerson == c.person, "person mismatch for «\(c.input)»: got \(String(describing: m.targetPerson)), want \(String(describing: c.person))")
            precondition(m.body == c.body, "body mismatch for «\(c.input)»: got «\(m.body)», want «\(c.body)»")
            let j = VoiceSupertagRules.formatForJournal(m)
            precondition(j == c.journal, "journal mismatch for «\(c.input)»: got «\(j)», want «\(c.journal)»")
            let p = VoiceSupertagRules.pillSummary(m)
            precondition(p == c.pill, "pill mismatch for «\(c.input)»: got «\(p)», want «\(c.pill)»")
        }

        // Zero false positives on normal dictation, mid-sentence mentions, compounds, and tiny fragments.
        let negative: [String] = [
            "",
            "   ",
            "I have a task for you tomorrow",
            "My idea is good",
            "Let me share a quick note about the release",
            "This is a note to self from yesterday",
            "To do this right, we need more time",
            "Task force meets at noon",
            "Task is done for today",
            "Task-based workflow scales better",
            "Task.swift compiles cleanly",
            "Tasks: one, two, three",
            "Idea is to ship tomorrow",
            "Ideas: alpha and beta",
            "Todo list is getting long",
            "Quick note is already saved",
            "Note to self was empty",
            "Задача була складною",
            "Задача, яку ми обговорювали вчора",
            "Завдання, про яке я казав",
            "Ідея дуже цікава",
            "Ідея, яку варто перевірити",
            "Idea, maybe we should wait",
            "Task, however, is still pending",
            "Нотатка про вчорашню зустріч",
            "Task: ",
            "Task: ok",
            "Idea: hi",
            "Задача: ок",
            "Task: ...",
            "Remember for Mila: ok",
            "Remember for : check this",
            "Remember for One Two Three Four: too many words",
            "Remember for Mila check contrast",
            "Remember for 123: check contrast",
            "Remember for the: check contrast",
            "Remind me to call later",
        ]

        for s in negative {
            let got = VoiceSupertagRules.parse(s)
            precondition(got == nil, "false positive on «\(s)»: got \(String(describing: got))")
        }

        print("PASS voice supertag rules (\(positive.count) positive, \(negative.count) negative)")
    }
}
