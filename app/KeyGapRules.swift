// Key gaps (2026-11-14): how long he waits between two typed letters in the same field, as a histogram only, for
// bench/models/twotier.py (a bigger model after a pause only helps if the pause is long enough; data/app.log had no
// real gaps). Keys.handle calls `key` once per typed key; Keys.ask calls `field` with the kind of the field it read
// (nil: skipped app, password field, secure input, no app). Once a minute while he typed, and when the app kind
// changes, one line goes out:
//   keygap <ai|chat|mail|other> lt60 N lt90 N lt120 N lt150 N lt200 N lt300 N lt500 N lt1000 N pause N ghost N
// ltX = gaps under X ms (and at or over the bucket before), pause = gaps of 1000 ms or more, ghost = gaps (pauses
// included) that ended while a ghost was on screen. Numbers only: never a key, a letter or the app's name.
// Pure (no AppKit), no allocation per key; tests/key_gap_rules.swift.
import Foundation

struct KeyGaps {
    /// Upper edges in ms; a gap at or over the last edge is a pause.
    static let edges: [UInt64] = [60, 90, 120, 150, 200, 300, 500, 1000]
    static let window: UInt64 = 60_000_000_000          // ns: one line a minute at most while he types
    static let kinds = ["ai", "chat", "mail", "other"]

    // the histogram of the open window (fixed size, mutated in place)
    private(set) var counts = [Int](repeating: 0, count: 8)
    private(set) var pauses = 0
    private(set) var ghost = 0
    private var windowKind = -1, windowStart: UInt64 = 0

    // the field: the kind Keys.ask read (-1 none or not allowed) and the key count it read it at
    private var fieldKind = -1, fieldRev = -1
    // the key before: when it came, its key count, the field token (Keys.fieldGen) and the key count its run began at
    private var prevAt: UInt64 = 0, prevRev = -2, prevField = -1, runStart = -1
    /// The gap before the last key in ms, -1 when unknown (first key of a run, another field, a non-letter, secure
    /// input). Cadence round: the engine routes a key to the fast model when this is short (engine/cadence.py).
    private(set) var lastMs = -1

    init() {}

    var total: Int { counts.reduce(pauses, +) }

    /// Keys.ask read the field at key count `rev`: its kind ("ai", "chat", "mail", "other") or nil when nothing may be
    /// counted there. A new kind closes the open window. Returns the line to log, if any.
    mutating func field(_ kind: String?, rev: Int) -> String? {
        let k = kind.flatMap { KeyGaps.kinds.firstIndex(of: $0) } ?? -1
        fieldKind = k; fieldRev = rev
        if k < 0 { prevRev = -2; return nil }            // a gap across a field that may not be counted is never counted
        return k != windowKind && total > 0 ? flush() : nil
    }

    /// One keyDown that reached typing: `at` the event's time (ns since boot), `rev` Keys.keyRevision, `field`
    /// Keys.fieldGen, `unit` the first UTF-16 unit it typed (nil: none), `secure` secure input on, `ghost` a ghost was
    /// on screen when it came. Returns the line to log when a minute has passed.
    mutating func key(at: UInt64, rev: Int, field: Int, unit: UInt16?, secure: Bool, ghost shown: Bool) -> String? {
        guard !secure, let u = unit, KeyGaps.isLetter(u) else { prevRev = -2; lastMs = -1; return nil }
        let chained = rev == prevRev + 1 && field == prevField && at >= prevAt
        lastMs = chained ? Int(min((at - prevAt) / 1_000_000, 60_000)) : -1
        if !chained { runStart = rev }
        defer { prevAt = at; prevRev = rev; prevField = field }
        // counted only once Keys.ask confirmed this run's field (a Tab can move the caret into another field)
        guard chained, fieldKind >= 0, fieldRev >= runStart else { return nil }
        var out: String? = nil
        if windowKind != fieldKind || at &- windowStart >= KeyGaps.window {
            if total > 0 { out = flush() }
            windowKind = fieldKind; windowStart = at
        }
        let ms = (at - prevAt) / 1_000_000
        if let i = KeyGaps.edges.firstIndex(where: { ms < $0 }) { counts[i] += 1 } else { pauses += 1 }
        if shown { ghost += 1 }
        return out
    }

    /// The open window as one log line; the window starts empty again.
    mutating func flush() -> String? {
        guard total > 0, windowKind >= 0 else { return nil }
        var s = "keygap " + KeyGaps.kinds[windowKind]
        for (i, e) in KeyGaps.edges.enumerated() { s += " lt\(e) \(counts[i])" }
        s += " pause \(pauses) ghost \(ghost)"
        for i in counts.indices { counts[i] = 0 }
        pauses = 0; ghost = 0
        return s
    }

    /// A typed character: not a control key (Return, Backspace, Tab, Esc), not Delete, not an arrow or function key
    /// (macOS gives those private-use units F700-F8FF).
    static func isLetter(_ u: UInt16) -> Bool { u >= 0x20 && u != 0x7F && !(0xF700...0xF8FF).contains(u) }
}
