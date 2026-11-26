import AppKit
import SwiftUI

/// Promises (2026-11-17, engine/promises.py): promises the user made while typing ("I'll send the deck tomorrow",
/// "завтра скину договір"). The window's Shortcuts page lists the open ones with Done and Drop.

/// The window's "Open promises" list (Shortcuts page): what · who or app · due, Done and Drop.
struct PromisesSection: View {
    var preview = false
    @State private var rows: [[String: Any]] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                PageCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            PageSectionHead(title: "Open Promises", glyph: "chat")
                            Text("\(rows.count)")
                                .font(NativeFont.mono(11)).foregroundStyle(UIInk.muted)
                                .padding(.horizontal, 7).frame(height: 19)
                                .background(Capsule().fill(UIInk.well))
                            Spacer()
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rows.indices, id: \.self) { i in
                                row(rows[i])
                                    .padding(.vertical, 6)
                                    .overlay(alignment: .top) {
                                        if i > 0 { Rectangle().fill(UIInk.line).frame(height: 0.5) }
                                    }
                            }
                        }
                    }
                }
            } else {
                // Zero-height anchor ensures .onAppear fires even before promises are fetched.
                Color.clear.frame(height: 0)
            }
        }
        .onAppear(perform: load)
    }

    private func row(_ r: [String: Any]) -> some View {
        let id = r["id"] as? String ?? ""
        let what = (r["what"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (r["phrase"] as? String ?? "")
        let who = (r["who"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (r["app"] as? String ?? "")
        let due = Date(timeIntervalSince1970: r["due"] as? Double ?? 0)
        let overdue = r["overdue"] as? Bool ?? false
        return HStack(spacing: 8) {
            Text(what).font(NativeFont.text(13, .medium)).foregroundStyle(UIInk.ink).lineLimit(1)
            if !who.isEmpty { Text("· " + who).font(NativeFont.text(12)).foregroundStyle(UIInk.muted).lineLimit(1) }
            Text("· " + PromisesSection.relative(due)).font(NativeFont.mono(11)).foregroundStyle(overdue ? UIInk.coral : UIInk.muted)
            Spacer()
            PagePillButton(title: "Done", glyph: "check", enabled: !preview) { act("/promises/done", id) }
            Button("Drop") { act("/promises/drop", id) }
                .buttonStyle(.plain)
                .font(NativeFont.text(12))
                .foregroundStyle(preview ? UIInk.faint : UIInk.muted)
                .padding(.horizontal, 6)
                .disabled(preview)
        }
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func act(_ path: String, _ id: String) {
        Engine.shared.post(path, ["id": id]) { _ in load() }
    }

    private func load() {
        if preview {
            rows = [["id": "p1", "what": "the deck", "who": "Alex", "due": Date().timeIntervalSince1970 + 3600, "overdue": false]]
            return
        }
        Engine.shared.get("/promises") { j in rows = (j?["promises"] as? [[String: Any]]) ?? [] }
    }
}
