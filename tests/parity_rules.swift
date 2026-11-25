import Foundation

// swiftc -parse-as-library app/ParityRules.swift tests/parity_rules.swift -o app/build/parity-rules-test && app/build/parity-rules-test
// Parity round 2026-11-15: clipboard context, writing instructions, personal style, numbered alternatives. Made-up text only.

@main
struct ParityRulesTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

    static func main() {
        let now = Date(), C = ClipContext.self
        func pick(_ t: String?, ago: TimeInterval = 10, app: String = "com.example.notes", on: Bool = true, secret: Bool = false, before: String = "so the") -> (String?, ClipContext.Why?) {
            let r = C.pick(t, copiedAt: t == nil ? nil : now.addingTimeInterval(-ago), from: app, now: now, on: on, skip: ["com.example.skipped"], secret: secret, before: before)
            return (r.text, r.why)
        }
        check(pick("the zebra plan moved to Thursday").0 == "the zebra plan moved to Thursday", "a fresh plain copy goes in")
        check(pick("two\n\n lines").0 == "two lines", "white space folded")
        check(pick(String(repeating: "a ", count: 400)).0?.count == C.maxChars, "capped")
        check(pick("x", on: false).1 == .off, "setting off")
        check(pick(nil).1 == .nothing, "nothing copied")
        check(pick("zebra", ago: 121).1 == .stale, "over 2 minutes: left out")
        check(pick("zebra", ago: 119).0 == "zebra", "under 2 minutes: in")
        check(pick("zebra", app: "com.bitwarden.desktop").1 == .vault, "a password manager")
        check(pick("zebra", app: "com.example.skipped").1 == .vault, "a skipped app")
        check(pick("zebra", secret: true).1 == .secret, "QuickRules.isSecret said so")
        check(pick("UA21 3223 1300 0002 6007 2335 6600 1").1 == .secret, "an IBAN")
        check(pick("482913").1 == .secret, "a one-time code")
        check(pick("x9Fq2LmZ8pR4tW7yB1nC5vK3hJ6dS0aG").1 == .secret, "a long mixed token")
        check(pick("https://example.com/a/very/long/path/to/the/zebra-plan-2026").0 != nil, "a long link is fine")
        check(pick("zebra plan Q4", before: "here: zebra plan Q4 and").1 == .pasted, "already pasted in the field")

        let W = WritingNotes.self
        check(W.forApp("com.x", global: "", perApp: [:]) == "", "no notes: nothing")
        check(W.forApp("com.x", global: " short ", perApp: ["com.y": "warm"]) == "short", "the global one")
        check(W.forApp("com.y", global: "short", perApp: ["com.y": "in English"]) == "short; in English", "global then the app's")
        check(W.forApp("com.y", global: "", perApp: ["com.y": String(repeating: "z", count: 500)]).count == W.maxChars, "capped")

        check(Strength.clamp(100) == 100 && Strength.clamp(-5) == 0 && Strength.clamp(54) == 50 && Strength.clamp(130) == 100, "strength steps")

        let A = AltKeys.self
        func k(_ code: Int, option: Bool = true, shift: Bool = false, ghost: Bool = true, plain: Bool = true, on: Bool = true, count: Int = 3) -> Int? {
            A.pick(code: code, option: option, control: false, command: false, shift: shift, ghost: ghost, plain: plain, on: on, count: count)
        }
        check(k(18) == 0 && k(19) == 1 && k(20) == 2, "⌥1 ⌥2 ⌥3")
        check(k(20, count: 2) == nil, "no third idea: ⌥3 goes to the app")
        check(k(19, option: false) == nil, "a plain digit types")
        check(k(19, shift: true) == nil, "⌥⇧2 goes to the app")
        check(k(19, ghost: false) == nil, "no ghost")
        check(k(19, plain: false) == nil, "a chip or a fix")
        check(k(19, on: false) == nil, "setting off")
        check(k(21) == nil, "⌥4 not taken")
        check(A.hint(index: 0, count: 3, on: true) == "1/3" && A.hint(index: 1, count: 2, on: true) == "2/2", "hint")
        check(A.hint(index: 0, count: 1, on: true) == "" && A.hint(index: 0, count: 3, on: false) == "", "no hint")
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("parity rules: all passed")
    }
}
