// swiftc -parse-as-library app/VoiceClaudeRules.swift tests/voice_claude_rules.swift -o app/build/voice-claude-test && app/build/voice-claude-test
// Made-up lines only.
import Foundation

@main struct VoiceClaudeTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL:", what) } }

    static func main() {
        typealias R = VoiceClaudeRules
        // who asks
        check(R.wants(on: true, level: "clean", live: false, segment: false, queued: 0), "clean asks")
        check(R.wants(on: true, level: "polished", live: false, segment: false, queued: 0), "polished asks")
        check(!R.wants(on: true, level: "raw", live: false, segment: false, queued: 0), "raw never goes to Claude")
        check(!R.wants(on: false, level: "clean", live: false, segment: false, queued: 0), "off by the switch")
        check(!R.wants(on: true, level: "clean", live: true, segment: false, queued: 0), "live typing: no")
        check(!R.wants(on: true, level: "clean", live: false, segment: true, queued: 0), "a segment: no")
        check(!R.wants(on: true, level: "clean", live: false, segment: false, queued: 1), "another take waits: no")

        // swap only while untouched
        let put = "send the deck to marta "
        check(R.canSwap(revisionAt: 7, revisionNow: 7, before: "Hi. " + put, put: put), "untouched: swap")
        check(!R.canSwap(revisionAt: 7, revisionNow: 8, before: "Hi. " + put, put: put), "he typed: no swap")
        check(!R.canSwap(revisionAt: 7, revisionNow: 7, before: "Hi. send the deck to ", put: put), "field changed: no swap")
        check(!R.canSwap(revisionAt: 7, revisionNow: 7, before: nil, put: put), "field unreadable: no swap")
        check(R.canSwap(revisionAt: 7, revisionNow: 7, before: "send the deck to\u{A0}marta ", put: put), "a no-break space reads as a space")

        // the answer
        check(R.answer("  Send the deck to Marta.\n", put: put) == "Send the deck to Marta.", "trimmed answer")
        check(R.answer("send the deck to marta", put: put) == nil, "same text: nothing to do")
        check(R.answer("", put: put) == nil && R.answer(nil, put: put) == nil, "empty: nothing")

        // what changed
        let ch = R.changes(old: "send the deck to marta by friday", new: "Send the deck to Marta by Friday.")
        check(ch.count == 3, "3 changed runs, got \(ch.count)")
        check(ch.first! == ("send", "Send"), "first run")
        check(ch.last! == ("friday", "Friday."), "last run")
        check(R.changes(old: "a b c", new: "a b c").isEmpty, "no change")
        let add = R.changes(old: "call ana", new: "call Ana today")
        check(add.count == 1 && add[0] == ("ana", "Ana today"), "a run with an added word: \(add)")
        let drop = R.changes(old: "so um send it", new: "so send it")
        check(drop.count == 1 && drop[0] == ("um", ""), "a dropped filler")
        check(R.note(drop) == "Claude: − um · ⌫ puts it back", R.note(drop))
        let many = R.changes(old: "a b c d e f g", new: "A b C d E f G")
        check(R.note(many).hasSuffix("· +1 · ⌫ puts it back"), R.note(many))

        if failed == 0 { print("voice claude rules: all checks passed") } else { print("\(failed) failed"); exit(1) }
    }
}
