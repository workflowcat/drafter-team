// Drafter's settings: data/settings.json, also written by the engine's /settings (local tools) and engine/cloud.py.
import Foundation

// MARK: settings

struct Settings: Codable {
    var paused = false
    var skip: [String] = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.Terminal",
                          "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.dt.Xcode", "com.microsoft.VSCode",
                          "com.todesktop.230313mzl4w4u92", "com.apple.loginwindow", "com.apple.systempreferences",
                          "com.apple.ScreenSharing", Home.bundleID]
    var model: String? = nil
    var stripStyle = "composer"      // the voice strip's look (app/Pill.swift): composer, or classic (the old one row) (2026-11-14)
    var actions_off: [String] = []
    var voice = false          // Right Option = voice (menu or /settings)
    var voiceFast: String? = nil     // model ID or local path; read on next voice process start
    var voiceCareful: String? = nil  // preserve model choices when any app setting is saved
    /// How a voice note reaches the field (app/VoiceFlowRules.swift, 14 November 2026): "enter" (default) the words show
    /// in the strip and ↩ puts the whole final text in; "live" they are typed into the field while he speaks.
    var voiceInsert = "enter"
    /// Voice style per app (17 November 2026, app/VoiceStyleRules.swift): an app kind (mail, chat, ai, other) or a bundle id
    /// -> "formal", "casual" or "veryCasual". Shape (app/VoiceShapeRules.swift): mail gets a greeting line, paragraphs and a
    /// sign-off; chat lines stay off (a new line in a chat can send it). Spoken snippets (app/SpokenSnippetRules.swift).
    var voiceStyle: [String: String] = ["mail": "formal", "chat": "casual", "ai": "casual", "other": "formal"]
    var voiceStyleApps: [String: String] = [:]
    /// Voice cleanup level (research item 3, app/VoiceModeRules.swift): per app kind and per app, "raw", "clean",
    /// "polished" or one of his mode names; none = Clean. `voiceModes`: his named modes, name -> prompt.
    var voiceLevel: [String: String] = [:]
    var voiceLevelApps: [String: String] = [:]
    var voiceModes: [String: String] = [:]
    var voiceShape = true
    var voiceChatLines = false
    var voiceSnippets = true
    var cleanNote = true       // "Cleaned: 2 fillers · 1 correction" under an armed draft
    var adapter: String? = nil // LoRA trained on his writing (data/adapters), loaded on top of the model
    var fmt: String? = nil     // prompt shape: raw (default) or bare (no examples up front, for the trained model)
    var learn = true           // keep lines he sends (Return) in data/typed.jsonl for the phrase memory, local only
    /// The messages on screen above the field as context for suggestions (app/ScreenContext.swift): Accessibility text
    /// where it is clean, else a picture read on this Mac (Screen Recording); never stored, never sent. An old file's
    /// `screen` (its name before 14 November 2026) is read when this key is missing.
    var screenContext = true
    /// Lower the Mac's other sounds (music, video) to 30% while a voice take records, back after it (app/Duck.swift,
    /// rules app/DuckRules.swift, 17 November 2026). Never during a long note, a call, or while another app holds a call.
    var duckAudio = true
    var keepMic = false        // keep the microphone running between takes: the take starts 0.6 s before the press (orange dot stays on)
    /// Instant replies (17 November 2026, engine/instant.py): an empty chat or mail box whose last message is theirs shows
    /// three one-line replies (yes, no, later or a question) from the local model; ⌥1-3 or Tab put one in. Nothing leaves the Mac.
    var instantReplies = true
    var shots = true           // screenshots while a long note or call records, for brief.md (Screen Recording, local only)
    var callScreenVideo = false // opt-in local screen.mp4 for Call Studio; absent keys keep false through Settings.decode
    var recordWindow = true    // a long note or call opens the recording window (app/RecordWindow.swift) and the notch shrinks to a dot and the time (17 November 2026)
    /// The daily Claude cap, USD a day, for the voice cleanup and the pause rewrite (one ledger,
    /// data/backoffice/spend.json, engine/voice_claude.py). The name is older than the features that use it.
    var backOfficeCap = 0.5
    /// The pause rewrite (17 November 2026, app/PauseRewrite.swift, engine/pause_rewrite.py): after a typing pause in a
    /// field with a finished sentence, Claude Haiku rewrites the paragraph before the caret through the ⌥Tab rework path
    /// and a chip shows it with the changed words marked; Tab puts it in, Backspace right after takes it back. Sends the
    /// paragraph and the rework context when it fires; under backOfficeCap. Off by default, with the cloud mark.
    var pauseRewrite = false
    /// Claude cleans a Clean or Polished voice take after Parakeet's text went in (engine/voice_claude.py, 17 November
    /// 2026): names, the chat on screen, his style; swapped in place only if he has not typed since, ⌫ puts Parakeet's
    /// text back. Raw never goes. Offline or over 2.5 s: Parakeet's text stays. Spend under backOfficeCap.
    var voiceClaude = false
    var callNotes = false      // a call or long note: Claude Haiku writes the live outline and the call summary from the transcript text; off = the local model (engine/cloud.py)
    var autocorrect = true     // fix typos when a word ends (macOS spellchecker + his own words; Backspace takes it back)
    var autocorrectMode = "offer" // "offer": a fix found at a word end shows as "→ word" and Tab puts it in; "replace": put in at once (before 13 November 2026); "sure": the ranked fix goes in by itself only when its gate is sure, else offered
    var typoEngine = "ranked"  // "ranked" (15 November 2026: his words, a keyboard error model, context and a learned gate, app/TypoEngine.swift) or "system" (macOS's correction only)
    var autocorrectUk = false  // Ukrainian typos too (off: the Ukrainian dictionary misses many real forms)
    var layoutFix = true       // a word typed in the wrong layout (ghbdsn -> привіт) is fixed and the keyboard switches; double Shift by hand
    var claudeModel = "sonnet" // the Claude model rework asks: sonnet or haiku (haiku answers ~0.5 s sooner)
    // Removed 2026-11-17 (Claude out of the live typing path): claudeTyping, claudePause, proofread, proofreadOff,
    // sentenceProof, facts, translate, nextMessage. An old file that holds them still decodes: unknown keys are skipped.
    /// Reader check before sending (roadmap item 4, an experiment, 2026-11-17): in a chat box, once the message looks
    /// finished, a local last look (engine/reader.py: slips, a question of theirs left open) as one chip; Tab takes it,
    /// any other key drops it. Never holds Enter, nothing leaves the Mac. Off by default.
    var readerCheck = false
    /// Edit mode (roadmap item 8, 17 November 2026, app/EditMarks.swift): on a selection or while he edits a field, side
    /// marks where the text could improve (engine/marks.py), Tab applies, Esc dismisses; ⌥⇧Tab his-style rewrite by the
    /// local model. Local only.
    var editMarks = true
    var rework = false         // ⌥Tab on a selection: shorter, fix, clearer, warmer, formal, list, translate or his own words (app/Rework.swift)
    var fixWord = true         // the word being typed is no word he writes but one is a letter or a layout away: "→ word" at the caret, Tab swaps it (app/Fixer.swift)
    let typoHold = true  /* fixed, SettingsPlan.fixed */        // no grey text while the word just typed is a suspected typo, until it is fixed or he types past the next word (TypoHold, 15 November 2026)
    // parity round (15 November 2026, app/ParityRules.swift)
    var clipContext = true     // a copy from the last 2 minutes goes into the ghost's prompt (never secrets, password managers, skipped apps)
    var writingNote = ""       // his writing instruction for every app (engine prompt "notes"); "" = none
    var appNotes: [String: String] = [:]   // bundle id -> his writing instruction for that app
    var personalStrength = 100 // 0-100 %: how much of his trained layer the ghosts use (engine /strength re-merges it)
    var guessBar = 0.15        // Bolder / Careful (more-bold round, 17 November 2026): the guesses' bar, 0.05-0.35; engine gatecore.guess_bar
    var typingModel = "live"   // Settings > Typing > Model: a catalog id (engine/catalog.json); saved only after the engine switched to it
    var alternatives = false   // ⌥1 ⌥2 ⌥3 on a ghost: the main idea or one of two others, a quiet "1/3" after the grey words (off since keys round three: ⌥ digits type characters)
    var minGhost = 5           // grey text that adds fewer letters is not shown (2026-11-13: under 5 he took 3%); 0 = all
    var predictKeys = true     // ask for a suggestion at the key itself for the field + that letter (no 35 ms wait, 2026-11-13)
    var streamGhost = true     // two-step ghost: the first sure words at once, the rest grows in place (round two)
    var longGhostsAI = true    // a lighter tail of up to 8 words after the sure words in AI apps (round two)
    var longGhostsChats = false  // the same in chats and everywhere else
    /// How far a ghost runs after the gate's first word (long round, 14 November 2026): "word" (round five's few words),
    /// "phrase" (to a comma, 6 words), "sentence" (to the sentence end while the running chance holds; default).
    var ghostLength = "sentence"
    /// Earlier round (2026-11-16, Andrii: "lets do 3-5 words and lessen the confidence"): outside "word" length the
    /// ghost shows at least `ghostMinWords` words when the model has them and at most `ghostMaxWords`; only a sentence
    /// end or a line break ends it sooner (engine gatecore "words" run). Off = `ghostLength` as before.
    let ghostWords = true   // fixed (settings round, SettingsPlan.fixed)
    var ghostMinWords = 3, ghostMaxWords = 5
    /// The lower gate (earlier round): a first word the gate scores a little under its bar still shows, as a guess;
    /// `guessShade` draws the whole guess lighter. Tab takes either. The bar per model is in engine/server.py GUESS.
    let guessGhosts = true   // fixed (settings round, SettingsPlan.fixed)
    let guessShade = true   // fixed (settings round, SettingsPlan.fixed)
    /// Earlier round step 2: ghosts of `minGhostShort` letters or more (in place of `minGhost`, which his settings
    /// file holds at 5), and a request still running when he types a few more letters runs on (engine keep_on).
    /// Earlier round step 6: the guesses' bar one notch lower (0.25) and lower still right after a space (0.2),
    /// engine gatecore.early_bar. Only with guessGhosts.
    let earlyStart = true   // fixed (settings round, SettingsPlan.fixed)
    /// Step 7, the idle ghost (Andrii: "start predicting and suggesting the next message even when the cursor is just
    /// blinking"): the caret rests in a chat or AI box, empty or after a finished sentence, and the local model drafts
    /// his next message from the screen above the field and his earlier lines there. Nothing leaves the Mac.
    var idleGhost = true
    let shortGhosts = true   // fixed (settings round, SettingsPlan.fixed)
    var minGhostShort = 3
    let keepTyping = true   // fixed (settings round, SettingsPlan.fixed)
    /// Cadence round (2026-11-17, docs/rounds/2026-11-17-cadence.md): with a bigger typing model picked, the live 1.7B
    /// stays loaded beside it and answers while he types fast (a gap under 120 ms), the bigger one in longer gaps.
    var comboModels = false
    var callOff: [String] = ["notion.id"]   // call apps that never get a record offer (Notion: its own meeting notes hold the mic)
    var autoRecordApps: [String] = []       // call apps whose calls record by themselves, no offer (17 November 2026, off for all by default)
    var autoRecordCalendars: [String] = []  // calendars whose meetings record by themselves when a call starts in them
    var calendarsOff: [String] = []         // EventKit calendars left out of call names and free times (other tools' calendars)
    var voiceIdleMin = 30      // Parakeet is dropped after this many minutes without a take (read at voice start; was 4 h until 2026-11-14)
    var textIdleMin = 30       // the text model sleeps after this many minutes without typing, wakes when a field gets focus; 0 = never (2026-11-14)
    var quickKey = QuickRules.defaultKey    // the full picker's own global key (app/Quick.swift); "" = off (the default since 17 November: ⌘⇧V held, then Space); never ⌃⌥Space or ⌘Space (reserved)
    var quickMax = 1000, quickDays = 30.0   // clipboard history: at most this many rows, none older (0 days = no age limit)
    var quickSecret = QuickRules.defaultSecrets   // patterns of copies never kept: API keys, card numbers, one-time codes
    var switchQuickForm = false   // ⌘⇧V held shows the small quick form (before 17 November); off: ⌘⇧V opens the full picker
    var switchKey = "⌘⇧V", switchFormat = false   // the paste switcher (app/Quick.swift); false: it puts plain text in
    var clipImageMB = 8, clipTotalMB = 300   // copied pictures kept in data/clips/: each at most, all together at most (0 = none kept)
    var captureKey = ShotRules.defaultKey     // quick capture (app/Capture.swift): ⌘⇧5, works once macOS lets it go; "" = off
    var captureFallbackKey = ""               // a second capture key beside it (e.g. "⌃⌥S"); "" = none (keys round two)
    var captureHintShown = false              // the one-time "turn off macOS's ⌘⇧5" hint was shown
    var captureCmdShiftS = false              // ⌘⇧S starts the capture too (apps' Save As / Duplicate then never get it); off since 17 November
    var shotLast = ""                         // the last send-to target of a screenshot (ShotTarget raw value), first in the ⇥ list
    var shotFolder = ""                       // "File" saves screenshots here; "" = ~/Desktop
    var captureTalk = true                    // the capture deck: the mic starts with each shot, what he says is that card's caption
    var deckAt = ""                           // the capture deck's place after he dragged it ("x,y" of its bottom-left, AppKit points); "" = bottom centre
    // keys round (14 November 2026, app/KeyRules.swift)
    let midLine = true  /* fixed, SettingsPlan.fixed */         // a ghost with text after the caret on its line, on a small card under the line (2026-11-15; on since the fim round measured it)
    let fallbackAnchor = true  /* fixed, SettingsPlan.fixed */  // a field with no caret rect (web editors): the ghost at an estimated place, else on a chip near the field (2026-11-17)
    var tabBack = true         // Backspace right after Tab takes that Tab's words out and shows the grey text again
    var pickOffer = true       // after a long copy, the strip offers "Pick parts"
    var pickKey = "⌃⌥P"        // Pick parts on the clipboard from anywhere (KeyMap "pick"); "" = off; never another of Drafter's global chords
    var escPause = true        // Esc twice in a field with a ghost pauses ghosts there for 10 minutes; twice again resumes
    var againKey = ""          // a chord for the last voice take again (app/Quick.swift), e.g. "⌃⌥R"; "" = off (the default since 17 November)
    var commandsKey = true     // Right ⌘ twice opens the one `;` picker (app/Commands.swift, KeyMap "commands")
    var againTap = true        // double tap of Right Option: the last voice take in again at the caret (KeyRules.AgainTap)
    var keysRound = 3          // keys rounds two and three (17 November 2026) applied to his saved keys (Settings.migrateKeys)
    var switchSwap = false     // ⌘⇧V again within 2 s of a switcher paste swaps it for the next older copy (opt-in since keys round three)
    // typography as you type (15 November 2026, app/TypoGraphRules.swift, app/Typography.swift): the master switch, then one per combo
    var typography = true
    var typographyDash = true, typographySpacedDash = true, typographyEllipsis = true, typographyQuotes = true
    var typographyApostrophe = true
    var typographyApostropheMark = "ʼ"   // "ʼ" (U+02BC) or "’" (U+2019)
    var typographyArrows = true, typographyMath = true, typographySymbols = true
    var typographyHryvnia = false, typographyNbsp = false
    var entityClassify = false // a kind for a name no source knows: Claude Haiku gets the name only (engine/entities.py); off = local model or nothing
    var contextPacks = true    // in AI apps a name he types or says gets a quiet mark, ⌥Tab attaches its context pack (app/Entities.swift)
    var contextLevelAI = 2, contextLevelAgent = 3   // default pack level: 1 name, 2 one line, 3 full (chat assistants, coding agents)
    // the journal window (second window round, 14 November 2026, app/TapeWindow.swift)
    var tapeDensity = "compact"   // "compact": 28 pt rows; "comfortable": 36 pt
    var journalFold = "older"     // sessions folded at start: "older" (today's open), "none", "all"
    // soft and gallery round (14 November 2026): cards or rows, the soft or the old look of rows, the card size
    var journalView = "gallery"   // "gallery": cards; "list": rows
    var journalLook = "soft"      // the list's rows: "soft" (three zones) or "grid" (the old columns)
    var cardSize = 1              // 0 small, 1 medium, 2 large (⌘- ⌘+)
    var obsidianVault = ""        // opt-in local Markdown source and export folder
    /// The journal window reads typed, takes and clipboard rows from data/journal.sqlite (journal in SQLite, phase 1,
    /// 23 November 2026, app/JournalDB.swift, engine/journal_db.py; engine/ask.py's takes too); off = the JSONL files.
    var journalDB = true

    init() {}

    /// The file's keys over today's defaults. A key with a value of the wrong type keeps its default alone, so a file
    /// written by the engine or an older Drafter still loads; a new property needs no line here. Keys no property has
    /// (SettingsPlan.removed, .fixed, .removedTyping) are ignored, except `screen`, screenContext's old name.
    /// `cloudDefaults` is never read back: the migration mark, always "off".
    static func decode(_ data: Data) -> Settings? {
        guard let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any] else { return nil }
        func settings(_ j: [String: Any]) -> Settings? {
            guard let d = try? JSONSerialization.data(withJSONObject: j) else { return nil }
            return try? JSONDecoder().decode(Settings.self, from: d)
        }
        var merged = base
        if let old = file["screen"] as? Bool { merged["screenContext"] = old }
        let keys = file.keys.filter { $0 != "cloudDefaults" && $0 != "screen" }.sorted()
        var all = merged; for k in keys { all[k] = file[k] }
        if let s = settings(all) { return s.normalized() }
        for k in keys {   // one value has the wrong type: take the keys one by one
            var trial = merged; trial[k] = file[k]
            if settings(trial) != nil { merged = trial }
        }
        return settings(merged)?.normalized()
    }

    /// The ranges and the allowed words of the settings that have them; anything else is that setting's default.
    func normalized() -> Settings {
        var s = self; let z = Settings()
        func one(_ x: String, _ allowed: [String], _ fallback: String) -> String { allowed.contains(x) || x == fallback ? x : fallback }
        s.stripStyle = one(s.stripStyle, ["classic"], z.stripStyle)   // as StripStyle.of
        s.voiceInsert = one(s.voiceInsert, ["live"], z.voiceInsert)
        s.voiceStyle = z.voiceStyle.merging(s.voiceStyle) { _, b in b }
        s.autocorrectMode = one(s.autocorrectMode, ["replace", "sure"], z.autocorrectMode)
        s.typoEngine = one(s.typoEngine, ["system"], z.typoEngine)
        s.ghostLength = one(s.ghostLength, ["word", "phrase"], z.ghostLength)   // same rule as GhostRules.lengthMode; kept here so Settings decodes alone
        s.typographyApostropheMark = one(s.typographyApostropheMark, ["’"], z.typographyApostropheMark)
        s.tapeDensity = one(s.tapeDensity, ["comfortable"], z.tapeDensity)
        s.journalFold = one(s.journalFold, ["none", "all"], z.journalFold)
        s.journalView = one(s.journalView, ["list"], z.journalView)
        s.journalLook = one(s.journalLook, ["grid"], z.journalLook)
        s.personalStrength = min(100, max(0, s.personalStrength))
        s.guessBar = min(0.35, max(0.05, s.guessBar))
        s.minGhostShort = max(0, s.minGhostShort)
        s.ghostMinWords = min(5, max(1, s.ghostMinWords)); s.ghostMaxWords = min(8, max(s.ghostMinWords, s.ghostMaxWords))
        s.contextLevelAI = min(3, max(1, s.contextLevelAI)); s.contextLevelAgent = min(3, max(1, s.contextLevelAgent))
        s.cardSize = max(0, min(2, s.cardSize))
        s.cloudDefaults = z.cloudDefaults
        return s
    }
    /// Claude switches (engine/cloud.py) are off for a new install since 2026-11-14. Once, before decoding, a file
    /// written earlier gets today's effective value (on) of each one it does not name, and the mark; cloud.migrate()
    /// in the engine does the same, whichever runs first.
    /// Trimmed 2026-11-17 to the switches that still exist (engine/cloud.py DEFAULTS); an old file's removed keys are
    /// left as they are and never read.
    static let cloudKeys = ["rework", "callNotes", "entityClassify", "voiceClaude", "pauseRewrite"]
    static let neverOn: Set<String> = ["entityClassify", "voiceClaude", "pauseRewrite"]   // new that day, never on before: stays off (engine/cloud.py NEVER_ON)
    var cloudDefaults = "off"
    /// "Connect a model" (app/Connect.swift, engine/provider.py): which way is connected, never a key. Empty = local only.
    struct Connection: Codable, Equatable {
        var provider = ""                       // "", "cli", "anthropic", "openai"
        var fastModel = "claude-haiku-5-5"      // the fast helpers on the Anthropic path
        var carefulModel = "claude-sonnet-5-5"  // rework on the Anthropic path
        var baseURL = ""                        // an OpenAI-compatible endpoint (or a stand-in Anthropic URL)
        var apiModel = ""                       // the model name at that endpoint
        var connected: Bool { !provider.isEmpty }
        init() {}
        init(from d: Decoder) throws {   // a missing key keeps its default ({"provider": "cli"} from the migration)
            let c = try d.container(keyedBy: CodingKeys.self), z = Connection()
            provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? nil ?? z.provider
            fastModel = (try? c.decodeIfPresent(String.self, forKey: .fastModel)) ?? nil ?? z.fastModel
            carefulModel = (try? c.decodeIfPresent(String.self, forKey: .carefulModel)) ?? nil ?? z.carefulModel
            baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? nil ?? z.baseURL
            apiModel = (try? c.decodeIfPresent(String.self, forKey: .apiModel)) ?? nil ?? z.apiModel
        }
    }
    var connect = Connection()
    static func migrateCloud() {
        guard let d = try? Data(contentsOf: Home.settings),
              var j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], j["cloudDefaults"] == nil else { return }
        for k in cloudKeys where j[k] == nil { j[k] = !neverOn.contains(k) }
        if j["connect"] == nil { j["connect"] = ["provider": "cli"] }   // the signed-in CLI was the one way before
        j["cloudDefaults"] = "off"
        if let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: Home.settings, options: .atomic)
        }
    }
    /// Keys rounds two and three (17 November 2026): a settings file saved before them gets the new defaults
    /// (KeyRules.keysRoundThree, which runs round two first for a file without the mark); his own keys stay.
    static func migrateKeys() {
        guard let d = try? Data(contentsOf: Home.settings),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], ((j["keysRound"] as? Int) ?? 0) < 3 else { return }
        if let out = try? JSONSerialization.data(withJSONObject: KeyRules.keysRoundThree(j), options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: Home.settings, options: .atomic)
        }
    }
    static func load() -> Settings {
        migrateCloud(); migrateKeys()
        guard let d = try? Data(contentsOf: Home.settings), let s = decode(d) else { return Settings() }
        return s
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Home.settings, options: .atomic)
    }
}
