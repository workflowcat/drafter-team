// Settings > Sources (17 November 2026): what the engine reads from (mail, beeper, drive, ...). One row per source on
// the settings grid: the switch (POST /sources), the name (its note on hover), what it holds and when it was updated;
// one "Update now" for the group (POST /sources/run). While any source updates, the list is read again every 3 s.
// Rules: app/SourceRules.swift.
import AppKit
import SwiftUI

final class SourceList: ObservableObject {
    static let shared = SourceList()
    @Published var rows: [SourceRow] = []
    @Published var now = Date().timeIntervalSince1970
    private var polling = false

    /// Made-up sources for the preview.
    static let sample: [SourceRow] = {
        let t = Date().timeIntervalSince1970
        return [SourceRow(name: "mail", label: "Email (Gmail)", enabled: true, count: 1234, updated: t - 7200, error: "", running: false, note: "read-only"),
                SourceRow(name: "beeper", label: "Chats (Beeper)", enabled: true, count: 0, updated: 0, error: "", running: true, note: ""),
                SourceRow(name: "drive", label: "Google Drive", enabled: false, count: 0, updated: 0, error: "", running: false, note: "")]
    }()

    func refresh(preview: Bool) {
        guard !preview else { rows = Self.sample; return }
        Engine.shared.get("/sources", timeout: 3) { j in
            guard let j else { return }
            self.take(j)
        }
    }

    func set(_ r: SourceRow, on: Bool, preview: Bool) {
        guard !preview else { return }
        log("sources: \(r.name) \(on ? "on" : "off")")
        Engine.shared.post("/sources", ["name": r.name, "enabled": on], timeout: 5) { j in
            if let j { self.take(j) } else { self.refresh(preview: false) }
        }
    }

    func run(preview: Bool) {
        guard !preview else { return }
        log("sources: update now")
        Engine.shared.post("/sources/run", [:], timeout: 5) { _ in self.refresh(preview: false) }
    }

    private func take(_ j: [String: Any]) {
        rows = SourceRules.rows(j)
        now = Date().timeIntervalSince1970
        guard SourceRules.anyRunning(rows), !polling else { return }
        polling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.polling = false; self.refresh(preview: false) }
    }
}

/// Re-renders its content when the list changes (SettingsView's own body does not observe it).
struct SourcesView<C: View>: View {
    @ObservedObject var list = SourceList.shared
    let preview: Bool
    @ViewBuilder let content: (SourceList) -> C
    var body: some View { content(list).onAppear { SourceList.shared.refresh(preview: preview) } }
}

extension SettingsView {
    var sourceRows: some View {
        SourcesView(preview: m.preview) { list in
            let searching = SettingsSearchRules.isSearching(search)
            let matched = list.rows.filter { r in
                SettingsSearchRules.matches(query: search, title: r.label, extra: "\(r.name) sources \(r.note)")
            }
            let showUpdate = !searching || SettingsSearchRules.matches(query: search, title: "Update now", extra: "sources refresh")
            if !searching || !matched.isEmpty || showUpdate {
                group("Sources") {
                    ForEach(matched, id: \.name) { r in sourceLine(r, list) }
                    if showUpdate {
                        line {
                            Button { list.run(preview: m.preview) } label: {
                                HStack(spacing: 6) { Glyph("refresh", size: 14); Text("Update now").font(NativeFont.text(15)) }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(UIInk.muted)
                            .disabled(SourceRules.anyRunning(list.rows) || !list.rows.contains { $0.enabled })
                        }
                    }
                }
            }
        }
    }

    func sourceLine(_ r: SourceRow, _ list: SourceList) -> some View {
        line {
            HStack(spacing: 0) {
                Toggle(r.label, isOn: Binding(get: { r.enabled }, set: { v in list.set(r, on: v, preview: m.preview) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .frame(width: G.toggle, alignment: .leading)
                Text(r.label).font(NativeFont.text(16)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .help(r.note)
                Text(SourceRules.detail(r, now: list.now)).font(NativeFont.mono(13))
                    .foregroundStyle(!r.running && !r.error.isEmpty ? Color(nsColor: Native.crit) : UIInk.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.trailing, G.cloud + 12)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
