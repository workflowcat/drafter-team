// How often a recording's live values reach the screen (17 November 2026, Andrii mid-call: "recording feels a little
// heavy"; measured: Drafter at 116% CPU, SwiftUI rebuilding the whole recording window for each level change, and the
// journal rebuilt every 3 s because the live recording's length changed). Pure: no AppKit. Used by RecordLive
// (app/RecordWindow.swift) and WindowModel.applyDocs (app/Recordings.swift). Test: tests/record_pace_rules.swift.
import Foundation

enum RecordPaceRules {
    /// The level meters: at most 15 frames a second, on one timer, only while the window shows.
    static let levelInterval = 1.0 / 15
    /// The live words: at most 4 times a second (the recording timer brings them once a second today).
    static let wordsInterval = 0.25
    /// A level moves on screen only when it changed by more than this (a 5 px meter shows no smaller step).
    static let levelStep: Double = 0.02
    /// With only a live recording changed, the journal is built again at most this often, in seconds.
    static let liveRebuildEvery: Double = 30

    /// A new meter value worth drawing.
    static func levelMoved(_ old: Double, _ new: Double) -> Bool { abs(new - old) > levelStep || (new == 0 && old != 0) }

    /// The live words go to the screen: they changed and the last update is at least `wordsInterval` old.
    static func wordsDue(changed: Bool, since last: Double) -> Bool { changed && last >= wordsInterval }

    /// One recording as `applyDocs` compares it: its folder and whether it is still recording.
    struct Doc: Equatable { let id: String; let live: Bool; let same: Bool }

    /// Should the journal be built again? Any change outside live recordings: yes. Only live recordings changed (their
    /// length and words grow each read): at most every `liveRebuildEvery` seconds. `docs`: the new list, `same`
    /// telling whether that recording equals its old version; `oldIds`: the previous list's folders.
    static func rebuild(docs: [Doc], oldIds: [String], sinceLive: Double, forced: Bool) -> Bool {
        if forced { return true }
        if docs.map(\.id) != oldIds { return true }                       // one came, went or moved
        let changed = docs.filter { !$0.same }
        if changed.isEmpty { return false }
        if changed.contains(where: { !$0.live }) { return true }         // a finished recording changed
        return sinceLive >= liveRebuildEvery
    }
}
