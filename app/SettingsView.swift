// The Settings page (split out of Window.swift on 25 November 2026, review item 11).
import AppKit
import SwiftUI
import AVFoundation
import EventKit

/// The switches (⌘,), on the tape's grid: row(), group() and sub() draw them (TapeSettings.swift), so a new row is one
/// line here and takes the look by itself. What each part does and its keys are in Help.
struct SettingsView: View {
    @EnvironmentObject var m: WindowModel

    /// The call apps on this Mac, by name.
    static var callApps: [(id: String, name: String)] {
        CallWatch.apps.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return (id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
    }
    /// Made-up calendars for the preview.
    static let sampleCalendars: [(id: String, title: String, source: String)] = [
        ("c1", "Work", "alex@example.com"), ("c2", "Family", "alex@example.com"),
        ("c3", "Transferred from sam@example.org", "alex@example.com"), ("c4", "Transferred from kim@example.net", "alex@example.com")]

    /// The voice strip's look (setting `stripStyle`, 14 November 2026): two words, the chosen one on the soft lift, as
    /// the other word pickers. It applies from the next take; a strip on screen is put away.
    /// A typo fix: offered (Tab puts it in), put in by itself only when sure, or always put in. Three ways, as Settings
    /// keeps them (autocorrectMode offer, sure, replace); the old switch lost "sure".
    @ViewBuilder var typoModeRow: some View {
        if SettingsSearchRules.matches(query: search, title: "Typo fixes", extra: "offer put in when sure always replace autocorrect") {
            line {
                HStack(spacing: 0) {
                    Color.clear.frame(width: G.toggle, height: 1)
                    Text("Typo fixes").font(NativeFont.text(13))
                    Spacer()
                    SwiftUI.Picker("Typo fixes", selection: Binding(get: { m.settings.autocorrectMode }, set: { v in m.save { $0.autocorrectMode = v } })) {
                        Text("Offer").tag("offer"); Text("Put in when sure").tag("sure"); Text("Always put in").tag("replace")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Offer: → word at the caret, Tab puts it in · When sure: in by itself only when the ranking is sure · Always: in at once")
                    Color.clear.frame(width: G.cloud + 12, height: 1)
                }
            }
        }
    }
    @ViewBuilder var stripRow: some View {
        if SettingsSearchRules.matches(query: search, title: "Strip", extra: "voice strip style notch classic") {
            line {
                HStack(spacing: 0) {
                    Glyph("waves", size: 16).foregroundStyle(UIInk.muted).frame(width: G.toggle, alignment: .leading)
                    Text("Strip").font(NativeFont.text(13))
                    Spacer()
                    // the system's segmented control (native round: a hand-made one stood here)
                    SwiftUI.Picker("Strip style", selection: Binding(get: { m.settings.stripStyle }, set: { v in m.save { $0.stripStyle = v } })) {
                        ForEach(StripStyle.allCases, id: \.self) { s in Text(s.name).tag(s.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Color.clear.frame(width: G.cloud + 12, height: 1)
                }
            }
        }
    }
    /// The user's EventKit calendars, account by account.
    static func calendars() -> [(id: String, title: String, source: String)] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return Actions.store.calendars(for: .event)
            .map { ($0.calendarIdentifier, $0.title, $0.source?.title ?? "") }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// The Advanced section starts folded (settings round, 17 November 2026); the preview opens it for its picture.
    @State var advanced = false
    @State var search = ""
    @State var category: SettingsCategory = .all
    @State var permsOpen = false

    init(advanced: Bool = false) {
        _advanced = State(initialValue: advanced)
    }

    private var permItems: [PermissionItem] {
        let s = m.settings
        let ax = m.preview ? true : Focus.trusted()
        let scr = m.preview ? true : Screen.allowed
        let cal = m.preview ? true : EKEventStore.authorizationStatus(for: .event) == .fullAccess
        let sys5 = m.preview ? false : Capture.systemKeyOn
        return Welcome.permissions(s, preview: m.preview, accessibility: ax, screen: scr, calendar: cal, systemKey: sys5)
    }

    @ViewBuilder var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader("Settings", subtitle: "Look, typing, voice, calls, capture and cloud controls") {
                PageSearchField(placeholder: "Search settings", text: $search)
                    .frame(width: PageLayout.searchWidth)
            }
            HStack(spacing: 4) {
                ForEach(SettingsCategory.allCases) { c in
                    let on = category == c && search.trimmingCharacters(in: .whitespaces).isEmpty
                    Button { category = c; search = "" } label: {
                        Text(c.label).font(NativeFont.text(12, on ? .medium : .regular))
                            .foregroundStyle(on ? UIInk.ink : UIInk.muted)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(on ? UIInk.pick : .clear))
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
            permissionsStrip
        }.padding(.bottom, 14)
    }

    @ViewBuilder var permissionsStrip: some View {
        let items = permItems
        let attention = SettingsSearchRules.attentionCount(items)
        let expanded = permsOpen || attention > 0
        VStack(alignment: .leading, spacing: 6) {
            Button { permsOpen.toggle() } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: attention == 0 ? Native.ok : Native.warn)).frame(width: 7, height: 7)
                    Text(attention == 0 ? "All macOS permissions ready" : "\(attention) permission\(attention == 1 ? "" : "s") need attention")
                        .font(NativeFont.text(13, .medium)).foregroundStyle(UIInk.ink)
                    Spacer()
                    Glyph(expanded ? "chevron-down" : "chevron-right", size: 12).foregroundStyle(UIInk.faint)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.soft))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { p in
                        HStack(spacing: 10) {
                            Circle().fill(p.ok ? Color(nsColor: Native.ok) : p.needed ? Color(nsColor: Native.warn) : UIInk.faint).frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.title).font(NativeFont.text(13, .medium)).foregroundStyle(UIInk.ink)
                                Text(p.neededFor).font(NativeFont.text(11)).foregroundStyle(UIInk.muted)
                            }
                            Spacer()
                            if p.ok {
                                Text("Ready").font(NativeFont.mono(11)).foregroundStyle(UIInk.faint)
                            } else if let u = URL(string: p.settingsURL) {
                                Button(p.actionLabel) { NSWorkspace.shared.open(u) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .overlay(alignment: .bottom) { Rectangle().fill(UIInk.line).frame(height: 1) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.card))
                .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.line, lineWidth: 0.5) }
            }
        }
    }

    private func showCat(_ c: SettingsCategory) -> Bool {
        SettingsSearchRules.showCategory(c, selected: category, query: search)
    }

    private func anyMatch(_ titles: [String]) -> Bool {
        SettingsSearchRules.anyMatch(query: search, titles: titles)
    }

    private var typingHasMatch: Bool {
        anyMatch([
            "Suggestions while typing", "Fix typos", "Fix the wrong keyboard layout",
            "Typography as you type", "Keep typed history and learn from it"
        ])
    }

    private var voiceHasMatch: Bool {
        anyMatch(["Voice on Right Option", "Type into the field while I speak"])
    }

    private var callsHasMatch: Bool {
        anyMatch(["Screenshots while recording", "Screen video while recording"])
    }

    private var captureHasMatch: Bool {
        anyMatch([
            "Quick capture",
            "Clipboard on ⌘⇧V (hold; Space opens the full picker)",
            "Data folder", "Dictionary"
        ])
    }

    private var cloudHasMatch: Bool {
        anyMatch([
            "Connect a model cloud Claude Anthropic OpenAI",
            "The connected model tidies a voice take after it goes in: names, the chat on screen cloud",
            "⌥Tab reworks the selected text cloud Claude",
            "The connected model offers a rewrite when I pause cloud",
            "The connected model writes the call outline and summary cloud",
            "The connected model names the kind of a new name (the name only) cloud"
        ])
    }

    private var advTypingHasMatch: Bool {
        let s = m.settings
        var keys = [
            "Longer suggestions in AI apps", "Longer suggestions in chats",
            "Suggest my next message while the caret rests",
            "Fast model while I type fast, the bigger one in pauses",
            "Use what I just copied", "⌥1 ⌥2 ⌥3 pick another suggestion",
            "A last look at a chat message before I send it",
            "Three quick replies to their last message (yes, no, later)",
            "Mark what could be better while I edit",
            "Read the messages on screen, on this Mac only",
            "Typo fixes offer put in when sure always replace autocorrect",
            "Fix Ukrainian typos too", "Fix the word while I type it",
            "Backspace takes back the last Tab", "Esc twice pauses suggestions in a field",
            "Right ⌘ twice opens the ; picker (snippets, quick starts, people)",
            "Offer \"Pick parts\" after a long copy",
            "Show the first sure words at once, the rest grows in place",
            "Let the text model sleep after 30 idle minutes",
            "Mark names in AI apps; ⌥Tab attaches what I know about them",
            "Personal style adapter lora layer strength",
            "Bolder Careful suggestions threshold guess bar",
            "All apps writing instructions note how I write"
        ]
        if s.typography {
            keys += [
                "Dashes: -\u{200C}- to —", "A spaced hyphen to a spaced dash",
                ".\u{200C}.\u{200C}. to …", "Curly quotes", "Apostrophes",
                "Arrows: -\u{200C}> to →, <\u{200C}- to ←", "Signs: +\u{200C}- to ±, 3x4 to 3×4",
                "Symbols: (c) to ©", "A number and грн to ₴", "No line break after і в у з а о"
            ]
        }
        keys += s.appNotes.keys.map { "\(NoteField.name($0)) \($0) writing instructions note" }
        keys += ModelCatalog.shared.rows.map { "\($0.name) model \($0.id)" }
        return anyMatch(keys)
    }

    private var advTypographyHasMatch: Bool {
        anyMatch([
            "Dashes: -\u{200C}- to —", "A spaced hyphen to a spaced dash",
            ".\u{200C}.\u{200C}. to …", "Curly quotes", "Apostrophes",
            "Arrows: -\u{200C}> to →, <\u{200C}- to ←", "Signs: +\u{200C}- to ±, 3x4 to 3×4",
            "Symbols: (c) to ©", "A number and грн to ₴", "No line break after і в у з а о"
        ])
    }

    private var advVoiceCallsHasMatch: Bool {
        let s = m.settings
        let apps = SettingsView.callApps
        let cals = CalendarGroups.group(m.preview ? SettingsView.sampleCalendars : SettingsView.calendars())
        let sources = m.preview ? SourceList.sample : SourceList.shared.rows
        var keys = [
            "Keep the microphone ready",
            "Right Option twice puts the last take in again",
            "A chord for the last take again",
            "Show a recording window, small notch",
            "Lower other sounds while I speak",
            "Style in mail formal casual", "Style in chats formal casual",
            "Style in AI apps formal casual", "Style everywhere else formal casual",
            "Cleanup in mail raw clean polished", "Cleanup in chats raw clean polished",
            "Cleanup in AI apps raw clean polished", "Cleanup everywhere else raw clean polished",
            "Mail: greeting, paragraphs, sign-off", "Chats: one sentence per line",
            "Say a shortcut's cue to put it in", "Say what the clean-up removed",
            "Update now sources refresh", "Obsidian vault folder choose clear sources"
        ]
        keys += s.voiceStyleApps.keys.map { "\(NoteField.name($0)) cleanup voice style" }
        keys += s.voiceModes.map { "\($0.key) voice mode \($0.value)" }
        keys += apps.map(\.name)
        keys += cals.flatMap(\.rows).flatMap { [$0.name, "Meetings in " + $0.name] }
        keys += sources.map { "\($0.label) \($0.name) sources \($0.note)" }
        return anyMatch(keys)
    }

    @ViewBuilder private var obsidianRow: some View {
        if anyMatch(["Obsidian vault folder choose clear sources"]) {
            HStack(spacing: 10) {
                Glyph("folder", size: 14)
                Text("Obsidian").font(NativeFont.text(13))
                Text(m.settings.obsidianVault.isEmpty ? "Off" : URL(fileURLWithPath: m.settings.obsidianVault).lastPathComponent)
                    .font(NativeFont.text(13)).foregroundStyle(UIInk.muted).lineLimit(1)
                    .help(m.settings.obsidianVault)
                Spacer()
                Button("Choose folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false; panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
                    panel.prompt = "Choose vault"
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        guard ObsidianExportRules.targetURL(vaultPath: url.path, date: Date(), title: "note") != nil else {
                            m.status = "Choose a vault folder without symlinks."; return
                        }
                        m.save { $0.obsidianVault = url.path }
                        if !m.preview { Engine.shared.post("/sources/run", ["name": "obsidian"]) }
                    }
                }
                Button("Clear") { m.save { $0.obsidianVault = "" } }
                    .disabled(m.settings.obsidianVault.isEmpty)
            }.controlSize(.small).padding(.vertical, 4)
        }
    }

    private var advCaptureHasMatch: Bool {
        let s = m.settings
        var keys = [
            "A key of its own for the full picker",
            "⌘⇧V again swaps the paste for an older copy",
            "Forget copies after 30 days",
            "Keep copied pictures"
        ]
        if !s.switchKey.isEmpty { keys.append("Small quick list while ⌘⇧V is held (the old way)") }
        if !s.captureKey.isEmpty {
            keys += [
                "⌘⇧S starts the capture (apps lose Save As on it)",
                "A second capture key",
                "Talk while capturing"
            ]
        }
        return anyMatch(keys)
    }

    private var advLookHasMatch: Bool {
        anyMatch([
            "Strip voice strip style notch classic"
        ])
    }

    private var advancedHasMatch: Bool {
        (showCat(.typing) && advTypingHasMatch)
        || ((showCat(.voice) || showCat(.calls)) && advVoiceCallsHasMatch)
        || (showCat(.capture) && advCaptureHasMatch)
        || (showCat(.look) && advLookHasMatch)
    }

    private var anySettingsMatch: Bool {
        !SettingsSearchRules.isSearching(search)
        || (showCat(.typing) && typingHasMatch)
        || (showCat(.voice) && voiceHasMatch)
        || (showCat(.calls) && callsHasMatch)
        || (showCat(.capture) && captureHasMatch)
        || (showCat(.cloud) && cloudHasMatch)
        || advancedHasMatch
    }

    /// The main page (settings round, 17 November 2026; SettingsPlan in app/SettingsRules.swift): the look, at most 10
    /// everyday switches in Typing, Voice, Calls and Capture, every switch that sends text in Cloud, then Advanced folded.
    var body: some View {
        let s = m.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsHeader
                if !anySettingsMatch {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No settings match \"\(search.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                            .font(NativeFont.text(15, .medium)).foregroundStyle(UIInk.ink)
                        Text("Try another keyword or clear the search to browse by category.")
                            .font(NativeFont.text(13)).foregroundStyle(UIInk.muted)
                        Button("Clear search") { search = "" }
                            .buttonStyle(.plain)
                            .font(NativeFont.text(13, .medium)).foregroundStyle(UIInk.blue)
                    }
                    .padding(.vertical, 24).padding(.leading, G.gutter + G.gap)
                } else {
                    if showCat(.typing) && typingHasMatch {
                        group("Typing", column: "7 days · taken / shown") {
                            row("Suggestions while typing", !s.paused, stat: LogStats.suggest, typing: true) { $0.paused = !$1 }
                            row("Fix typos", s.autocorrect, stat: LogStats.typo, typing: true) { $0.autocorrect = $1 }
                            row("Fix the wrong keyboard layout", s.layoutFix, stat: LogStats.layout, typing: true) { $0.layoutFix = $1 }
                            row("Typography as you type", s.typography, typing: true) { $0.typography = $1 }
                            row("Keep typed history and learn from it", s.learn) { $0.learn = $1 }
                        }
                    }
                    if showCat(.voice) && voiceHasMatch {
                        group("Voice") {
                            row("Voice on Right Option", s.voice, value: m.stats.map { "\($0["takes"]?.shown ?? 0) today" }) { $0.voice = $1 }
                            row("Type into the field while I speak", s.voiceInsert == "live") { $0.voiceInsert = $1 ? "live" : "enter" }
                        }
                    }
                    if showCat(.calls) && callsHasMatch {
                        group("Calls") {
                            row("Screenshots while recording", s.shots) { $0.shots = $1 }
                            row("Screen video while recording", s.callScreenVideo) { $0.callScreenVideo = $1 }
                                .help("Saves lightweight, change-triggered screen.mp4 locally for Call Studio replay. Skips private and excluded apps.")
                        }
                    }
                    if showCat(.capture) && captureHasMatch {
                        group("Capture") {
                            // keys round two: ⌘⇧5 once macOS lets it go (ShotRules.keys); while macOS holds it, the one step
                            let sysOn = m.preview ? true : Capture.systemKeyOn
                            let inUse = ShotRules.keys(setting: s.captureKey, systemOn: sysOn, cmdShiftS: s.captureCmdShiftS, fallback: s.captureFallbackKey).first
                            row("Quick capture", !s.captureKey.isEmpty, value: inUse ?? (s.captureKey.isEmpty ? nil : "no key yet")) { $0.captureKey = $1 ? ShotRules.defaultKey : "" }
                            if ShotRules.showSystemStep(setting: s.captureKey, systemOn: sysOn),
                               SettingsSearchRules.matches(query: search, title: "Quick capture", extra: "⌘⇧5 screenshot") {
                                Text("For ⌘⇧5: " + ShotRules.systemPath + ".")
                                    .font(NativeFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                            }
                            // ⌘⇧V held is the clipboard (Space or a letter: the full picker)
                            row("Clipboard picker on ⇧⌘V", !s.switchKey.isEmpty, value: s.switchKey.isEmpty ? nil : s.switchKey) { $0.switchKey = $1 ? "⌘⇧V" : "" }
                            if SettingsSearchRules.matches(query: search, title: "Data folder Dictionary", extra: "open files") {
                                line {
                                    HStack(spacing: 16) {
                                        Button("Data folder") { NSWorkspace.shared.open(Home.data) }
                                        Button("Dictionary") { NSWorkspace.shared.open(Home.words) }
                                    }.buttonStyle(.plain).font(NativeFont.text(15)).foregroundStyle(UIInk.muted)
                                }
                            }
                        }
                    }
                    if showCat(.cloud) && cloudHasMatch { cloudGroup }
                    if advancedHasMatch { advancedSection }
                }
            }.padding(.horizontal, PageLayout.margin).padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { m.loadStats() }
    }

    /// Every switch that sends text off the Mac, each with its cloud mark, under the way the model is connected.
    var cloudGroup: some View {
        let s = m.settings
        return group("Cloud") {
            if !SettingsSearchRules.isSearching(search) || SettingsSearchRules.matches(query: search, title: "Connect a model", extra: "cloud Claude Anthropic OpenAI API key") {
                ConnectSection(m: m).padding(.leading, G.gutter + G.gap).padding(.bottom, 8)   // on the grid, under the heading
            }
            // after a Clean or Polished take went in (engine/voice_claude.py); its spend counts under the same cap
            row("The connected model tidies a voice take after it goes in: names, the chat on screen", s.voiceClaude, sends: true,
                value: s.voiceClaude ? String(format: "up to $%.2f a day", s.backOfficeCap) : nil) { $0.voiceClaude = $1 }
            row("⌥Tab reworks the selected text", s.rework, sends: true, stat: LogStats.rework, typing: true) { $0.rework = $1 }
            // a typing pause: Claude offers a rewrite of the paragraph as a chip (app/PauseRewrite.swift); same daily cap
            row("The connected model offers a rewrite when I pause", s.pauseRewrite, sends: true, typing: true,
                value: s.pauseRewrite ? String(format: "up to $%.2f a day", s.backOfficeCap) : nil) { $0.pauseRewrite = $1 }
            row("The connected model writes the call outline and summary", s.callNotes, sends: true) { $0.callNotes = $1 }
            row("The connected model names the kind of a new name (the name only)", s.entityClassify, sends: true) { $0.entityClassify = $1 }
        }
    }

    /// One folded section for the rest: finer typing choices, voice, calls, calendars, keys and the look of the journal.
    var advancedSection: some View {
        let s = m.settings
        let isOpen = SettingsSearchRules.advancedOpen(toggled: advanced, selected: category, query: search)
        return VStack(alignment: .leading, spacing: 0) {
            line(tall: true) {
                Button { advanced.toggle() } label: {
                    HStack(spacing: 14) {
                        Glyph(isOpen ? "chevron-down" : "chevron-right", size: 14).foregroundStyle(UIInk.muted)
                        Text("Advanced").font(NativeFont.text(15, .semibold)).lineLimit(1).fixedSize()
                        Rectangle().fill(UIInk.line).frame(height: 1)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Advanced").accessibilityValue(isOpen ? "open" : "folded")
            }
            if isOpen {
                if showCat(.typing) && advTypingHasMatch {
                sub("Typing")
                row("Longer suggestions in AI apps", s.longGhostsAI, typing: true) { $0.longGhostsAI = $1 }
                row("Longer suggestions in chats", s.longGhostsChats, typing: true) { $0.longGhostsChats = $1 }
                row("Suggest my next message while the caret rests", s.idleGhost, typing: true) { $0.idleGhost = $1 }
                row("Fast model while I type fast, the bigger one in pauses", s.comboModels, typing: true) { $0.comboModels = $1 }
                row("Use what I just copied", s.clipContext, typing: true) { $0.clipContext = $1 }
                row("⌥1 ⌥2 ⌥3 pick another suggestion", s.alternatives, typing: true) { $0.alternatives = $1 }
                row("A last look at a chat message before I send it", s.readerCheck, typing: true) { $0.readerCheck = $1 }
                row("Three quick replies to their last message (yes, no, later)", s.instantReplies, typing: true) { $0.instantReplies = $1 }
                row("Mark what could be better while I edit", s.editMarks, typing: true) { $0.editMarks = $1 }
                row("Read the messages on screen, on this Mac only", s.screenContext, typing: true, value: s.screenContext && !Screen.allowed ? "no access" : nil) { $0.screenContext = $1 }
                typoModeRow
                row("Fix Ukrainian typos too", s.autocorrectUk, typing: true) { $0.autocorrectUk = $1 }
                row("Fix the word while I type it", s.fixWord, stat: LogStats.fixWord, typing: true) { $0.fixWord = $1 }
                row("Backspace takes back the last Tab", s.tabBack, typing: true) { $0.tabBack = $1 }
                row("Esc twice pauses suggestions in a field", s.escPause, typing: true) { $0.escPause = $1 }
                row("Right ⌘ twice opens the ; picker (snippets, quick starts, people)", s.commandsKey) { $0.commandsKey = $1 }
                row("Offer \"Pick parts\" after a long copy", s.pickOffer, typing: true) { $0.pickOffer = $1 }
                row("Show the first sure words at once, the rest grows in place", s.streamGhost, typing: true) { $0.streamGhost = $1 }
                row("Let the text model sleep after 30 idle minutes", s.textIdleMin > 0, typing: true) { $0.textIdleMin = $1 ? 30 : 0 }
                row("Mark names in AI apps; ⌥Tab attaches what I know about them", s.contextPacks, typing: true) { $0.contextPacks = $1 }
                if s.typography && advTypographyHasMatch {
                    sub("Typography")
                    row("Dashes: -\u{200C}- to —", s.typographyDash) { $0.typographyDash = $1 }
                    row("A spaced hyphen to a spaced dash", s.typographySpacedDash) { $0.typographySpacedDash = $1 }
                    row(".\u{200C}.\u{200C}. to …", s.typographyEllipsis) { $0.typographyEllipsis = $1 }
                    row("Curly quotes", s.typographyQuotes) { $0.typographyQuotes = $1 }
                    row("Apostrophes", s.typographyApostrophe) { $0.typographyApostrophe = $1 }
                    row("Arrows: -\u{200C}> to →, <\u{200C}- to ←", s.typographyArrows) { $0.typographyArrows = $1 }
                    row("Signs: +\u{200C}- to ±, 3x4 to 3×4", s.typographyMath) { $0.typographyMath = $1 }
                    row("Symbols: (c) to ©", s.typographySymbols) { $0.typographySymbols = $1 }
                    row("A number and грн to ₴", s.typographyHryvnia) { $0.typographyHryvnia = $1 }
                    row("No line break after і в у з а о", s.typographyNbsp) { $0.typographyNbsp = $1 }
                }
                parityRows
                modelRows
                }
                if (showCat(.voice) || showCat(.calls)) && advVoiceCallsHasMatch {
                sub("Voice and calls")
                row("Keep the microphone ready", s.keepMic) { $0.keepMic = $1 }
                row("Right Option twice puts the last take in again", s.againTap) { $0.againTap = $1 }
                row("A chord for the last take again", !s.againKey.isEmpty, value: s.againKey.isEmpty ? nil : s.againKey) { $0.againKey = $1 ? "⌃⌥R" : "" }
                row("Show a recording window, small notch", s.recordWindow) { $0.recordWindow = $1 }
                voiceStyleRows
                row("Lower other sounds while I speak", s.duckAudio) { $0.duckAudio = $1 }
                let apps = SettingsView.callApps
                if !apps.isEmpty && anyMatch(apps.map(\.name)) { sub("Offer to record") }
                ForEach(apps, id: \.id) { a in
                    row(a.name, !s.callOff.contains(a.id)) { st, on in
                        st.callOff.removeAll { $0 == a.id }; if !on { st.callOff.append(a.id) }
                    }
                }
                // auto-record (17 November 2026): off everywhere until the user turns it on for an app or a calendar
                let cals = CalendarGroups.group(m.preview ? SettingsView.sampleCalendars : SettingsView.calendars()).flatMap(\.rows).filter { !s.calendarsOff.contains($0.id) }
                if (!apps.isEmpty || !cals.isEmpty) && anyMatch(apps.map(\.name) + cals.map { "Meetings in " + $0.name }) { sub("Record by itself, no offer") }
                ForEach(apps, id: \.id) { a in
                    row(a.name, s.autoRecordApps.contains(a.id)) { st, on in
                        st.autoRecordApps.removeAll { $0 == a.id }; if on { st.autoRecordApps.append(a.id) }
                    }
                }
                ForEach(cals, id: \.id) { c in
                    row("Meetings in " + c.name, s.autoRecordCalendars.contains(c.id)) { st, on in
                        st.autoRecordCalendars.removeAll { $0 == c.id }; if on { st.autoRecordCalendars.append(c.id) }
                    }
                }
                calendarRows
                sourceRows
                obsidianRow
                }
                if showCat(.capture) && advCaptureHasMatch {
                sub("Keys and capture")
                if !s.switchKey.isEmpty {
                    row("Small quick list while ⌘⇧V is held (the old way)", s.switchQuickForm) { $0.switchQuickForm = $1 }
                }
                row("A key of its own for the full picker", !s.quickKey.isEmpty, value: s.quickKey.isEmpty ? nil : s.quickKey) { $0.quickKey = $1 ? QuickRules.suggestedKey : "" }
                row("⌘⇧V again swaps the paste for an older copy", s.switchSwap) { $0.switchSwap = $1 }
                if !s.captureKey.isEmpty {
                    // ⌘⇧S is Save As / Duplicate in many apps and the tap takes it from all of them: off gives it back
                    row("⌘⇧S starts the capture (apps lose Save As on it)", s.captureCmdShiftS) { $0.captureCmdShiftS = $1 }
                    row("A second capture key", !s.captureFallbackKey.isEmpty, value: s.captureFallbackKey.isEmpty ? nil : s.captureFallbackKey) { $0.captureFallbackKey = $1 ? ShotRules.oldKey : "" }
                    row("Talk while capturing", s.captureTalk) { $0.captureTalk = $1 }
                }
                row("Forget copies after 30 days", s.quickDays > 0, value: s.quickDays > 0 ? "\(Int(s.quickDays)) days" : nil) { $0.quickDays = $1 ? 30 : 0 }
                row("Keep copied pictures", s.clipTotalMB > 0, value: s.clipTotalMB > 0 ? "\(s.clipTotalMB) MB" : nil) { $0.clipTotalMB = $1 ? 300 : 0 }
                }
                if showCat(.look) && advLookHasMatch {
                sub("Look")
                stripRow
                }
            }
        }
    }

    /// The user's calendars, account by account: the ones left out give no call names or free times.
    @ViewBuilder var calendarRows: some View {
        let s = m.settings
        let groups = CalendarGroups.group(m.preview ? SettingsView.sampleCalendars : SettingsView.calendars())
        let searching = SettingsSearchRules.isSearching(search)
        let matchingGroups = groups.compactMap { g -> (heading: String, rows: [(id: String, name: String)])? in
            let rows = g.rows.filter { SettingsSearchRules.matches(query: search, title: $0.name, extra: "\(g.heading) calendars") }
            return rows.isEmpty ? nil : (g.heading, rows)
        }
        if !searching || !matchingGroups.isEmpty {
            sub("Calendars")
            if groups.isEmpty && !searching {
                line {
                    Text("No calendar access: System Settings › Privacy › Calendars › Drafter.")
                        .font(NativeFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true).padding(.leading, G.toggle)
                }
            }
            ForEach(matchingGroups, id: \.heading) { g in
                sub(g.heading)
                ForEach(g.rows, id: \.id) { c in
                    row(c.name, !s.calendarsOff.contains(c.id)) { st, on in
                        st.calendarsOff.removeAll { $0 == c.id }; if !on { st.calendarsOff.append(c.id) }
                    }
                }
            }
        }
    }
}
