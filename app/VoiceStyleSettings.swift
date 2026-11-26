// Settings > Voice rows for the voice style round (17 November 2026): a style per app kind, an override per app, mail
// shape, chat lines, spoken snippets and the "Cleaned" note. Rules: app/VoiceStyleRules.swift, app/VoiceShapeRules.swift.
import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder var voiceStyleRows: some View {
        let s = m.settings
        let choices = VoiceStyle.allCases.map { ($0.rawValue, $0.label) }
        ForEach([("mail", "Style in mail"), ("chat", "Style in chats"), ("ai", "Style in AI apps"), ("other", "Style everywhere else")], id: \.0) { kind, title in
            lookRow(title, choices, s.voiceStyle[kind] ?? VoiceStyleRules.defaults[kind] ?? "formal",
                    "Formal: capitals and a full stop. Casual: no full stop at the end. Very casual: no capitals, no full stop") { v in
                m.save { $0.voiceStyle[kind] = v }
            }
        }
        ForEach(s.voiceStyleApps.keys.sorted(), id: \.self) { id in
            lookRow(NoteField.name(id), choices + [("", "Remove")], s.voiceStyleApps[id] ?? "formal", "This app's own voice style") { v in
                m.save { if v.isEmpty { $0.voiceStyleApps.removeValue(forKey: id) } else { $0.voiceStyleApps[id] = v } }
            }
        }
        if !SettingsSearchRules.isSearching(search) {
            line { AddStyleApp(taken: Set(s.voiceStyleApps.keys)) }
        }
        // the cleanup level (research item 3): per kind, then per app on the same app list as the style
        let levels = VoiceLevel.allCases.map { ($0.rawValue, $0.label) } + s.voiceModes.keys.sorted().map { ($0, $0) }
        let levelHelp = "Raw: as heard. Clean: fillers out, punctuation. Polished: the local model rewrites it as written text (a mode adds its prompt)"
        ForEach([("mail", "Cleanup in mail"), ("chat", "Cleanup in chats"), ("ai", "Cleanup in AI apps"), ("other", "Cleanup everywhere else")], id: \.0) { kind, title in
            lookRow(title, levels, s.voiceLevel[kind] ?? "clean", levelHelp) { v in m.save { $0.voiceLevel[kind] = v } }
        }
        ForEach(s.voiceStyleApps.keys.sorted(), id: \.self) { id in
            lookRow(NoteField.name(id) + " cleanup", levels + [("", "As its kind")], s.voiceLevelApps[id] ?? "", "This app's own cleanup level") { v in
                m.save { if v.isEmpty { $0.voiceLevelApps.removeValue(forKey: id) } else { $0.voiceLevelApps[id] = v } }
            }
        }
        ForEach(s.voiceModes.keys.sorted(), id: \.self) { name in
            if SettingsSearchRules.matches(query: search, title: name, extra: "voice mode " + (s.voiceModes[name] ?? "")) {
                line(gutter: name) { ModeField(name: name, initial: s.voiceModes[name] ?? "") }
            }
        }
        if !SettingsSearchRules.isSearching(search) {
            line { AddModeField(taken: Set(s.voiceModes.keys)) }
        }
        row("Mail: greeting, paragraphs, sign-off", s.voiceShape) { $0.voiceShape = $1 }
        row("Chats: one sentence per line", s.voiceChatLines) { $0.voiceChatLines = $1 }
        row("Say a shortcut's cue to put it in", s.voiceSnippets) { $0.voiceSnippets = $1 }
        row("Say what the clean-up removed", s.cleanNote) { $0.cleanNote = $1 }
    }
}

/// The app picker for a per-app voice style: the apps open now, by name.
struct AddStyleApp: View {
    @EnvironmentObject var m: WindowModel
    let taken: Set<String>
    var body: some View {
        SwiftUI.Menu("Add an app") {
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { a -> (String, String)? in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
                .filter { !taken.contains($0.0) && $0.0 != Home.bundleID }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            ForEach(apps, id: \.0) { a in
                Button(a.1) { m.save { $0.voiceStyleApps[a.0] = "casual" } }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().font(NativeFont.text(14)).padding(.leading, SettingsGrid.toggle)
    }
}

/// One of the user's voice modes: its prompt, saved on Return or when the user leaves the field; empty removes the mode.
struct ModeField: View {
    @EnvironmentObject var m: WindowModel
    let name: String
    let initial: String
    @State private var value = ""
    @FocusState private var focused: Bool
    func save() {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v != (m.settings.voiceModes[name] ?? "") else { return }
        m.save { if v.isEmpty { $0.voiceModes.removeValue(forKey: name) } else { $0.voiceModes = VoiceModeRules.tidy($0.voiceModes.merging([name: v]) { _, b in b }) } }
    }
    var body: some View {
        TextField("How takes sound in this mode (empty removes it)", text: $value)
            .textFieldStyle(.roundedBorder).font(NativeFont.text(14)).focused($focused).onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
            .padding(.trailing, SettingsGrid.cloud + 12)
            .onAppear { value = initial }
    }
}

/// A new voice mode: its name and prompt ("Email" / "formal, short paragraphs"); say "mode email" or pick it with `;`.
struct AddModeField: View {
    @EnvironmentObject var m: WindowModel
    let taken: Set<String>
    @State private var name = ""
    @State private var prompt = ""
    func add() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !p.isEmpty, !taken.contains(where: { $0.lowercased() == n.lowercased() }) else { return }
        m.save { $0.voiceModes = VoiceModeRules.tidy($0.voiceModes.merging([n: p]) { _, b in b }) }
        name = ""; prompt = ""
    }
    var body: some View {
        HStack(spacing: 8) {
            TextField("New mode", text: $name).textFieldStyle(.roundedBorder).font(NativeFont.text(14)).frame(width: 120)
            TextField("Its prompt, e.g. formal, short paragraphs", text: $prompt).textFieldStyle(.roundedBorder).font(NativeFont.text(14)).onSubmit(add)
            Button("Add", action: add).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.trailing, SettingsGrid.cloud + 12)
    }
}
