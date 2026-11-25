// swiftc -parse-as-library app/RecordPaceRules.swift tests/record_pace_rules.swift -o app/build/record-pace-test && app/build/record-pace-test
// How often a recording's live values reach the screen, and when the journal is built again while one records.
import Foundation

@main
struct RecordPaceTest {
    static var failed = 0, checks = 0
    static func check(_ ok: Bool, _ what: String) { checks += 1; if !ok { failed += 1; print("FAIL", what) } }
    typealias D = RecordPaceRules.Doc

    static func main() {
        check(RecordPaceRules.levelInterval <= 1.0 / 15 + 1e-9, "levels at most 15 fps")
        check(RecordPaceRules.wordsInterval >= 0.25, "words at most 4 times a second")
        check(!RecordPaceRules.levelMoved(0.40, 0.41), "a 1% step is not drawn")
        check(RecordPaceRules.levelMoved(0.40, 0.45), "a 5% step is drawn")
        check(RecordPaceRules.levelMoved(0.01, 0), "falling to silence is drawn")
        check(!RecordPaceRules.levelMoved(0, 0), "silence to silence is not drawn")
        check(!RecordPaceRules.wordsDue(changed: false, since: 5), "unchanged words are not sent")
        check(!RecordPaceRules.wordsDue(changed: true, since: 0.1), "changed words wait for 0.25 s")
        check(RecordPaceRules.wordsDue(changed: true, since: 0.3), "changed words after 0.25 s are sent")

        let ids = ["c", "b", "a"]
        let calm = [D(id: "c", live: true, same: true), D(id: "b", live: false, same: true), D(id: "a", live: false, same: true)]
        check(!RecordPaceRules.rebuild(docs: calm, oldIds: ids, sinceLive: 100, forced: false), "nothing changed: no rebuild")
        check(RecordPaceRules.rebuild(docs: calm, oldIds: ids, sinceLive: 0, forced: true), "forced: rebuild")
        let grew = [D(id: "c", live: true, same: false), D(id: "b", live: false, same: true), D(id: "a", live: false, same: true)]
        check(!RecordPaceRules.rebuild(docs: grew, oldIds: ids, sinceLive: 3, forced: false), "only the live one grew, 3 s after: no rebuild")
        check(!RecordPaceRules.rebuild(docs: grew, oldIds: ids, sinceLive: 29.9, forced: false), "only the live one grew, 29.9 s after: no rebuild")
        check(RecordPaceRules.rebuild(docs: grew, oldIds: ids, sinceLive: 30, forced: false), "only the live one grew, 30 s after: rebuild")
        let done = [D(id: "c", live: true, same: false), D(id: "b", live: false, same: false), D(id: "a", live: false, same: true)]
        check(RecordPaceRules.rebuild(docs: done, oldIds: ids, sinceLive: 1, forced: false), "a finished one changed: rebuild at once")
        check(RecordPaceRules.rebuild(docs: calm, oldIds: ["b", "a"], sinceLive: 1, forced: false), "a new recording: rebuild at once")
        check(RecordPaceRules.rebuild(docs: Array(calm.dropFirst()), oldIds: ids, sinceLive: 1, forced: false), "one gone: rebuild at once")
        let ended = [D(id: "c", live: false, same: false), D(id: "b", live: false, same: true), D(id: "a", live: false, same: true)]
        check(RecordPaceRules.rebuild(docs: ended, oldIds: ids, sinceLive: 1, forced: false), "the recording ended (no longer live): rebuild at once")
        print(failed == 0 ? "record pace: \(checks) checks pass" : "\(failed) of \(checks) failed")
        if failed > 0 { exit(1) }
    }
}
