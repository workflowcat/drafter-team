// swiftc -parse-as-library app/PutCheckRules.swift tests/put_check_rules.swift -o app/build/put-check-rules-test && app/build/put-check-rules-test
// The check after a voice paste (app/PutCheckRules.swift): what counts as landed, what is a real miss, the per-app tally.
// Made-up lines only.
import Foundation

@main
struct PutCheckChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        typealias R = PutCheckRules
        let text = "Please move the planning call to Thursday, and send the notes after it"

        check(R.squash("a\u{A0}b \n c\u{200B}d\u{FFFC}") == "abcd", "whitespace, NBSP, zero width, object marks go")
        check(R.squash("it\u{2019}s \u{201C}ok\u{201D} \u{2014} yes") == "it's\"ok\"-yes", "curly quotes and dashes fold")

        // seen: the field holds the text, however the editor spaced or broke it
        check(R.verdict(text: text, before: "", after: text + " ", web: true) == .seen, "plain")
        check(R.verdict(text: text, before: "", after: "Please move the planning call to Thursday,\nand send the notes\u{A0}after it", web: true) == .seen,
              "line break and NBSP in the field")
        check(R.verdict(text: "it's done", before: "", after: "it\u{2019}s done", web: false) == .seen, "smart quote in the field")
        check(R.verdict(text: "  ", before: "x", after: "x", web: false) == .seen, "nothing to put: nothing to miss")

        // grew: the field changed by about the text (an editor that rewrote its end)
        check(R.verdict(text: text, before: "Hi.", after: "Hi." + String(repeating: "z", count: 60), web: true) == .grew, "grew by the text")
        check(R.verdict(text: text, before: "Hi.", after: "Hi. zz", web: true) == .miss, "grew by a little: not the text")

        // unreadable: no field, a field that reads empty (Electron, or the user already sent it)
        check(R.verdict(text: text, before: "", after: nil, web: false) == .unreadable, "no field read")
        check(R.verdict(text: text, before: "", after: "", web: true) == .unreadable, "Electron reads empty")
        check(R.verdict(text: text, before: "", after: "", web: false) == .unreadable, "empty after: sent already, or not readable")

        // stale: an Electron tree that has not caught up reads the value from before the paste
        check(R.verdict(text: text, before: "Draft so far", after: "Draft so far", web: true) == .stale, "Electron, unchanged: stale")
        check(R.verdict(text: text, before: nil, after: "Draft so far", web: true) == .miss, "no read before: cannot call it stale")
        check(R.verdict(text: text, before: "Draft so far", after: "Draft so far", web: false) == .miss, "native, unchanged: miss")
        check(R.verdict(text: text, before: "Draft so far", after: "Another line", web: true) == .miss, "changed without the text: miss")

        check(R.needsSecondCheck(.miss) && !R.needsSecondCheck(.stale) && !R.needsSecondCheck(.seen), "second check on a miss only")
        check(!R.landed(.miss) && R.landed(.stale) && R.landed(.unreadable) && R.landed(.grew), "landed")

        // the pill: none after a paste went out, whatever the read-back; on a real miss the reason and ⌘V
        check(R.outcome(notPutWhy: nil) == .quiet, "paste went out: no pill")
        check(R.outcome(notPutWhy: "") == .quiet, "no reason: no pill")
        check(R.outcome(notPutWhy: "No text field here") == .clipboard("No text field here · ⌘V to paste"), "no field: clipboard")
        check(R.outcome(notPutWhy: "Secure input is on here") == .clipboard("Secure input is on here · ⌘V to paste"), "secure input")
        check(R.outcome(notPutWhy: "Drafter is off in this app") == .clipboard("Drafter is off in this app · ⌘V to paste"), "skipped app")
        check(R.unsureLine(app: "com.example.chat") == "voice flow: put in, read-back unsure (com.example.chat)", "unsure line")
        check(R.unsureLine(app: "") == "voice flow: put in, read-back unsure (?)", "unsure line, no app")

        var t = R.Tally()
        _ = R.count(&t, app: "com.example.chat", .seen)
        _ = R.count(&t, app: "com.example.chat", .stale)
        _ = R.count(&t, app: "com.example.other", .miss)
        let line = R.count(&t, app: "com.example.chat", .miss)
        check(line == "voice put: com.example.chat seen 1 grew 0 unreadable 0 stale 1 miss 1 (33% miss)", "tally line: \(line)")
        check(R.count(&t, app: "", .seen).hasPrefix("voice put: ? seen 1"), "no bundle id")

        let d = R.detail(text: text, before: "ab", after: "ab")
        check(d.hasPrefix("text 58 before 2 after 2") && d.hasSuffix("same 1") && !d.contains("Thursday"), "detail is numbers only: \(d)")
        check(R.detail(text: text, before: nil, after: nil).contains("before - after -"), "detail with no reads")

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("put check rules: ok")
    }
}
