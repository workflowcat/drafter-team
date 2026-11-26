// How Settings groups the user's calendars (2026-11-13, window round: rows named "Transferred from xx@…" repeated that phrase
// on every row, and every row carried its account under it). Pure, for a test.
import Foundation

enum CalendarGroups {
    static let transferred = "Transferred from "

    /// Calendars grouped under one heading each: an account (its own calendars, by title), then one "Transferred"
    /// group whose rows are the addresses the calendars came from.
    static func group(_ cals: [(id: String, title: String, source: String)]) -> [(heading: String, rows: [(id: String, name: String)])] {
        var own: [String: [(id: String, name: String)]] = [:], moved: [(id: String, name: String)] = []
        for c in cals {
            if c.title.lowercased().hasPrefix(transferred.lowercased()) {
                let address = String(c.title.dropFirst(transferred.count)).trimmingCharacters(in: .whitespaces)
                moved.append((c.id, address.isEmpty ? c.title : address))
            } else {
                own[c.source.isEmpty ? "Other" : c.source, default: []].append((c.id, c.title))
            }
        }
        var out = own.keys.sorted().map { (heading: $0, rows: own[$0]!.sorted { $0.name.lowercased() < $1.name.lowercased() }) }
        if !moved.isEmpty { out.append((heading: "Transferred", rows: moved.sorted { $0.name.lowercased() < $1.name.lowercased() })) }
        return out
    }
}

/// Where every setting lives since the settings cleanup round (17 November 2026, docs/rounds/2026-11-17-settings.md):
/// the main page holds at most 11 switches (including opt-in screen video), cloud switches stay visible in Cloud,
/// the rest sit in one collapsed Advanced section, are fixed in code (Settings ignores a saved value) or were removed
/// (no code read them; an old file with them still loads). SettingsView (app/Window.swift) draws these lists; a test
/// (tests/settings_load.swift) holds them to the counts and to Settings.cloudKeys.
enum SettingsPlan {
    /// Typing, Voice, Calls, Capture: the everyday switches, in page order.
    static let main: [(group: String, key: String)] = [
        ("Typing", "paused"), ("Typing", "autocorrect"), ("Typing", "layoutFix"), ("Typing", "typography"), ("Typing", "learn"),
        ("Voice", "voice"), ("Voice", "voiceInsert"),
        ("Calls", "shots"), ("Calls", "callScreenVideo"),
        ("Capture", "captureKey"), ("Capture", "switchKey"),
    ]
    /// Each sends text off the Mac when on, so each stays on the page with its cloud mark (AGENTS.md "What leaves the Mac").
    static let cloud = ["voiceClaude", "rework", "pauseRewrite", "callNotes", "entityClassify"]
    /// The collapsed section at the bottom of the page.
    static let advanced = [
        "longGhostsAI", "longGhostsChats", "idleGhost", "comboModels", "typingModel", "personalStrength", "guessBar", "writingNote", "appNotes",
        "clipContext", "alternatives", "readerCheck", "instantReplies", "autocorrectMode", "autocorrectUk", "fixWord", "tabBack", "escPause",
        "pickOffer", "screenContext", "keepMic", "againTap", "commandsKey", "recordWindow", "callOff", "calendarsOff", "quickKey", "switchSwap",
        "captureCmdShiftS", "captureFallbackKey", "captureTalk", "clipTotalMB", "stripStyle", "journalView", "journalLook",
        "cardSize", "tapeDensity", "journalFold", "obsidianVault",
        // added on main during the round: voice style, auto-record (same rows, now in Advanced)
        "voiceStyle", "voiceStyleApps", "voiceLevel", "voiceLevelApps", "voiceModes", "voiceShape", "voiceChatLines", "voiceSnippets", "cleanNote", "autoRecordApps",
        "autoRecordCalendars", "switchQuickForm", "editMarks", "duckAudio",
        // the coordinator's cleanup (same day): file-only keys someone may want, now with a row
        "streamGhost", "textIdleMin", "contextPacks", "typographyDash", "typographySpacedDash", "typographyEllipsis", "typographyQuotes", "typographyApostrophe", "typographyArrows", "typographyMath", "typographySymbols", "typographyHryvnia", "typographyNbsp", "againKey", "quickDays",
    ]
    /// Were on the page; now always their default (all on), whatever an old file says.
    static let fixed = ["ghostWords", "guessGhosts", "guessShade", "earlyStart", "shortGhosts", "keepTyping", "typoHold",
                        "midLine", "fallbackAnchor"]
    /// The Cloud group's "Connect a model" panel: which way is connected, never a key.
    static let panel = ["connect"]
    /// Never on the page, before or after: state the app keeps (marks, last places, the picked model) and knobs only
    /// the file sets (models, limits, the typography combos). Unchanged by the settings round.
    static let hidden = [
        "actions_off", "adapter", "pickKey", "captureHintShown", "claudeModel", "clipImageMB", "cloudDefaults",
        "contextLevelAI", "contextLevelAgent", "deckAt", "fmt", "ghostLength", "ghostMaxWords", "ghostMinWords",
        "keysRound", "minGhost", "minGhostShort", "model", "predictKeys", "backOfficeCap", "quickMax", "quickSecret",
        "shotFolder", "shotLast", "skip", "switchFormat", "typoEngine", "typographyApostropheMark", "voiceCareful",
        "voiceFast", "voiceIdleMin", "journalDB",
    ]
    /// No code read them: gone from Settings. `screen` is still read once, as the old name of screenContext.
    /// The night batch, server training and the MCP adapter left the core on 26 November 2026: an old file's keys are ignored.
    static let removed = ["lookVariant", "voiceLive", "screen", "backOffice", "retrainRemote", "mcp"]
    /// Removed on 17 November 2026: Claude no longer works while the user types.
    static let removedTyping = ["claudeTyping", "claudePause", "proofread", "proofreadOff", "sentenceProof", "facts",
                                    "translate", "nextMessage"]
}
