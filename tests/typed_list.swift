import Foundation

// swiftc -parse-as-library app/Entry.swift app/PictureLookRules.swift app/ClipRules.swift tests/typed_list.swift -o app/build/typed-list-test && app/build/typed-list-test
// Made-up lines only.
@main
struct TypedListChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }
    static func row(_ t: Double, _ text: String, _ app: String = "Chat") -> [String: Any] { ["t": t, "text": text, "app": app] }

    static func main() {
        let base = 1_800_000_000.0
        let drafts = [
            row(base, "see you at"), row(base + 20, "see you at the"), row(base + 40, "see you at the station"),   // grew, then sent
            row(base + 100, "the report is in the folder"), row(base + 130, "the report is in the folder"),        // left twice, never sent
            row(base + 200, "different app line", "Mail"),
            row(base + 5000, "much later about something else"),
            row(base + 6000, "ok"), row(base + 6010, "ok, that one is a long enough line"),                      // short stub grows
            row(base + 7000, "a long line that he cut back later"), row(base + 7010, "a long line that he"),        // cut back, left
        ]
        let sent = [row(base + 60, "see you at the station at 9"), row(base + 300, "see you at the station at 9")]  // sent twice
        let list = TypedList.build(sent: sent, drafts: drafts)
        let texts = list.map(\.text)
        check(texts.filter { $0 == "see you at the station at 9" }.count == 2, "both sends stay, as two rows: \(texts)")
        let first = list.first { $0.text == "see you at the station at 9" && $0.when.timeIntervalSince1970 == base + 60 }
        check(first?.drafts == ["see you at", "see you at the", "see you at the station"], "drafts fold into the sent line, oldest first")
        check(first?.title == "", "a sent line is not marked draft")
        check(!texts.contains("see you at") && !texts.contains("see you at the station"), "no draft row for a sent message")
        check(texts.filter { $0 == "the report is in the folder" }.count == 1, "a draft left twice shows once")
        check(list.first { $0.text == "the report is in the folder" }?.title == "draft", "a message never sent stays a draft")
        check(texts.contains("different app line"), "another app's line is its own row")
        check(texts.contains("much later about something else"), "a later unrelated line is its own row")
        check(texts.contains("ok, that one is a long enough line") && !texts.contains("ok"), "a short start folds into what it grew into")
        check(texts.contains("a long line that he cut back later") && !texts.contains("a long line that he"), "cut back: the longest version shows")
        check(list.count == 7, "seven messages, got \(list.count): \(texts)")
        check(zip(list, list.dropFirst()).allSatisfy { ($0.touched ?? $0.when) >= ($1.touched ?? $1.when) }, "newest first")
        // a two-letter draft never swallows a long line the user wrote after it… only the other way
        let stub = TypedList.build(sent: [], drafts: [row(base, "hello there my friend"), row(base + 10, "he")])
        check(stub.count == 2, "a long draft does not fold into a later two-letter stub")
        let later = TypedList.build(sent: [], drafts: [row(base, "the same words left in the box"), row(base + 3 * 3600, "the same words left in the box"),
                                                      row(base + 4 * 3600, "please send the contract by friday"), row(base + 4 * 3600 + 30, "please send the contract by monday")])
        check(later.count == 2, "same words hours apart fold; an edit near the end folds: \(later.map(\.text))")
        check(later.first?.text == "please send the contract by monday" && later.first?.drafts == ["please send the contract by friday"], "the edited version stands")
        // how long it took (window round two): from the first kept draft, or a row's first key ("t0")
        check(first?.started?.timeIntervalSince1970 == base, "started: the first draft of the message")
        let one = TypedList.build(sent: [["t": base + 50, "t0": base + 8, "text": "a line typed in one go here", "app": "Chat"]], drafts: [])
        check(one.first?.started?.timeIntervalSince1970 == base + 8, "started: the row's first key")
        check(TypedList.build(sent: [row(base, "a single line with no stamps")], drafts: []).first?.started == nil, "no stamps: nothing")
        // the estimate mark and the sent line (soft round): carried by the row shown
        let estRows = TypedList.build(sent: [["t": 5000.0, "text": "a sent line about the station", "app": "Mail"]],
                                      drafts: [["t": 9000.0, "text": "the end of a long draft he left", "app": "Notes", "est": true]])
        check(estRows.first { $0.app == "Notes" }?.est == true && estRows.first { $0.app == "Notes" }?.sent == false, "est draft")
        check(estRows.first { $0.app == "Mail" }?.sent == true && estRows.first { $0.app == "Mail" }?.est == false, "sent line")
        print("typed list: all checks passed")
    }
}
