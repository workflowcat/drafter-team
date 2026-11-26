import Foundation

// swiftc -parse-as-library app/Settings.swift app/SettingsRules.swift tests/settings_load.swift -o app/build/settings-load-test && app/build/settings-load-test
// Settings cleanup round (17 November 2026): an old settings file with every key it ever had (114: before the round,
// with the 3 removed ones) still loads, fixed keys keep their default whatever the file says, and SettingsPlan places
// every key once, at most 11 on the main page, every cloud switch visible. Made-up values only.

enum QuickRules { static let defaultKey = ""; static let defaultSecrets: [String] = [] }
enum ShotRules { static let defaultKey = "⌘⇧5" }
enum KeyRules { static func keysRoundTwo(_ j: [String: Any]) -> [String: Any] { j }; static func keysRoundThree(_ j: [String: Any]) -> [String: Any] { j }; static func needsKeysRound(_ j: [String: Any]) -> Bool { false } }
enum Home {
    static let bundleID = "drafter.test"
    static let settings = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drafter-settings-load-test.json")
}

@main
struct SettingsLoadChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    /// Every key a file written before the round could hold, each boolean the other way round from its default.
    static let oldFile = ##"""
{
 "actions_off": [],
 "adapter": "made-up-adapter",
 "againKey": "",
 "againTap": false,
 "alternatives": false,
 "appNotes": {
  "com.example.chat": "A made-up note."
 },
 "autocorrect": false,
 "autocorrectMode": "offer",
 "autocorrectUk": true,
 "calendarsOff": [],
 "callNotes": true,
 "callOff": [
  "notion.id"
 ],
 "captureCmdShiftS": true,
 "captureFallbackKey": "",
 "captureHintShown": true,
 "captureKey": "⌘⇧5",
 "captureTalk": false,
 "cardSize": 1,
 "claudeModel": "sonnet",
 "claudePause": true,
 "claudeTyping": true,
 "clipContext": false,
 "clipImageMB": 8,
 "clipTotalMB": 300,
 "cloudDefaults": "off",
 "comboModels": true,
 "connect": {
  "apiModel": "",
  "baseURL": "",
  "carefulModel": "claude-sonnet-5-5",
  "fastModel": "claude-haiku-5-5",
  "provider": ""
 },
 "contextLevelAI": 2,
 "contextLevelAgent": 3,
 "contextPacks": false,
 "deckAt": "",
 "earlyStart": false,
 "entityClassify": true,
 "escPause": false,
 "facts": true,
 "fallbackAnchor": false,
 "fixWord": false,
 "fmt": "bare",
 "ghostLength": "sentence",
 "ghostMaxWords": 5,
 "ghostMinWords": 3,
 "ghostWords": false,
 "guessGhosts": false,
 "guessShade": false,
 "idleGhost": false,
 "journalFold": "older",
 "journalLook": "soft",
 "journalView": "gallery",
 "keepMic": true,
 "keepTyping": false,
 "keysRound": 2,
 "layoutFix": false,
 "learn": false,
 "longGhostsAI": false,
 "longGhostsChats": true,
 "lookVariant": "a",
 "midLine": false,
 "minGhost": 5,
 "minGhostShort": 3,
 "model": "made-up/model",
 "nextMessage": true,
 "paused": true,
 "personalStrength": 100,
 "pickOffer": false,
 "predictKeys": false,
 "proofread": true,
 "proofreadOff": [
  "ai"
 ],
 "quickDays": 30,
 "quickKey": "",
 "quickMax": 1000,
 "quickSecret": [
  "\\b(sk|pk|rk)[-_](live|test|proj|ant)?[-_]?[A-Za-z0-9_-]{20,}",
  "\\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\\bgithub_pat_[A-Za-z0-9_]{30,}",
  "\\bxox[abprs]-[A-Za-z0-9-]{10,}|\\bAKIA[0-9A-Z]{16}\\b|\\bAIza[0-9A-Za-z_-]{35}",
  "(?i)\\b(api[_ -]?key|secret|token|password|passwd|пароль)\\s*[:=]\\s*\\S{6,}",
  "-----BEGIN [A-Z ]*PRIVATE KEY-----",
  "\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}",
  "(?m)^\\s*(?=[\\w-]*\\d)(?=[\\w-]*[A-Za-z])(?![a-z0-9]+(?:-[a-z0-9]+){2,}\\s*$)[A-Za-z0-9_-]{32,}\\s*$",
  "(?m)^\\D{0,24}\\b(\\d{4}[ -]?){3}\\d{1,7}\\b\\D{0,24}$",
  "^\\s*(\\d{6}|\\d{3}[ -]\\d{3}|\\d{8})\\s*$"
 ],
 "readerCheck": true,
 "recordWindow": false,
 "retrainRemote": true,
 "rework": true,
 "screen": false,
 "screenContext": false,
 "sentenceProof": true,
 "shortGhosts": false,
 "shotFolder": "",
 "shotLast": "",
 "shots": false,
 "skip": [
  "com.example.skipped"
 ],
 "streamGhost": false,
 "stripStyle": "composer",
 "switchFormat": true,
 "switchKey": "⌘⇧V",
 "switchSwap": false,
 "tabBack": false,
 "tapeDensity": "compact",
 "textIdleMin": 30,
 "translate": true,
 "typingModel": "live",
 "typoEngine": "ranked",
 "typoHold": false,
 "typography": false,
 "typographyApostrophe": false,
 "typographyApostropheMark": "ʼ",
 "typographyArrows": false,
 "typographyDash": false,
 "typographyEllipsis": false,
 "typographyHryvnia": true,
 "typographyMath": false,
 "typographyNbsp": true,
 "typographyQuotes": false,
 "typographySpacedDash": false,
 "typographySymbols": false,
 "voice": true,
 "voiceCareful": "made-up/careful",
 "voiceFast": "made-up/fast",
 "voiceIdleMin": 30,
 "voiceInsert": "enter",
 "voiceLive": true,
 "writingNote": "Short lines, made up for this test."
}
"""##

    static func main() {
        check(Settings().obsidianVault.isEmpty, "vault defaults off")
        check(Settings.decode(Data(#"{"obsidianVault":42}"#.utf8))?.obsidianVault == "", "malformed vault keeps default")
        check(Settings.decode(Data(#"{"obsidianVault":"/tmp/Orchard"}"#.utf8))?.obsidianVault == "/tmp/Orchard", "vault loads")
        var vault = Settings(); vault.obsidianVault = "/tmp/Orchard"
        check(Settings.decode(try! JSONEncoder().encode(vault))?.obsidianVault == vault.obsidianVault, "vault round trip")
        check(SettingsPlan.advanced.contains("obsidianVault"), "vault is advanced")
        let raw = (try? JSONSerialization.jsonObject(with: Data(oldFile.utf8))) as? [String: Any] ?? [:]
        check(raw.count == 114, "the old file holds 114 keys: \(raw.count)")
        guard let s = Settings.decode(Data(oldFile.utf8)) else { check(false, "the old file loads"); return }
        // his choices on the main page and in Advanced come through
        check(s.paused && !s.autocorrect && !s.layoutFix && !s.typography && !s.learn, "Typing switches decoded")
        check(!s.callScreenVideo, "old settings keep video off")
        check(Settings.decode(Data(#"{"callScreenVideo":true}"#.utf8))?.callScreenVideo == true, "video opt-in decodes")
        check(Settings.decode(Data(#"{"callScreenVideo":"yes"}"#.utf8))?.callScreenVideo == false, "invalid video opt-in stays off")
        var videoSettings = Settings(); videoSettings.callScreenVideo = true
        check(Settings.decode(try! JSONEncoder().encode(videoSettings))?.callScreenVideo == true, "video opt-in survives a save")
        let gone = Settings.decode(Data(#"{"mcp":true,"backOffice":true,"retrainRemote":true,"rework":true}"#.utf8))
        check(gone?.rework == true, "an old file with removed switches still loads")
        check(s.voice && !s.shots && s.longGhostsAI == false && s.longGhostsChats && !s.idleGhost, "voice, calls, advanced decoded")
        check(s.callNotes && s.entityClassify && s.rework, "cloud switches decoded")
        check(s.model == "made-up/model" && s.voiceFast == "made-up/fast" && s.adapter == "made-up-adapter" && s.fmt == "bare", "hidden keys decoded")
        check(s.writingNote.hasPrefix("Short lines") && s.appNotes.count == 1, "writing notes decoded")
        check(!s.screenContext, "screenContext decoded")
        // fixed keys: the file says false, the app keeps true
        check(s.ghostWords && s.guessGhosts && s.guessShade && s.earlyStart && s.shortGhosts && s.keepTyping && s.typoHold
              && s.midLine && s.fallbackAnchor, "fixed keys keep their default")
        // removed keys are gone when the app saves again; the rest are all still written
        let out = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s))) as? [String: Any] ?? [:]
        for k in SettingsPlan.removed + SettingsPlan.removedTyping { check(out[k] == nil, "removed key \(k) is not written") }
        let lost = Set(raw.keys).subtracting(out.keys).subtracting(["voiceCareful"] + SettingsPlan.removed + SettingsPlan.removedTyping)
        check(lost.isEmpty, "every other key is written back (keys added later may be written too): \(lost.sorted())")
        // screen, the old name: read when screenContext is missing
        let legacy = Settings.decode(Data(#"{"screen": false}"#.utf8))
        check(legacy?.screenContext == false, "an old screen=false turns screenContext off")
        check((Settings.decode(Data("{}".utf8)))?.screenContext == true, "an empty file keeps the defaults")
        // the plan: each key in one place, the main page at most 11, every cloud switch on the page
        let places = [SettingsPlan.main.map(\.key), SettingsPlan.cloud, SettingsPlan.advanced, SettingsPlan.fixed,
                      SettingsPlan.removed, SettingsPlan.removedTyping, SettingsPlan.panel, SettingsPlan.hidden]
        let all = places.flatMap { $0 }
        check(all.count == Set(all).count, "no key in two places")
        let now = Set(((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings()))) as? [String: Any] ?? [:]).keys)
        check(Set(raw.keys).union(now).isSubset(of: Set(all)), "every key placed, old and new: missing \(Set(raw.keys).union(now).subtracting(all).sorted())")
        check(SettingsPlan.main.count <= 11, "at most 11 on the main page: \(SettingsPlan.main.count)")
        check(Set(SettingsPlan.main.map(\.group)).isSubset(of: ["Typing", "Voice", "Calls", "Capture"]), "main groups")
        check(Set(Settings.cloudKeys).isSubset(of: SettingsPlan.cloud), "every Claude switch is in Cloud")
        check(Set(SettingsPlan.cloud).isDisjoint(with: SettingsPlan.hidden + SettingsPlan.fixed + SettingsPlan.advanced), "no cloud switch hidden")
        roundTrips()
        print("settings load: all checks passed (\(raw.count) old keys; main \(SettingsPlan.main.count), cloud \(SettingsPlan.cloud.count), advanced \(SettingsPlan.advanced.count), fixed \(SettingsPlan.fixed.count), removed \(SettingsPlan.removed.count), hidden \(SettingsPlan.hidden.count))")
    }

    /// Values decode leniently and survive save and load (from tests/test_fix_offers.py and
    /// tests/test_voice_settings_swift.py, 18 November 2026: one set of stand-ins).
    static func roundTrips() {
        try? FileManager.default.removeItem(at: Home.settings)
        let empty = Settings.decode(Data("{}".utf8))!
        check(empty.autocorrectMode == "offer" && empty.voiceFast == nil && empty.voiceCareful == nil, "defaults")
        let emptyOut = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(empty))) as? [String: Any] ?? [:]
        check(Settings.cloudKeys.allSatisfy { emptyOut[$0] as? Bool == false }, "an empty file has every Claude switch off (engine/cloud.py DEFAULTS)")
        var s = Settings.decode(Data(#"{"autocorrectMode":"replace","rework":true,"voiceFast":"~/models/fast","voiceCareful":"repo/q4","voice":true}"#.utf8))!
        s.paused = true
        s.save(); let back = Settings.load()
        check(back.autocorrectMode == "replace" && back.rework && back.paused && back.voice, "save and load keep his values")
        check(back.voiceFast == "~/models/fast" && back.voiceCareful == "repo/q4", "save and load keep the voice models")
        check(Settings.decode(Data(#"{"autocorrectMode":7}"#.utf8))!.autocorrectMode == "offer", "a wrong value keeps the default")
        let bad = Settings.decode(Data(#"{"voiceFast":false,"voiceCareful":[],"voice":true}"#.utf8))!
        check(bad.voiceFast == nil && bad.voiceCareful == nil && bad.voice, "wrong model values fall back alone")
        // a file from before 2026-11-17 still holds the removed Claude typing keys: it decodes, the keys are skipped
        let old = Settings.decode(Data(#"{"claudeTyping":true,"claudePause":true,"proofread":true,"proofreadOff":["ai"],"sentenceProof":true,"facts":true,"translate":true,"nextMessage":true,"claudeModel":"haiku","rework":true,"minGhost":4}"#.utf8))!
        check(old.rework && old.claudeModel == "haiku" && old.minGhost == 4, "removed keys are skipped")
        // one wrongly typed key falls back alone; before 2026-11-15 a wrong type on a strict key reset every setting
        let one = Settings.decode(Data(#"{"voice":"yes","minGhost":3,"skip":["a.b"]}"#.utf8))!
        check(!one.voice && one.minGhost == 3 && one.skip == ["a.b"], "one wrong type falls back alone")
        // atomic save: rewrites replace the inode via rename, so a concurrent reader never sees a truncated file
        s.save()
        let attrs1 = try? FileManager.default.attributesOfItem(atPath: Home.settings.path)
        let ino1 = attrs1?[.systemFileNumber] as? UInt64
        s.paused = false
        s.save()
        let attrs2 = try? FileManager.default.attributesOfItem(atPath: Home.settings.path)
        let ino2 = attrs2?[.systemFileNumber] as? UInt64
        check(ino1 != nil && ino2 != nil && ino1 != ino2, "Settings.save writes atomically (replaces inode)")
        try? FileManager.default.removeItem(at: Home.settings)
    }
}
