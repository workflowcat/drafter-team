// swiftc -parse-as-library app/VoicePinRules.swift tests/voice_pin_rules.swift -o app/build/voice-pin-rules-test && app/build/voice-pin-rules-test
// The voice language pin (app/VoicePinRules.swift): the language count agrees with the engine's, a tap flips the pin,
// the mark, and what counts as a clean Left Option tap. Made-up lines only.
import Foundation

@main
struct VoicePinChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        // the same table as tests/test_voice_language.py test_language_majority_and_unknown
        for (text, want) in [("Новий проєкт готовий до review", "uk"), ("Please review the проєкт tomorrow", nil),
                             ("добре", "uk"), ("café déjà", "en"), ("сімʼя", "uk"), ("так", "uk"), ("OK", "en"),
                             ("123!?", nil), ("тест test", "uk"), ("文字文字", nil), ("", nil)] as [(String, String?)] {
            check(VoicePinRules.language(text) == want, "language «\(text)»: \(VoicePinRules.language(text) ?? "nil") want \(want ?? "nil")")
        }

        // a tap: unpinned, the other language than heard; mixed or nothing yet, Ukrainian; pinned, the other one
        check(VoicePinRules.next(pin: nil, heard: "Please check the report") == "uk", "heard English -> UK")
        check(VoicePinRules.next(pin: nil, heard: "Новий проєкт готовий") == "en", "heard Ukrainian -> EN")
        check(VoicePinRules.next(pin: nil, heard: "Please review the проєкт tomorrow") == "uk", "mixed -> UK")
        check(VoicePinRules.next(pin: nil, heard: "") == "uk", "nothing yet -> UK")
        check(VoicePinRules.next(pin: "uk", heard: "Новий проєкт") == "en", "UK -> EN")
        check(VoicePinRules.next(pin: "en", heard: "Please check") == "uk", "EN -> UK")
        check(VoicePinRules.next(pin: "de", heard: "Новий проєкт") == "en", "an unknown pin counts as none")

        check(VoicePinRules.mark("uk") == "UK" && VoicePinRules.mark("en") == "EN", "marks")
        check(VoicePinRules.mark(nil) == "" && VoicePinRules.mark("de") == "", "no mark unpinned")

        check(VoicePinRules.tap(seconds: 0.12, keyBetween: false, otherModifiers: false), "a short tap")
        check(!VoicePinRules.tap(seconds: 0.6, keyBetween: false, otherModifiers: false), "held too long: not a tap")
        check(!VoicePinRules.tap(seconds: 0.1, keyBetween: true, otherModifiers: false), "⌥ + a key: his character, not a tap")
        check(!VoicePinRules.tap(seconds: 0.1, keyBetween: false, otherModifiers: true), "⌘⌥ or ⇧⌥: not a tap")
        check(!VoicePinRules.tap(seconds: -1, keyBetween: false, otherModifiers: false), "no down seen")

        // raw flags: left 0x20, right 0x40, the Option bit 0x80000
        let alt: UInt64 = 0x80000
        check(VoicePinRules.options(raw: alt | 0x20) == (true, false), "left only")
        check(VoicePinRules.options(raw: alt | 0x40) == (false, true), "right only")
        check(VoicePinRules.options(raw: alt | 0x60) == (true, true), "both")
        check(VoicePinRules.options(raw: alt) == (false, true), "no device bits: the Option bit is the voice key")
        check(VoicePinRules.options(raw: 0) == (false, false), "none")

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("voice pin rules: ok")
    }
}
