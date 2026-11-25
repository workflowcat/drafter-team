import Foundation
// swiftc -parse-as-library app/Entry.swift app/PictureLookRules.swift app/ClipRules.swift app/ClipKindRules.swift tests/voice_history.swift -o app/build/voice_history-test && app/build/voice_history-test

@main struct VoiceHistoryChecks {
    static func main() {
        var count = 0
        func check(_ ok: @autoclosure () -> Bool, _ name: String) {
            precondition(ok(), name); count += 1
        }
        let old = Entry.voice(["id": "old", "text": "Hello", "t": 12.0])!
        check(old.text == "Hello" && old.raw.isEmpty && !old.incomplete, "Old history rows still load")
        check(old.id == "old" && old.when.timeIntervalSince1970 == 12, "Identity and date remain stable")
        let cleaned = Entry.voice(["text": "Зустріч о третій.", "raw": "Зустріч о другій, ні, тобто о третій.", "app": "Mail"])!
        check(cleaned.matches("другій MAIL"), "Search finds removed Ukrainian wording and app together")
        check(cleaned.matches("третій"), "Search finds final wording")
        check(!cleaned.matches("missing"), "Search rejects an unrelated word")
        check(cleaned.originalLabel == "Before cleanup", "Original is not labelled as a confidence score")
        let equal = Entry.voice(["text": "Same", "raw": "Same"])!
        check(equal.raw.isEmpty, "Identical originals are not shown twice")
        let timeout = Entry.voice(["text": "", "raw": "Partial words", "outcome": "timeout"])!
        check(timeout.text.isEmpty && timeout.incomplete, "A preview is never promoted to final text")
        check(timeout.summary == "Partial words" && timeout.originalLabel == "Last live preview", "Recovery identifies the partial preview")
        check(timeout.matches("incomplete partial"), "Recovery is searchable by status and content")
        check(timeout.notice.contains("timed out"), "Timeout reason is visible")
        let interrupted = Entry.voice(["raw": "Draft", "outcome": "incomplete"])!
        check(interrupted.notice.contains("No final transcript"), "Empty response is distinguished from timeout")
        let audio = Entry.voice(["text": "", "audio": "/synthetic.wav"], audioExists: { _ in true })!
        check(audio.summary == "Audio only · no transcript", "Audio-only history is visible")
        check(audio.audioOnly && !timeout.audioOnly, "Filtering silent clips never hides incomplete recoveries")
        check(Entry.voice(["text": "", "audio": "/expired.wav"], audioExists: { _ in false }) == nil, "Expired empty clips do not create unusable rows")
        check(Entry.voice(["text": "Kept text", "audio": "/expired.wav"], audioExists: { _ in false }) != nil, "Text outlives audio retention")
        check(Entry.voice(["raw": "Kept original", "audio": "/expired.wav"], audioExists: { _ in false }) != nil, "Original wording outlives audio retention")
        check(Entry.voice([:]) == nil, "Empty malformed rows are skipped")
        check(cleaned.matches(" \n\t "), "Whitespace query matches all records")
        print("PASS: \(count) voice history checks")
    }
}
