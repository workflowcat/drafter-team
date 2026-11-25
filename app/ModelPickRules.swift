// Model catalog (Cotypist parity round 2, 15 November 2026): the pure rules of Settings > Typing > Model. The engine's
// GET /models answer becomes rows; each row says what a press on it does (pick, download, cancel) or that it is
// loading. The personal-style slider is off for a model without his trained layer. View: app/ModelSettings.swift.
import Foundation

struct ModelRow: Equatable {
    var id = "", name = ""
    var diskGB = 0.0
    var speed = 0, quality = 0          // 1-3 marks (engine/catalog.py speed_mark, quality_mark)
    var layer = false, downloaded = false, recommended = false, current = false
    var download = "none"               // none, downloading, done, failed, cancelled
    var pct = 0
}

enum ModelPick {
    enum Action: Equatable { case none, pick, download, cancel, loading }

    static func rows(_ j: [String: Any]) -> [ModelRow] {
        let cur = j["current"] as? String, rec = j["recommended"] as? String
        return (j["models"] as? [[String: Any]] ?? []).map { m in
            let d = m["download"] as? [String: Any] ?? [:]
            let id = m["id"] as? String ?? ""
            return ModelRow(id: id, name: m["name"] as? String ?? id, diskGB: m["disk_gb"] as? Double ?? 0,
                            speed: m["speed"] as? Int ?? 0, quality: m["quality"] as? Int ?? 0,
                            layer: m["layer"] as? Bool ?? false, downloaded: m["downloaded"] as? Bool ?? false,
                            recommended: id == rec, current: id == cur,
                            download: d["state"] as? String ?? "none", pct: d["pct"] as? Int ?? 0)
        }
    }

    /// What pressing this row does. `switching`: the id being loaded now, if any (then nothing else can be picked).
    static func action(_ r: ModelRow, switching: String?) -> Action {
        if switching == r.id { return .loading }
        if r.download == "downloading" { return .cancel }
        if !r.downloaded { return .download }
        if r.current || switching != nil { return .none }
        return .pick
    }

    /// The gutter: size on disk.
    static func size(_ gb: Double) -> String { String(format: "%.1f GB", gb) }

    /// The right-hand word of a row.
    static func status(_ r: ModelRow, switching: String?) -> String {
        switch action(r, switching: switching) {
        case .loading: return "loading…"
        case .cancel: return "\(r.pct) %"
        case .download: return r.download == "failed" ? "failed" : ""
        default: return ""
        }
    }

    /// Without his layer the personal-style slider has nothing to scale: off, with this one word beside it.
    static func styleReason(layer: Bool) -> String? { layer ? nil : "untrained" }

    /// Whether the picked model has his layer; before the first answer only live has one.
    static func hasLayer(_ rows: [ModelRow], id: String) -> Bool { rows.first { $0.id == id }?.layer ?? (id == "live") }

    /// Ask the engine again in a second: a download runs or a model loads.
    static func keepPolling(_ rows: [ModelRow], switching: String?) -> Bool {
        switching != nil || rows.contains { $0.download == "downloading" }
    }
}
