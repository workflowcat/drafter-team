// Model catalog (Cotypist parity round 2, 15 November 2026): Settings > Typing > Model. One row per catalog model on
// the settings grid: size on disk in the gutter, the pick mark, the name (a sparkle on the one recommended for this
// Mac, its reason on hover), a speed mark and a quality mark, then download / progress and cancel / loading.
// The engine does the work (GET /models, POST /model, /models/download, /models/cancel); rules: ModelPickRules.swift.
// A download starts only from the user's press here; "typingModel" is saved only after the engine says it switched.
import AppKit
import SwiftUI

final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()
    @Published var rows: [ModelRow] = []
    @Published var switching: String?
    @Published var failed: String?
    @Published var why = ""
    private var polling = false

    func refresh() {
        Engine.shared.get("/models", timeout: 3) { j in
            guard let j else { return }
            self.rows = ModelPick.rows(j)
            self.why = j["why"] as? String ?? ""
            self.pollLater()
        }
    }

    private func pollLater() {
        guard ModelPick.keepPolling(rows, switching: switching), !polling else { return }
        polling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.polling = false; self.refresh() }
    }

    func press(_ r: ModelRow, save: @escaping (String) -> Void) {
        switch ModelPick.action(r, switching: switching) {
        case .pick:
            switching = r.id; failed = nil
            log("model: switch to \(r.id) asked")
            Engine.shared.post("/model", ["id": r.id], timeout: 300) { j in
                self.switching = nil
                let cur = j?["current"] as? String
                if let cur { save(cur) }                       // live after a failed load: the setting says so too
                if j?["ok"] as? Bool != true { self.failed = r.id }
                log("model: now \(cur ?? "unknown")" + ((j?["seconds"] as? Double).map { String(format: ", %.1f s", $0) } ?? "")
                    + ((j?["error"] as? String).map { ", \($0)" } ?? ""))
                self.refresh()
            }
            refresh()
        case .download:
            log("model: download \(r.id) asked")
            Engine.shared.post("/models/download", ["id": r.id], timeout: 5) { _ in self.refresh() }
        case .cancel:
            Engine.shared.post("/models/cancel", ["id": r.id], timeout: 10) { _ in self.refresh() }
        case .none, .loading:
            break
        }
    }
}

/// Re-renders its content when the catalog changes (SettingsView's own body does not observe it).
struct CatalogView<C: View>: View {
    @ObservedObject var cat = ModelCatalog.shared
    @ViewBuilder let content: (ModelCatalog) -> C
    var body: some View { content(cat).onAppear { ModelCatalog.shared.refresh() } }
}

/// A 1-3 mark: three small cells, lit up to `n`, after its glyph.
struct ThreeMark: View {
    let glyph: String
    let n: Int
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Glyph(glyph, size: 12).foregroundStyle(UIInk.faint)
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in RoundedRectangle(cornerRadius: 1.5).fill(i < n ? UIInk.ink : UIInk.soft).frame(width: 5, height: 12) }
            }
        }
        .accessibilityElement().accessibilityLabel("\(label) \(n) of 3")
    }
}

extension SettingsView {
    @ViewBuilder var modelRows: some View {
        CatalogView { cat in
            let searching = SettingsSearchRules.isSearching(search)
            let matched = cat.rows.filter { r in
                SettingsSearchRules.matches(query: search, title: r.name, extra: "model \(r.id)")
            }
            if !searching || !matched.isEmpty {
                sub("Model")
                ForEach(matched, id: \.id) { r in modelLine(r, cat) }
            }
        }
    }

    func modelLine(_ r: ModelRow, _ cat: ModelCatalog) -> some View {
        let act = ModelPick.action(r, switching: cat.switching)
        let press = { cat.press(r) { id in m.save { $0.typingModel = id } } }
        return line(gutter: ModelPick.size(r.diskGB)) {
            HStack(spacing: 0) {
                Button(action: press) {
                    ZStack {
                        Circle().strokeBorder(r.current ? Color.clear : Color(nsColor: Native.controlEdge), lineWidth: 1)
                            .background(Circle().fill(r.current ? UIInk.ink : Color.clear))
                            .frame(width: 18, height: 18)
                        if r.current { Glyph("check", size: 12).foregroundStyle(UIInk.card) }
                    }
                    .opacity(r.downloaded || r.current ? 1 : 0.4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(act != .pick)
                .frame(width: G.toggle, alignment: .leading)
                .accessibilityLabel(r.name).accessibilityAddTraits(r.current ? .isSelected : [])
                HStack(spacing: 6) {
                    Text(r.name).font(NativeFont.text(16)).lineLimit(1)
                    if r.recommended {
                        Glyph("sparkle", size: 14).foregroundStyle(UIInk.muted).help(cat.why)
                            .accessibilityHidden(false).accessibilityLabel("Recommended for this Mac: \(cat.why)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture { if act == .pick { press() } }
                HStack(spacing: 12) {
                    ThreeMark(glyph: "bolt", n: r.speed, label: "Speed")
                    ThreeMark(glyph: "pencil", n: r.quality, label: "Quality")
                }
                .frame(width: 128, alignment: .leading)
                HStack(spacing: 6) {
                    let word = cat.failed == r.id && act == .pick ? "not loaded" : ModelPick.status(r, switching: cat.switching)
                    if !word.isEmpty { Text(word).font(NativeFont.mono(13)).foregroundStyle(UIInk.muted).lineLimit(1) }
                    if act == .download {
                        Button(action: press) {
                            HStack(spacing: 4) { Glyph("download", size: 14); Text("Download").font(NativeFont.text(13)) }
                                .foregroundStyle(UIInk.ink).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("\(ModelPick.size(r.diskGB)) from Hugging Face")
                    } else if act == .cancel {
                        Button(action: press) { Glyph("close", size: 14).foregroundStyle(UIInk.muted).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel("Cancel the download")
                    }
                }
                .frame(width: G.meter + G.numbers + G.cloud + 12 - 128, alignment: .trailing)
            }
        }
    }
}
