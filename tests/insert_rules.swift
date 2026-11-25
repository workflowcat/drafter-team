// swiftc -parse-as-library app/InsertRules.swift app/PutCheckRules.swift tests/insert_rules.swift -o app/build/insert-rules-test && app/build/insert-rules-test
// Insert audit (23 November 2026, docs/inserts.md): an AX write read back, apps nothing goes into, a put-in in steps,
// a test field's Tab, Shift Shift on a selection. Made-up lines only.
import Foundation

@main
struct InsertRulesTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL", what) } }

    static func main() {
        // 1. AX write read back: a field the app reformatted must not get a paste on top (the double insert)
        let old = "Lunch at noon", before = "Lunch at noon"
        check(InsertRules.afterAXWrite(old: old, caret: 13, before: before, text: " works", now: "Lunch at noon works") == .landed, "exact write lands")
        check(InsertRules.afterAXWrite(old: old, caret: 13, before: before, text: " it's fine", now: "Lunch at noon it’s fine") == .landed, "same length, curly quote: landed")
        check(InsertRules.afterAXWrite(old: old, caret: 13, before: before, text: " -- ok", now: "Lunch at noon — ok") == .changed, "smart dash: changed")
        check(!InsertRules.pasteAfterAX(.changed), "changed field: no second paste")
        check(InsertRules.afterAXWrite(old: old, caret: 13, before: before, text: " works", now: old) == .unchanged, "no trace: unchanged")
        check(InsertRules.pasteAfterAX(.unchanged), "unchanged: paste")
        check(InsertRules.afterAXWrite(old: old, caret: 13, before: before, text: " works", now: nil) == .unreadable, "nil: unreadable")
        check(InsertRules.pasteAfterAX(.unreadable), "unreadable: paste as before")
        check(!InsertRules.pasteAfterAX(.landed), "landed: no paste")
        check(InsertRules.afterAXWrite(old: "", caret: 0, before: "", text: "Hi", now: "Hi") == .landed, "empty field")

        // 1b. Focus.replace: a reformatted replacement went in; only an unchanged field gets the paste
        check(InsertRules.replacedByAX(old: "Meet at the cafe", new: "café", now: "Meet at the café"), "replace exact")
        check(InsertRules.replacedByAX(old: "He said hi", new: "\"ok\"", now: "He said “ok”"), "replace reformatted: no paste")
        check(!InsertRules.replacedByAX(old: "He said hi", new: "ok", now: "He said hi"), "unchanged: paste")
        check(!InsertRules.replacedByAX(old: "He said hi", new: "ok", now: nil), "unreadable: paste as before")

        // 2. apps nothing goes into, whatever the skip list says
        for b in ["com.1password.1password", "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.loginwindow", "com.apple.SecurityAgent"] {
            check(InsertRules.neverInto(b), "never: \(b)")
        }
        for b in ["com.apple.TextEdit", "com.apple.Terminal", "com.google.Chrome", "com.apple.Safari"] { check(!InsertRules.neverInto(b), "allowed: \(b)") }
        check(!InsertRules.neverInto(nil), "no bundle id: not on the list")

        // 3. a put-in in steps stops when the keys moved, under secure input, or when Drafter holds them
        check(InsertRules.stepMayGo(startPid: 40, keyPid: 40, ownPid: 9, secure: false), "same app: go")
        check(!InsertRules.stepMayGo(startPid: 40, keyPid: 41, ownPid: 9, secure: false), "another app: stop")
        check(!InsertRules.stepMayGo(startPid: 40, keyPid: nil, ownPid: 9, secure: false), "no app: stop")
        check(!InsertRules.stepMayGo(startPid: 40, keyPid: 40, ownPid: 9, secure: true), "secure input: stop")
        check(!InsertRules.stepMayGo(startPid: 9, keyPid: 9, ownPid: 9, secure: false), "Drafter itself: stop")
        check(!InsertRules.stepMayGo(startPid: nil, keyPid: 40, ownPid: 9, secure: false), "unknown start: stop")

        // 4. a Tab in a test field leaves no /accept row
        check(!InsertRules.logAccept(field: "⟦drafter-test⟧ The parcel comes on"), "test field: no row")
        check(InsertRules.logAccept(field: "The parcel comes on"), "plain field: row")

        // 5. Shift Shift: a selection is converted (spot gives none for a selection)
        check(InsertRules.layoutWay(spot: false, why: "selection", selection: true) == .selection, "selection")
        check(InsertRules.layoutWay(spot: true, why: "ok", selection: false) == .lastWord, "last word")
        for why in ["password field", "secure input", "skipped app", "own app", "no focus"] {
            check(InsertRules.layoutWay(spot: false, why: why, selection: true) == .keyboardOnly, "guarded: \(why)")
        }
        check(InsertRules.layoutWay(spot: false, why: "selection", selection: false) == .keyboardOnly, "selection unreadable")

        // 6. the live check's own guards and verdicts
        let m = "⟦drafter-test⟧ "
        check(InsertCheckRules.mayAct(front: "com.apple.TextEdit", expected: "com.apple.TextEdit", field: m + "Pick up the keys"), "TextEdit with marker")
        check(!InsertCheckRules.mayAct(front: "com.apple.TextEdit", expected: "com.apple.TextEdit", field: "Pick up the keys"), "no marker: stop")
        check(!InsertCheckRules.mayAct(front: "com.apple.Notes", expected: "com.apple.Notes", field: m), "Notes never")
        check(!InsertCheckRules.mayAct(front: "com.google.Chrome", expected: "com.apple.Safari", field: m), "another app in front: stop")
        check(!InsertCheckRules.mayAct(front: "com.apple.Safari", expected: "com.apple.Safari", field: nil), "no field: stop")
        check(InsertCheckRules.dirOK("/var/tmp/x/drafter-insert-check-ab12", tmp: "/var/tmp/x"), "temp folder ok")
        check(!InsertCheckRules.dirOK("/opt/drafter/data", tmp: "/var/tmp/x"), "data folder refused")
        check(!InsertCheckRules.dirOK("/var/tmp/x/../y/drafter-insert-check-1", tmp: "/var/tmp/x"), "dot-dot refused")
        check(InsertCheckRules.verdict(before: m, after: m + "The van leaves at six", line: "The van leaves at six") == "ok", "verdict ok")
        check(InsertCheckRules.verdict(before: m, after: m, line: "The van leaves at six") == "nothing", "verdict nothing")
        check(InsertCheckRules.verdict(before: m, after: m + "The bus", line: "The van leaves at six") == "wrong text", "verdict wrong")
        check(InsertCheckRules.verdict(before: m, after: m + "Hi there Hi there", line: "Hi there").hasPrefix("ok, but"), "verdict twice")
        check(InsertCheckRules.verdict(before: m, after: m + "\u{FFFC}", line: "", changed: true) == "ok", "picture changed")

        print(failed == 0 ? "insert rules: all passed" : "insert rules: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
