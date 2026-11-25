import Foundation

// swiftc -parse-as-library app/LogStats.swift tests/log_stats.swift -o app/build/log-stats-test && app/build/log-stats-test
// Made-up log lines in the shapes the app writes.
@main
struct LogStatsChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    static func main() {
        let lines = [
            "2026-11-01T10:00:00Z shown com.example.chat 80ms engine 40ms gate 0.55",          // before the window
            "2026-11-10T10:00:00Z shown com.example.chat 80ms engine 40ms gate 0.55",
            "2026-11-10T10:00:01Z shown com.example.chat 70ms engine 30ms words",
            "2026-11-10T10:00:02Z ghost com.example.chat gate len 12 word 5 taken 5 typed 0",
            "2026-11-10T10:00:03Z ghost com.example.chat words len 6 word 6 taken 0 typed 6",   // typed through: not taken
            "2026-11-10T10:00:04Z shown com.example.ai 1200ms engine 900ms claude early",
            "2026-11-10T10:00:05Z ghost com.example.ai claude len 20 word 4 taken 4 typed 0",
            "2026-11-10T10:00:06Z shown com.example.chat 5ms fix typo",
            "2026-11-10T10:00:07Z fix taken typo 5 -> 5 chars",
            "2026-11-10T10:00:08Z fix mark: typo, native",
            "2026-11-10T10:00:09Z autocorrect typo 4 -> 4 chars",
            "2026-11-10T10:00:10Z autocorrect typo 5 -> 5 chars",
            "2026-11-10T10:00:11Z autocorrect taken back (typo)",
            "2026-11-10T10:00:12Z autocorrect layout 6 -> 6 chars",
            "2026-11-10T10:00:12Z fix offer space typo taken 800ms",                // offer mode (Argon 21)
            "2026-11-10T10:00:12Z fix offer space layout uk expired 6000ms",
            "2026-11-10T10:00:12Z autocorrect taken back (layout uk) 340ms after tab",
            "2026-11-10T10:00:12Z fix offer word typo typed 200ms",                 // mid-word: counted by its shown line
            "2026-11-10T10:00:13Z proofread com.example.chat 1400ms engine 1200ms 2 fixes",
            "2026-11-10T10:00:14Z proofread com.example.chat 1400ms engine 1200ms 0 fixes",
            "2026-11-10T10:00:15Z proofread applied 2 of 2 (range)",
            "2026-11-10T10:00:16Z proofread: word not found",
            "2026-11-10T10:00:17Z translate com.example.chat en 1500ms engine 1300ms 42 chars",
            "2026-11-10T10:00:18Z translate com.example.chat en 1500ms engine 1300ms none",
            "2026-11-10T10:00:19Z translate applied en, 40 → 42 chars",
            "2026-11-10T10:00:20Z translate taken back",
            "2026-11-10T10:00:21Z facts com.example.chat 2000ms engine 1800ms answer",
            "2026-11-10T10:00:22Z facts com.example.chat 2000ms engine 1800ms none",
            "2026-11-10T10:00:23Z facts taken",
            "2026-11-10T10:00:24Z next message reply shown in 4000 ms",
            "2026-11-10T10:00:25Z next message for the assistant drafted in 3000 ms (cache)",
            "2026-11-10T10:00:26Z next message taken",
            "2026-11-10T10:00:27Z rework: open, 40 chars in com.example.chat",
            "2026-11-10T10:00:28Z rework shorter 1500ms by claude 40 → 20 chars",
            "2026-11-10T10:00:29Z rework fix 1500ms by local none",
            "2026-11-10T10:00:30Z rework applied shorter, 40 → 20 chars",
            "2026-11-13T09:00:00Z take 4.2 s, peak 0.31",
            "2026-11-12T09:00:00Z take 3.0 s, peak 0.20",
            "garbage",
        ]
        let c = LogStats.count(lines, since: "2026-11-06T00:00:00Z", today: "2026-11-13")
        func is_(_ k: String, _ s: Int, _ t: Int) { check(c[k] == LogStats.Count(shown: s, taken: t), "\(k): want \(s)/\(t), got \(String(describing: c[k]))") }
        is_(LogStats.suggest, 2, 1)
        is_(LogStats.fixWord, 1, 1)
        is_(LogStats.typo, 3, 2)
        is_(LogStats.layout, 2, 0)
        for gone in ["claude", "proofread", "translate", "facts"] { check(c[gone] == nil, "\(gone): removed 2026-11-17, old lines count nowhere") }
        is_(LogStats.next, 2, 1)
        is_(LogStats.rework, 1, 1)
        check(c["takes"]?.shown == 1, "today's takes")

        let w = LogStats.warnings([
            "2026-11-03T14:04:50Z recording: warning: Your microphone gives only silence (muted or taken by another app?) (me 6.0 s peak 0.000; them running 6.0 s peak 0.020)",
            "2026-11-03T14:05:30Z recording: both sides heard again (me 46.0 s peak 0.2; them running 46.0 s peak 0.3)",
            "2026-11-03T14:06:00Z recording: warning: Your microphone gives only silence (muted or taken by another app?) (me 70.0 s peak 0.000; them running 70 s peak 0.1)",
            "2026-11-03T14:07:00Z recording: warning: Not hearing the other side yet (me 1 s peak 0.1; them running 1 s peak 0.001)",
            "2026-11-03T16:00:00Z recording: warning: Microphone gives no sound at all (me 0 s peak 0; them none 0 s peak 0)",
        ], from: "2026-11-03T14:04:46Z", to: "2026-11-03T15:00:00Z")
        check(w == ["Your microphone gives only silence (muted or taken by another app?)", "Not hearing the other side yet"], "warnings in the window, once each: \(w)")
        print("log stats: all checks passed")
    }
}
