// Typing telemetry (numbers only, never text): caret-rect success rates per app/role (data/caret.json)
// and keystroke-to-ghost latency percentiles (data/latency.json). Extracted from Keys.swift.
import AppKit

/// Where the caret could and could not be found, per app and field role (data/caret.json).
enum Caret {
    static var table: [String: [String: Int]] = {
        guard let d = try? Data(contentsOf: Home.data.appendingPathComponent("caret.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Int]] else { return [:] }
        return j
    }()
    static var dirty = 0
    static func note(_ app: NSRunningApplication, _ role: String, ok: Bool) {
        let k = "\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) \(role)"
        table[k, default: [:]][ok ? "ok" : "fail", default: 0] += 1
        dirty += 1
        if dirty >= 10 {
            dirty = 0
            if let d = try? JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: Home.data.appendingPathComponent("caret.json"), options: .atomic)
            }
        }
    }
}

/// Keystroke-to-ghost time as the user sees it (after the debounce), written every 20 shows to data/latency.json.
enum Stats {
    static var app: [Double] = [], engine: [Double] = [], n = 0
    static func add(ms: Double, engineMs: Double) {
        app.append(ms); engine.append(engineMs); n += 1
        // the newest 2,000 only (Argon 24: both grew for as long as the app ran, sorted whole every 20 ghosts)
        if app.count > 2400 { app.removeFirst(400); engine.removeFirst(400) }
        guard n % 20 == 0 else { return }
        func p(_ a: [Double], _ q: Double) -> Int { let s = a.sorted(); return Int(s[min(s.count - 1, Int(Double(s.count) * q))]) }
        let j: [String: Any] = ["n": app.count, "request_ms_p50": p(app, 0.5), "request_ms_p90": p(app, 0.9),
                                "engine_ms_p50": p(engine, 0.5), "engine_ms_p90": p(engine, 0.9), "debounce_ms": Int(Keys.shared.debounce * 1000)]
        if let d = try? JSONSerialization.data(withJSONObject: j, options: .prettyPrinted) {
            try? d.write(to: Home.data.appendingPathComponent("latency.json"), options: .atomic)
        }
    }
}
