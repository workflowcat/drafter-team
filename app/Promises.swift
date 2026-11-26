import AppKit
import SwiftUI

/// Promises (2026-11-17, engine/promises.py): promises the user made in a chat ("I'll send the deck tomorrow",
/// "завтра скину договір") come back in that chat's empty box when due: a matching saved or copied link, else a
/// follow-up line. Tab fills the box (never sends) and marks the promise done. The window's Shortcuts page lists the
/// open ones with Done and Drop.
enum PromiseHooks {
    /// The field asked last: one ask per field.
    static var askedEl: AXUIElement?
    /// The due promise for the box on screen, for the instant-replies card to put first (the lead's
    /// `Keys.promiseFirst` reads this on merge). Cleared when another field asks.
    static var first: (el: AXUIElement, opt: [String: String])?

    /// A next-message option was taken with Tab: a promise option is marked done.
    static func taken(_ o: [String: String]?) {
        guard let id = o?["promise"], !id.isEmpty else { return }
        Engine.shared.post("/promises/done", ["id": id])
        log("promise taken")
    }
}

extension Keys {
    /// The due promise for this box as a draft option (first in the list), or nil. `ctx`: the screen text above the box.
    func promiseOption(for s: Spot, ctx: String, done: @escaping ([String: String]?) -> Void) {
        guard !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { done(nil); return }
        Engine.shared.post("/promises/due", ["app": s.app.localizedName ?? "", "context": String(ctx.suffix(1500))], timeout: 3) { j in
            guard let id = j?["id"] as? String, let offer = j?["offer"] as? String, !offer.isEmpty else { done(nil); return }
            let what = j?["what"] as? String ?? ""
            done(["text": offer, "label": "promise · " + what, "promise": id, "kind": j?["kind"] as? String ?? ""])
        }
    }

    /// An empty chat box (checkEmpty): ask once per field; a due promise shows as a next-message card.
    func askPromise(_ s: Spot) {
        if let was = PromiseHooks.askedEl, CFEqual(was, s.el) { return }
        PromiseHooks.askedEl = s.el
        PromiseHooks.first = nil
        let el = s.el, pid = s.app.processIdentifier, rect = s.rect ?? Focus.fieldStart(s.el)
        contextQueue.async {
            let ctx = Keys.readContext(el, pid: pid, caret: rect)
            DispatchQueue.main.async {
                self.promiseOption(for: s, ctx: ctx) { o in
                    if let o { PromiseHooks.first = (el, ["text": o["text"] ?? "", "label": o["label"] ?? "", "promise": o["promise"] ?? ""]) }
                    guard let o, !Ghost.shared.isDraft, let now = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(now.el, el),
                          Keys.boxKind(now) != nil, !KeyHooks.paused(now), let r = now.rect ?? Focus.fieldStart(now.el) else { return }
                    self.spot = now
                    Ghost.shared.showDraft([o], field: Focus.frame(now.el), caret: r)
                    log("promise offered (\(o["kind"] ?? ""))")
                }
            }
        }
    }
}

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
            Text(what).font(NativeFont.text(13.5, .medium)).foregroundStyle(UIInk.ink).lineLimit(1)
            if !who.isEmpty { Text("· " + who).font(NativeFont.text(12.5)).foregroundStyle(UIInk.muted).lineLimit(1) }
            Text("· " + PromisesSection.relative(due)).font(NativeFont.mono(11.5)).foregroundStyle(overdue ? UIInk.coral : UIInk.muted)
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
