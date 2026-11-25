import Foundation

/// The owner's local config, data/drafter.local.json (untracked; engine/local.py reads the same file, and the tracked
/// drafter.local.example.json shows every key). No file: neutral wording, every private integration off.
enum LocalConfig {
    private static var cache: (stamp: Date?, json: [String: Any]) = (nil, [:])
    static var file: URL { Home.data.appendingPathComponent("drafter.local.json") }

    static var json: [String: Any] {
        let m = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if m != cache.stamp || m == nil {
            let d = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            cache = (m, d ?? [:])
        }
        return cache.json
    }

    static func user(_ key: String) -> String {
        ((json["user"] as? [String: Any])?[key] as? String ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// First name for short lines ("Я = <name>"); "the user" without a config.
    static var shortName: String {
        let s = user("short_name")
        if !s.isEmpty { return s }
        return user("name").split(separator: " ").first.map(String.init) ?? "the user"
    }

    /// The user's own keys in calendar people: the e-mail name and own names, lower case (a call's people leave them out).
    static var ownKeys: Set<String> {
        let names = (json["user"] as? [String: Any])?["own_names"] as? [String] ?? []
        let mail = user("email").split(separator: "@").first.map(String.init) ?? ""
        return Set(([mail] + names).map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    /// Apps where Drafter stays quiet, from the config's integrations (an owner's own dictation app).
    static var skipApps: [String] {
        let id = integration("voice_notes")["bundle_id"] as? String ?? ""
        return enabled("voice_notes") && !id.isEmpty ? [id] : []
    }

    static func integration(_ name: String) -> [String: Any] {
        (json["integrations"] as? [String: Any])?[name] as? [String: Any] ?? [:]
    }

    /// The config turns it on (whether its tool answers is `available`).
    static func enabled(_ name: String) -> Bool { integration(name)["enabled"] as? Bool == true }

    /// On in the config and its file is there (engine/integrations.py checks the same, plus Aleph's port). The app
    /// itself only asks for "gam": the Google lookups and the Google account block in Settings.
    static func available(_ name: String) -> Bool {
        guard enabled(name) else { return false }
        for key in ["bin", "path", "db"] {
            if let p = integration(name)[key] as? String, !p.isEmpty {
                return FileManager.default.fileExists(atPath: (p as NSString).expandingTildeInPath)
            }
        }
        return true
    }
}
