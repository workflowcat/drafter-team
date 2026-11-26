// Explicit export writes locally; Share notes only copies to the clipboard.
import AppKit
import SwiftUI

struct ObsidianActions: View {
    @EnvironmentObject var m: WindowModel
    let title: String
    let date: Date
    let markdown: String
    let brief: String
    @State private var saving = false
    @State private var notice = ""
    @State private var saved: URL?

    var body: some View {
        FlowRow(spacing: 8) {
            Button("Send to Obsidian", action: save)
                .disabled(m.settings.obsidianVault.isEmpty || saving)
                .help(m.settings.obsidianVault.isEmpty ? "Set an Obsidian vault in Settings" : "Save a new note in the vault's Drafter folder")
            Button("Share notes") {
                if !m.preview { History.copy(brief) }
                notice = m.preview ? "Sample brief copied" : "Brief copied"
            }.disabled(brief.isEmpty).help("Copy a brief to share")
            if let saved {
                Button("Show note") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
            }
            if !notice.isEmpty { Text(notice).font(NativeFont.text(11)).foregroundStyle(UIInk.muted) }
        }.controlSize(.small)
    }
    private func save() {
        guard !saving else { return }
        if m.preview { notice = "Sample export"; return }
        let vault = m.settings.obsidianVault
        saving = true; notice = "Saving…"; saved = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error>
            if let target = ObsidianExportRules.targetURL(vaultPath: vault, date: date, title: title) {
                result = ObsidianExportRules.writeAtomically(content: markdown, to: target)
            } else { result = .failure(ObsidianExportRules.ExportError.unsafePath) }
            DispatchQueue.main.async {
                saving = false
                switch result {
                case .success(let url):
                    saved = url; notice = "Saved to Obsidian"
                    Engine.shared.post("/sources/run", ["name": "obsidian"])
                case .failure(let error): notice = error.localizedDescription
                }
            }
        }
    }
}
