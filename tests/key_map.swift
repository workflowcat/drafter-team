// swiftc -parse-as-library app/PenRules.swift app/KeyMap.swift app/KeyRules.swift app/QuickRules.swift app/PictureLookRules.swift app/ClipRules.swift app/ShotRules.swift app/MarkupRules.swift app/ShotPackRules.swift tests/key_map.swift -o app/build/key-map-test && app/build/key-map-test
// The key map (keys round three, 17 November 2026, docs/plans/2026-11-17-key-map.md): no two default-on keys share a
// chord in one place, no default key is one Drafter gave back, Help (built from the registry) names no retired key,
// and the settings defaults agree with the registry. Reads app/Settings.swift and app/HelpViews.swift as text only.
import Foundation

@main
struct KeyMapChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        ids(); clashes(); givenBack(); help(); defaults(); helpSource(); window()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("key map: \(KeyMap.all.count) keys, \(KeyMap.clashes().count) default clashes")
    }

    static func ids() {
        let ids = KeyMap.all.map(\.id)
        check(Set(ids).count == ids.count, "every id once")
        check(KeyMap.all.allSatisfy { !$0.keys.isEmpty && !$0.job.isEmpty }, "every key has keys and a job")
        check(KeyMap.all.allSatisfy { $0.section.isEmpty || !$0.help.isEmpty }, "a key in a Help part has a Help line")
    }

    static func clashes() {
        for (a, b) in KeyMap.clashes() { check(false, "clash on \(a.surface.rawValue): \(a.id) and \(b.id) both \(a.keys)") }
        // the check itself finds a clash
        let t = [KeyDef(id: "a", keys: "⌘⇧V", job: "x", surface: .global), KeyDef(id: "b", keys: "⇧⌘V", job: "y", surface: .global),
                 KeyDef(id: "c", keys: "⌘⇧V", job: "y", surface: .picker), KeyDef(id: "d", keys: "⌘⇧V", job: "y", surface: .global, on: false),
                 KeyDef(id: "e", keys: "⌘T", job: "x", surface: .picker, scope: "link"), KeyDef(id: "f", keys: "⌘T", job: "x", surface: .picker, scope: "picture"),
                 KeyDef(id: "g", keys: "⌘T", job: "x", surface: .picker)]
        let found = KeyMap.clashes(t).map { $0.0.id + $0.1.id }
        check(found == ["ab", "eg", "fg"], "same chord in another modifier order clashes; other surface, off, other scope do not: \(found)")
        check(KeyMap.norm("Tab") == KeyMap.norm("⇥") && KeyMap.norm("⌥⌘C") == KeyMap.norm("⌘⌥C") && KeyMap.norm("⌥⌘C") != KeyMap.norm("⌘C"), "chord spelling")
    }

    /// Keys round three gave these back; no key on by default may take them (globally, in a field or the strip).
    static func givenBack() {
        let back = Set(KeyMap.givenBack.map(KeyMap.norm))
        for k in KeyMap.all where k.on {
            let parts = k.keys.split(separator: " ").map { KeyMap.norm(String($0)) }
            check(!back.contains(KeyMap.norm(k.keys)) && !parts.contains(where: back.contains), "\(k.id) takes a key Drafter gave back: \(k.keys)")
        }
        for k in KeyMap.all where k.on && k.surface == .global {
            check(!KeyMap.retired.map(KeyMap.norm).contains(KeyMap.norm(k.keys)), "\(k.id): a retired chord is on by default")
        }
        // the global chords he can set are all different
        let chords = ["picker", "quickKey", "capture", "captureFallback", "captureSaveAs", "pick", "againKey"].compactMap { KeyMap.entry($0)?.keys }
        check(Set(chords.map(KeyMap.norm)).count == chords.count, "settable global chords are all different: \(chords)")
        check(KeyMap.entry("alternatives")?.on == false && KeyMap.entry("swap")?.on == false, "⌥1-3 and the ⌘⇧V swap are opt-in")
    }

    static func help() {
        let sections = ["typing", "names", "dictionary", "voice", "calls", "actions", "elsewhere"]
        for s in sections {
            let lines = KeyMap.help(s)
            check(!lines.isEmpty, "Help part \(s) has keys")
            check(Set(lines.map(\.0)).count == lines.count, "Help part \(s): each key once (SwiftUI rows are keyed by it)")
            for (k, v) in lines {
                for r in KeyMap.retired { check(!k.contains(r) && !v.contains(r), "Help \(s) names a retired key \(r): \(k) \(v)") }
                check(!(k == "⇥" || k == "Tab") || !v.lowercased().contains("record"), "Help: Tab never records")
            }
        }
        let all = sections.flatMap(KeyMap.help)
        check(!all.contains { $0.1.contains("again within 2 s") }, "Help no longer offers the swap")
        check(all.contains { $0.0 == "Right Option" && $0.1.contains("once on") }, "Help: voice once on")
        check(KeyMap.all.filter { !$0.section.isEmpty }.allSatisfy { k in !KeyMap.retired.contains(where: { k.keys.contains($0) }) }, "no retired key in Help")
    }

    /// The defaults: QuickRules, ShotRules and Settings agree with the registry.
    static func defaults() {
        check(QuickRules.defaultKey == KeyMap.defaultChord("quickKey"), "quickKey default")
        check(QuickRules.suggestedKey == KeyMap.entry("quickKey")?.keys, "quickKey suggested")
        check(ShotRules.defaultKey == KeyMap.defaultChord("capture"), "captureKey default")
        check(ShotRules.oldKey == KeyMap.entry("captureFallback")?.keys && ShotRules.saveAsKey == KeyMap.entry("captureSaveAs")?.keys, "capture's other keys")
        check(KeyRules.doubleTap == KeyMap.doubleWindow && EscPause.window == KeyMap.doubleWindow && KeyMap.doubleWindow == 0.45, "one double-press window, 0.45 s")
        guard let src = try? String(contentsOfFile: "app/Settings.swift", encoding: .utf8) else { check(false, "read app/Settings.swift"); return }
        func value(_ name: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: "\\bvar \(name) = ([^,/\\n]+)"),
                  let m = r.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)), let g = Range(m.range(at: 1), in: src) else { return nil }
            let v = src[g].trimmingCharacters(in: .whitespaces)
            if v == "QuickRules.defaultKey" { return "\"\(QuickRules.defaultKey)\"" }
            if v == "ShotRules.defaultKey" { return "\"\(ShotRules.defaultKey)\"" }
            return v
        }
        var seen = Set<String>()
        for k in KeyMap.all where !k.setting.isEmpty && !seen.contains(k.setting) {
            seen.insert(k.setting)
            guard let v = value(k.setting) else { check(false, "Settings has \(k.setting)"); continue }
            if v == "true" || v == "false" { check((v == "true") == k.on, "Settings.\(k.setting) = \(v), key map says on: \(k.on)") }
            else { check(v == "\"\(k.on ? k.keys : "")\"", "Settings.\(k.setting) = \(v), key map: \(k.on ? k.keys : "off")") }
        }
        check(value("keysRound") == "3", "fresh files are at keys round three")
    }

    /// Help's key lists in HelpViews.swift come from the registry (the journal keeps its own list).
    static func helpSource() {
        guard let src = try? String(contentsOfFile: "app/HelpViews.swift", encoding: .utf8), let i = src.range(of: "struct HelpView") else {
            check(false, "read HelpView in app/HelpViews.swift"); return
        }
        let help = String(src[i.lowerBound...])
        let keyArgs = help.components(separatedBy: "keys: ").dropFirst().map { String($0.prefix(20)) }
        check(!keyArgs.isEmpty && keyArgs.allSatisfy { $0.hasPrefix("KeyMap.help(") || $0.hasPrefix("JournalKeys.all") || $0.hasPrefix("[]") || $0.hasPrefix("[(String") },
              "every Help part reads KeyMap: \(keyArgs)")
        for r in KeyMap.retired + ["⌃⇥"] { check(!help.contains("\"\(r)\""), "Help source names \(r)") }
    }

    /// Keys round three's rules (KeyRules), made-up states only.
    static func window() {
        // keysRound 3: a file at round two, or before it
        let two: [String: Any] = ["keysRound": 2, "switchSwap": true, "alternatives": true, "voice": true]
        let a = KeyRules.keysRoundThree(two)
        check(a["switchSwap"] as? Bool == false && a["alternatives"] as? Bool == false && a["pickKey"] as? String == "⌃⌥P" && a["keysRound"] as? Int == 3
              && a["voice"] as? Bool == true, "round two -> three")
        let none = KeyRules.keysRoundThree(["quickKey": "⌃⌥V", "pickKey": ""])
        check(none["quickKey"] as? String == "" && none["pickKey"] as? String == "" && none["keysRound"] as? Int == 3, "no mark: round two first; his own pickKey stays")
        check(KeyRules.needsKeysRound([:]) && KeyRules.needsKeysRound(["keysRound": 2]) && !KeyRules.needsKeysRound(["keysRound": 3]), "which files move")
    }
}
