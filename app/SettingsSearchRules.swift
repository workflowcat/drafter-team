// Settings search, category filtering, and Permissions & Health checklist rules.
// Pure Foundation only (no AppKit/SwiftUI), tested in tests/settings_search_rules.swift.
import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case all, typing, voice, calls, capture, cloud, look
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .typing: return "Typing"
        case .voice: return "Voice"
        case .calls: return "Calls"
        case .capture: return "Capture"
        case .cloud: return "Cloud"
        case .look: return "Look"
        }
    }
}

struct PermissionItem: Equatable, Identifiable {
    let id: String
    let title: String
    let ok: Bool
    let neededFor: String
    let actionLabel: String
    let settingsURL: String
    /// Missing and needed counts as needing attention; missing and optional is shown grey (cohesion round, 26 November 2026).
    var needed = true
}

enum SettingsSearchRules {
    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Multi-word case- and diacritic-insensitive match: every whitespace-separated word in `query` must appear in `title` or `extra`.
    static func matches(query: String, title: String, extra: String = "") -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let hay = fold(title + " " + extra)
        return fold(trimmed).split(whereSeparator: \.isWhitespace).allSatisfy { hay.contains($0) }
    }

    /// True when not searching, or at least one (title, extra) pair matches `query`.
    static func anyMatch(query: String, items: [(String, String)]) -> Bool {
        guard isSearching(query) else { return true }
        return items.contains { matches(query: query, title: $0.0, extra: $0.1) }
    }

    static func anyMatch(query: String, titles: [String]) -> Bool {
        guard isSearching(query) else { return true }
        return titles.contains { matches(query: query, title: $0) }
    }

    /// Whether a category section should show: searching always searches across every category.
    static func showCategory(_ section: SettingsCategory, selected: SettingsCategory, query: String) -> Bool {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return selected == .all || selected == section
    }

    /// Whether the Advanced section should be expanded: open when the user toggled it, searched, or picked a category.
    static func advancedOpen(toggled: Bool, selected: SettingsCategory, query: String) -> Bool {
        if toggled { return true }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return selected != .all && selected != .cloud
    }

    /// Unified macOS permissions and system-key checklist for Settings and the first-run window. One name per permission,
    /// as macOS shows it. Accessibility is always needed; the microphone when voice is on; screen recording when a feature
    /// that reads the screen is on; calendars are optional.
    static func permissions(accessibility: Bool, microphone: Bool = true, screenRecording: Bool, calendar: Bool,
                            voiceOn: Bool = false, screenUsed: Bool = true,
                            captureSystemKeyOn: Bool, captureEnabled: Bool) -> [PermissionItem] {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
        var out: [PermissionItem] = [
            PermissionItem(id: "accessibility", title: "Accessibility", ok: accessibility,
                           neededFor: "Grey text at the caret, Tab, keys and typing fixes. Quit and reopen Drafter after allowing it.",
                           actionLabel: "Open Accessibility", settingsURL: pane + "Accessibility"),
            PermissionItem(id: "microphone", title: "Microphone", ok: microphone,
                           neededFor: "Voice on Right Option, long notes and calls",
                           actionLabel: "Open Microphone", settingsURL: pane + "Microphone", needed: voiceOn),
            PermissionItem(id: "screen", title: "Screen & System Audio Recording", ok: screenRecording,
                           neededFor: "The other side of a call, screenshots while recording, and reading chats on screen",
                           actionLabel: "Open Screen Recording", settingsURL: pane + "ScreenCapture", needed: screenUsed),
            PermissionItem(id: "calendar", title: "Calendars", ok: calendar,
                           neededFor: "Meeting titles, free slots and the offer to take notes before a call",
                           actionLabel: "Open Calendars", settingsURL: pane + "Calendars", needed: false),
        ]
        if captureEnabled {
            out.append(PermissionItem(id: "captureKey", title: "macOS ⇧⌘5 shortcut", ok: !captureSystemKeyOn,
                                      neededFor: "Turn off macOS's own ⇧⌘5 so Drafter's quick capture receives it",
                                      actionLabel: "Open Keyboard Shortcuts", settingsURL: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
        }
        return out
    }

    static func attentionCount(_ items: [PermissionItem]) -> Int {
        items.reduce(0) { $0 + ($1.ok || !$1.needed ? 0 : 1) }
    }
}
