// swiftc -parse-as-library app/CommandRules.swift tests/command_rules.swift -o app/build/command-rules-test && app/build/command-rules-test
// The one `;` picker's rules: ranking, aliases, labels, the typed query and Right ⌘ twice. Made-up rows only.
import Foundation

@main
struct CommandRulesTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL", what) } }

    static let items: [CommandItem] = [
        CommandItem(kind: .snippet, key: ";sig", title: "Best regards, Sample Person", ref: ";sig"),
        CommandItem(kind: .snippet, key: ";addr", title: "Sample st 1, Example City", ref: ";addr"),
        CommandItem(kind: .preset, key: ";gmeet", title: "New Google Meet", detail: "meet.google.com"),
        CommandItem(kind: .preset, key: ";sheet", title: "New sheet", detail: "sheets.new"),
        CommandItem(kind: .lookup, key: ";docs", title: "Search Google Drive", on: false, ref: "docs"),
        CommandItem(kind: .lookup, key: ";meetings", title: "Find a meeting link", on: false, ref: "meetings"),
        CommandItem(kind: .person, key: "", title: "Ana Example", detail: "Sample Studio", ref: "0"),
        CommandItem(kind: .card, key: "", title: "Meetup Sample", ref: "3"),
    ]

    static func main() {
        // ;free rows with a day set (availability round 2): only for ;fr…, in the field's language, keys the lookup reads
        check(CommandRules.freeRows(";fr", uk: false, on: true).count == 4, "free rows for ;fr")
        check(CommandRules.freeRows(";free", uk: true, on: true).first?.title == "Вільний час: завтра, 30 хв", "free rows in Ukrainian")
        check(CommandRules.freeRows(";docs", uk: false, on: true).isEmpty && CommandRules.freeRows("", uk: false, on: true).isEmpty, "no free rows for other queries")
        check(CommandRules.freeRows(";free", uk: false, on: false).allSatisfy { !$0.on && $0.kind == .lookup }, "free rows off without Google")
        let ranked = CommandRules.filter([CommandItem(kind: .lookup, key: ";free", title: "Find free times to insert")] + CommandRules.freeRows(";free", uk: false, on: true), ";free")
        check(ranked.first?.key == ";free" && ranked.count == 5, "plain ;free first, then the set ones")
        // exact key first, then key prefix, then title words
        let me = CommandRules.filter(items, "mee").map(\.title)
        check(me.first == "Find a meeting link", "key prefix ;mee -> ;meetings first: \(me)")
        let gm = CommandRules.filter(items, "gm").map(\.title)
        check(gm.first == "New Google Meet", "key prefix ;gm -> the Meet quick start: \(gm)")
        let tie = CommandRules.filter([CommandItem(kind: .lookup, key: ";x1", title: "Sample row", on: false), CommandItem(kind: .preset, key: ";x2", title: "Sample row")], "sample")
        check(tie.first?.key == ";x2", "on before off in one rank")
        check(me.contains("Meetup Sample"), "a title word matches")
        check(CommandRules.filter(items, ";sig").first?.key == ";sig", "with the ; typed")
        check(CommandRules.filter(items, "ana").first?.kind == .person, "a person by name")
        check(CommandRules.filter(items, "zzz").isEmpty, "nothing")
        check(CommandRules.filter(items, "").count == CommandRules.most, "empty query: the first rows")

        // hidden aliases: ;doc means ;docs while no item owns ;doc; a quick start that owns ;doc wins
        check(CommandRules.filter(items, "doc").first?.key == ";docs", ";doc -> ;docs")
        let withDoc = items + [CommandItem(kind: .preset, key: ";doc", title: "New Google Doc")]
        check(CommandRules.filter(withDoc, "doc").first?.key == ";doc", "an owned ;doc wins over the alias")
        let withEn = items + [CommandItem(kind: .snippet, key: ";en", title: "translate")]
        check(CommandRules.filter(withEn, "e").first?.key == ";en", ";e -> ;en")

        // meeting notes (17 November 2026): ;meet and ;notes find the one row, first; ;gmeet is Google Meet now
        let meet = [CommandItem(kind: .action, key: ";meet", title: "Start meeting notes", detail: "call or in person", ref: "meeting-notes")] + items
        check(CommandRules.filter(meet, ";meet").first?.ref == "meeting-notes", ";meet -> meeting notes")
        check(CommandRules.filter(meet, ";notes").first?.ref == "meeting-notes", ";notes -> meeting notes (alias)")
        check(CommandRules.filter(meet, ";no").first?.ref == "meeting-notes", ";no -> meeting notes by its title")
        check(CommandRules.filter(meet, ";gmeet").first?.title == "New Google Meet", ";gmeet -> Google Meet")
        // voice modes (research item 3): ;mode lists the levels and his modes; ;mode-em finds his Email mode
        let vm = CommandRules.voiceModeRows(modes: ["Email"], current: "Clean", uk: false)
        check(vm.map(\.title) == ["Voice mode: Raw", "Voice mode: Clean", "Voice mode: Polished", "Voice mode: Email"], "mode rows: \(vm.map(\.title))")
        check(vm[1].detail == "now" && vm[3].detail == "my mode" && vm[3].ref == "voice-mode:Email", "now and ref")
        check(CommandRules.filter(vm + items, ";mode").count == 4, ";mode lists 4")
        check(CommandRules.filter(vm + items, ";mode-em").first?.ref == "voice-mode:Email", ";mode-em -> Email")
        check(CommandRules.filter(vm + items, ";voice").first?.kind == .action, ";voice finds a mode row by its title")
        check(CommandRules.voiceModeRows(modes: [], current: "", uk: true)[0].title == "Режим голосу: Raw", "Ukrainian label")
        check(CommandRules.filter(meet + [CommandItem(kind: .snippet, key: ";notes", title: "my notes snippet", ref: ";notes")], ";notes").first?.kind == .snippet,
              "a snippet that owns ;notes wins over the alias")
        check(CommandRules.label(.action, uk: false) == "start" && CommandRules.label(.action, uk: true) == "почати", "action label")

        // labels in the field's language
        check(CommandRules.label(.preset, uk: false) == "open" && CommandRules.label(.preset, uk: true) == "відкрити", "labels")
        check(CommandRules.cyrillic("привіт, як справи"), "Cyrillic line")
        check(!CommandRules.cyrillic("see you at noon"), "Latin line")

        // the typed query
        check(CommandRules.typed("hi ;me")! == (";me", "me"), ";me after a space")
        check(CommandRules.typed(";sig")! == (";sig", "sig"), "at the line start")
        check(CommandRules.typed("hi ;m") == nil, "one letter is not enough")
        check(CommandRules.typed("a;me") == nil, "glued to a word")
        check(CommandRules.typed("x;\n;ана")! == (";ана", "ана"), "last line, Cyrillic")
        check(CommandRules.typed("hi ;me now") == nil, "a space after it ends it")

        // Right ⌘ twice
        var t = RightCommandTaps()
        func tap(_ at: Double, len: Double = 0.08, others: Bool = false, mouse: Bool = false) -> Bool {
            _ = t.rightCommand(down: true, at: at, others: others, mouse: mouse)
            return t.rightCommand(down: false, at: at + len, others: others, mouse: mouse)
        }
        check(!tap(0) && tap(0.2), "two quick taps fire")
        t = RightCommandTaps(); check(!tap(0) && !tap(0.6), "too slow apart")
        t = RightCommandTaps(); check(!tap(0) && !tap(0.2, len: 0.3), "second press held too long")
        t = RightCommandTaps(); check(!tap(0, len: 0.3) && !tap(0.4), "first press held too long")
        t = RightCommandTaps(); _ = tap(0); t.other(); check(!tap(0.2), "a key between")
        t = RightCommandTaps(); check(!tap(0) && !tap(0.2, others: true), "another modifier held")
        t = RightCommandTaps(); check(!tap(0) && !tap(0.2, mouse: true), "during a drag")
        t = RightCommandTaps(); check(!tap(0) && tap(0.2) && !tap(0.4) && tap(0.6), "a third tap starts over")

        print(failed == 0 ? "command rules: all passed" : "command rules: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
