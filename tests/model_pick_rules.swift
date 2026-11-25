import Foundation

// swiftc -parse-as-library app/ModelPickRules.swift tests/model_pick_rules.swift -o app/build/model-pick-rules-test && app/build/model-pick-rules-test
// Model catalog round 2026-11-15: rows from GET /models, what a press does, the style slider's reason. Made-up rows.

@main
struct ModelPickRulesTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }

    static func main() {
        let j: [String: Any] = [
            "current": "live", "recommended": "live",
            "models": [
                ["id": "live", "name": "Qwen3 1.7B + my style", "disk_gb": 0.98, "speed": 3, "quality": 3, "layer": true,
                 "downloaded": true, "download": ["state": "done", "pct": 100]],
                ["id": "small", "name": "Small", "disk_gb": 1.06, "speed": 2, "quality": 2, "layer": false,
                 "downloaded": true, "download": ["state": "done", "pct": 100]],
                ["id": "big", "name": "Big", "disk_gb": 3.61, "speed": 1, "quality": 1, "layer": false,
                 "downloaded": false, "download": ["state": "downloading", "pct": 42]],
                ["id": "away", "name": "Away", "disk_gb": 2.28, "speed": 1, "quality": 2, "layer": false,
                 "downloaded": false, "download": ["state": "none", "pct": 0]],
            ] as [[String: Any]],
        ]
        let rows = ModelPick.rows(j)
        check(rows.count == 4, "four rows")
        check(rows[0].current && rows[0].recommended && rows[0].layer, "live is current, recommended, has the layer")
        check(!rows[1].current && !rows[1].recommended, "others are not")
        check(ModelPick.size(rows[0].diskGB) == "1.0 GB", "size in the gutter")

        check(ModelPick.action(rows[0], switching: nil) == .none, "the current one: nothing to do")
        check(ModelPick.action(rows[1], switching: nil) == .pick, "downloaded: pick")
        check(ModelPick.action(rows[2], switching: nil) == .cancel, "downloading: cancel")
        check(ModelPick.status(rows[2], switching: nil) == "42 %", "progress word")
        check(ModelPick.action(rows[3], switching: nil) == .download, "not here: download, never by itself")
        check(ModelPick.action(rows[1], switching: "small") == .loading, "the one loading")
        check(ModelPick.status(rows[1], switching: "small") == "loading…", "loading word")
        check(ModelPick.action(rows[0], switching: "small") == .none, "no second pick while one loads")
        check(ModelPick.action(rows[3], switching: "small") == .download, "a download may still start")
        var failed = rows[3]; failed.download = "failed"
        check(ModelPick.status(failed, switching: nil) == "failed", "a failed download says so")

        check(ModelPick.styleReason(layer: true) == nil, "style slider on with the layer")
        check(ModelPick.styleReason(layer: false) == "untrained", "off with one word without it")
        check(ModelPick.hasLayer(rows, id: "small") == false && ModelPick.hasLayer(rows, id: "live"), "layer by id")
        check(ModelPick.hasLayer([], id: "live") && !ModelPick.hasLayer([], id: "small"), "before the first answer only live")

        check(ModelPick.keepPolling(rows, switching: nil), "a download runs: poll")
        check(!ModelPick.keepPolling([rows[0], rows[1]], switching: nil), "nothing runs: no poll")
        check(ModelPick.keepPolling([rows[0]], switching: "small"), "a model loads: poll")

        check(ModelPick.rows([:]).isEmpty, "no answer: no rows")
        if failures == 0 { print("model pick rules: all passed") } else { print("\(failures) failed"); exit(1) }
    }
}
