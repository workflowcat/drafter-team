import Foundation
// swiftc -parse-as-library app/LookupQuery.swift tests/lookups.swift -o app/build/lookups-test && app/build/lookups-test

@main struct LookupTests {
    static func main() {
        var count = 0
        func check(_ ok: Bool, _ message: String) {
            precondition(ok, message); count += 1
        }
        for (input, kind, query, trigger) in [
            ("Please read ;docs project notes", "docs", "project notes", ";docs project notes"),
            ("Привіт 👋 ;meetings завтра", "meetings", "завтра", ";meetings завтра"),
            (";free 30 next week ", "free", "30 next week", ";free 30 next week "),
            (";links", "links", "", ";links"),
            ("line\n;accounts", "accounts", "", ";accounts")
        ] {
            let parsed = LookupQuery.parse(input)
            check(parsed?.kind == kind && parsed?.query == query && parsed?.trigger == trigger, "parse \(input)")
        }
        for input in [";docsfoo", "prefix;docs project", ";docs project\n", ";docs project\r", ";free 30\ntext", ";docs " + String(repeating: "x", count: 201)] {
            check(LookupQuery.parse(input) == nil, "reject \(input)")
        }
        func same(_ before: String = "Hi ;links cal", _ value: String = "Hi ;links cal", _ caret: Int = 13) -> Bool {
            LookupQuery.unchanged(before: before, value: value, caret: caret, expectedBefore: "Hi ;links cal", expectedValue: "Hi ;links cal", expectedCaret: 13, trigger: ";links cal")
        }
        check(same(), "accept unchanged snapshot")
        check(!same("Changed ;links cal"), "reject changed prefix")
        check(!same("Hi ;links cal", "Hi ;links cal changed"), "reject changed full text")
        check(!same("Hi ;links cal", "Hi ;links cal", 12), "reject moved caret")
        print("Lookup parsing and insertion guards passed: \(count) checks")
    }
}
