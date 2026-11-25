// The voice language pin (17 November 2026, research item 4, docs/rounds/2026-11-17-voice-pin.md). A Left Option
// tap during a take pins the recogniser to Ukrainian or English for the rest of that take (Enter pieces included);
// the strip shows "UK" or "EN". Never a translation: the engine only tells Whisper which language it hears
// (engine/voice_language.py pinned_plan). The next take starts unpinned. Pure: tests/voice_pin_rules.swift.
import Foundation

enum VoicePinRules {
    static let pins = ["uk", "en"]
    /// A tap: Left Option down and up within this time, no key and no other modifier in between.
    static let tapMax = 0.35

    /// The language of a text, as the engine counts it (voice_language.fast_language): 30% or more of the words
    /// Cyrillic is Ukrainian; English has no Cyrillic word; anything else (mixed, digits only, empty) is unknown.
    static func language(_ text: String) -> String? {
        var words = 0, cyr = 0, latinOnly = true
        for w in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || "'’ʼ".contains($0)) }) {
            var c = false, l = false, other = false
            for u in w.unicodeScalars where CharacterSet.letters.contains(u) && u != "ʼ" {
                switch u.value {
                case 0x0400...0x052F: c = true
                case 0x0041...0x024F: l = true
                default: other = true
                }
            }
            guard c || l || other else { continue }   // numbers alone do not vote
            words += 1
            if c { cyr += 1 }
            if c || other || !l { latinOnly = false }
        }
        if words > 0, cyr * 10 >= words * 3 { return "uk" }
        if words > 0, cyr == 0, latinOnly { return "en" }
        return nil
    }

    /// The pin after a tap. Unpinned: the language the words so far are not in (heard as English -> Ukrainian and
    /// back; mixed or nothing yet -> Ukrainian, his own). Pinned: the other one.
    static func next(pin: String?, heard: String) -> String {
        if let pin, pins.contains(pin) { return pin == "uk" ? "en" : "uk" }
        return language(heard) == "uk" ? "en" : "uk"
    }

    /// The strip's mark: "UK", "EN", or nothing when unpinned.
    static func mark(_ pin: String?) -> String { pin.map { pins.contains($0) ? $0.uppercased() : "" } ?? "" }

    /// A clean Left Option tap: short, no key typed while it was down (an ⌥ character is his), no ⌘ ⌃ ⇧ with it.
    static func tap(seconds: Double, keyBetween: Bool, otherModifiers: Bool) -> Bool {
        seconds >= 0 && seconds <= tapMax && !keyBetween && !otherModifiers
    }

    /// Left and right Option in an event's raw flags (NX_DEVICELALTKEYMASK 0x20, NX_DEVICERALTKEYMASK 0x40). A
    /// keyboard that sets neither device bit counts the Option bit as the right one (the voice key as before).
    static func options(raw: UInt64) -> (left: Bool, right: Bool) {
        let alt = raw & 0x80000 != 0, l = raw & 0x20 != 0, r = raw & 0x40 != 0
        return (l, r || (alt && !l && !r))
    }
}
