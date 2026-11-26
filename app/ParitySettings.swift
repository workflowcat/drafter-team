// Parity round (15 November 2026): Settings > Typing rows for the personal-style slider and the writing instructions
// (one for every app, one per app). Rules: app/ParityRules.swift. Laid out on the settings grid (TapeSettings.swift):
// SettingsView.parityRows puts these into `line {}` cells.
import AppKit
import SwiftUI

extension SettingsView {
    @ViewBuilder var parityRows: some View {
        let s = m.settings
        if SettingsSearchRules.matches(query: search, title: "Personal style", extra: "adapter lora layer strength") {
            line(gutter: "\(s.personalStrength)%") { StrengthSlider(initial: s.personalStrength) }
        }
        if SettingsSearchRules.matches(query: search, title: "Bolder Careful", extra: "suggestions threshold guess bar") {
            line(gutter: String(format: "%.2f", s.guessBar)) { BoldSlider(initial: s.guessBar) }
        }
        if SettingsSearchRules.matches(query: search, title: "All apps", extra: "writing instructions note how I write") {
            line(gutter: "All apps") { NoteField(bundle: nil, initial: s.writingNote) }
        }
        ForEach(s.appNotes.keys.sorted(), id: \.self) { id in
            let name = NoteField.name(id)
            if SettingsSearchRules.matches(query: search, title: name, extra: "\(id) writing instructions note") {
                line(gutter: name) { NoteField(bundle: id, initial: s.appNotes[id] ?? "") }
            }
        }
        if !SettingsSearchRules.isSearching(search) {
            line { AddNoteApp(taken: Set(s.appNotes.keys)) }
        }
    }
}

/// Personal style: 0-100 % of the user's trained layer. Sent once the slider is let go; the engine merges the layer again
/// (a few seconds, typing answers from the user's words meanwhile) and the time shows beside it.
struct StrengthSlider: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var cat = ModelCatalog.shared      // model catalog: a model without the user's layer has no style to scale
    let initial: Int
    @State private var value = 100.0
    @State private var status = ""
    var reason: String? { ModelPick.styleReason(layer: ModelPick.hasLayer(cat.rows, id: m.settings.typingModel)) }
    var body: some View {
        HStack(spacing: 12) {
            Text("Personal style").font(NativeFont.text(13)).lineLimit(1).frame(width: 150, alignment: .leading)
            Slider(value: $value, in: 0...100, step: 10) { editing in
                guard !editing else { return }
                let v = Strength.clamp(value)
                guard v != m.settings.personalStrength else { return }
                m.save { $0.personalStrength = v }
                status = "…"
                Engine.shared.post("/strength", ["value": v], timeout: 60) { j in
                    DispatchQueue.main.async {
                        status = (j?["seconds"] as? Double).map { String(format: "%.1f s", $0) } ?? "next start"
                        log("strength \(v)% \(status)")
                    }
                }
            }
            .accessibilityLabel("Personal style").accessibilityValue("\(Int(value)) percent")
            .disabled(reason != nil)
            Text(reason ?? status).font(NativeFont.mono(13)).foregroundStyle(UIInk.muted).frame(width: 80, alignment: .trailing)
        }
        .padding(.trailing, SettingsGrid.cloud + 12)
        .onAppear { value = Double(initial) }
    }
}

/// Bolder / Careful (more-bold round, 17 November 2026, the user: "a bit less sureness in the guesses and suggest
/// more"): the bar a guess must clear, 0.05 at Bolder to 0.35 at Careful (default 0.15, bench/guess_sweep.py). The
/// slider runs Bolder on the left, so its position is the bar turned around. Saved when let go; the next request sends it.
struct BoldSlider: View {
    @EnvironmentObject var m: WindowModel
    let initial: Double
    @State private var value = 0.25
    var body: some View {
        HStack(spacing: 12) {
            Text("Bolder").font(NativeFont.text(13)).lineLimit(1).frame(width: 150, alignment: .leading)
            Slider(value: $value, in: 0.05...0.35, step: 0.05) { editing in
                guard !editing else { return }
                let bar = GhostRules.boldBar(0.4 - value)
                guard bar != m.settings.guessBar else { return }
                m.save { $0.guessBar = bar }
                log("guessBar \(bar)")
            }
            .accessibilityLabel("Bolder or careful suggestions").accessibilityValue(String(format: "bar %.2f", GhostRules.boldBar(0.4 - value)))
            Text("Careful").font(NativeFont.text(13)).foregroundStyle(UIInk.muted).frame(width: 80, alignment: .trailing)
        }
        .padding(.trailing, SettingsGrid.cloud + 12)
        .onAppear { value = 0.4 - GhostRules.boldBar(initial) }
    }
}

/// One writing instruction: for every app (bundle nil) or for one app. Saved when the user presses Return or leaves the
/// field; an empty app instruction removes its row.
struct NoteField: View {
    @EnvironmentObject var m: WindowModel
    let bundle: String?
    let initial: String
    @State private var value = ""
    @FocusState private var focused: Bool
    static func name(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    func save() {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = bundle {
            guard v != (m.settings.appNotes[id] ?? "") || v.isEmpty else { return }
            m.save { if v.isEmpty { $0.appNotes.removeValue(forKey: id) } else { $0.appNotes[id] = v } }
        } else {
            guard v != m.settings.writingNote else { return }
            m.save { $0.writingNote = v }
        }
    }
    var body: some View {
        TextField(bundle == nil ? "How I write everywhere" : "How I write here", text: $value)
            .textFieldStyle(.roundedBorder).font(NativeFont.text(14)).focused($focused).onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
            .padding(.trailing, SettingsGrid.cloud + 12)
            .onAppear { value = initial.trimmingCharacters(in: .whitespaces) }
    }
}

/// The app picker for a new per-app instruction: the apps open now, by name.
struct AddNoteApp: View {
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
                Button(a.1) { m.save { $0.appNotes[a.0] = " " } }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().font(NativeFont.text(14))
    }
}
