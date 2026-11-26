// Reader check before sending (roadmap item 4, 17 November 2026; docs/rounds/2026-11-17-reader.md; setting
// `readerCheck`, off). In a chat box, once the message looks finished (ReaderRules.wait), the message and the screen
// text the app already read for suggestions go to the engine's `/reader` (engine/reader.py: local, no model, nothing
// leaves the Mac). An answer that comes within ReaderRules.budget, before any key of the user's, shows one chip: "⇥ Fix N"
// (Tab puts the fixes in through the Fix chip's path, app/Proof.swift) and/or "↩ they asked about X" (Tab only
// puts the chip away). Any other key, Enter included, drops the chip and goes to the app as always: Enter is never
// held.
import AppKit
import Carbon

enum Reader {
    static var timer: Timer?
    static var checked = ""

    /// From Keys.ask. True when the reader took this field (a chat, or a test field) and the setting is on.
    @discardableResult
    static func schedule(_ s: Spot, context ctx: String, seq mine: Int) -> Bool {
        timer?.invalidate()
        guard Drafter.shared.settings.readerCheck, ReaderRules.applies(kind: Proof.kind(s), value: s.value) else { return false }
        guard !IsSecureEventInputEnabled() else { return true }
        let span = Proof.span(s.before)
        guard let wait = ReaderRules.wait(span), let msg = ReaderRules.message(span), msg.text != checked,
              !s.viaMarkers || span == s.before else { return true }
        let context = s.value.contains(ReaderRules.marker) ? ReaderRules.testContext(s.before, span: span) : ctx
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
            let k = Keys.shared, g = Ghost.shared
            // a plain ghost may be replaced; another chip is left alone
            guard mine == k.seq, Talk.shared.keysFree, g.action == nil else { return }
            checked = msg.text
            let t0 = Date()
            Engine.shared.post("/reader", ["text": msg.text, "context": context, "app": s.app.localizedName ?? ""], timeout: ReaderRules.budget) { j in
                let elapsed = Date().timeIntervalSince(t0)
                let raw = j?["edits"] as? [[String: Any]] ?? []
                let ask = j?["ask"] as? String ?? ""
                var edits = raw.compactMap { e -> ReaderRules.Edit? in
                    guard let at = e["at"] as? Int, let len = e["len"] as? Int, let old = e["old"] as? String, let new = e["new"] as? String else { return nil }
                    return ReaderRules.Edit(at: at, len: len, old: old, new: new)
                }
                _ = Autocorrect.refresh()
                edits = ReaderRules.shifted(edits.filter { e in
                    ReaderRules.keep(e, known: { w in
                        Autocorrect.known(w) || Spell.known(w, w.unicodeScalars.contains { KeyLayout.cyr.contains($0) } ? "uk" : "en")
                    })
                }, by: msg.offset)
                log("reader \(s.app.bundleIdentifier ?? "?") \(Int(elapsed * 1000))ms engine \(j?["ms"] as? Double ?? 0)ms \(raw.count)/\(edits.count) fixes" + (ask.isEmpty ? "" : " ask"))
                guard let label = ReaderRules.label(edits, ask: ask), Ghost.shared.action == nil,
                      let now = Focus.spot(skip: Drafter.shared.settings.skip).0, let r = now.rect,
                      CFEqual(now.el, s.el), now.app.processIdentifier == s.app.processIdentifier,
                      ReaderRules.fresh(sentSeq: mine, nowSeq: k.seq, sentBefore: s.before, nowBefore: now.before, elapsed: elapsed) else { return }
                if !edits.isEmpty {
                    Proof.pending = Proof.Pending(el: now.el, pid: now.app.processIdentifier, before: now.before, text: span, caret: now.caret,
                                                  web: now.viaMarkers || Focus.isWeb(now.app),
                                                  edits: edits.map { ["at": $0.at, "len": $0.len, "old": $0.old, "new": $0.new] },
                                                  fixed: span)
                }
                k.endStat()
                k.spot = now
                Ghost.shared.unsure = 0
                Ghost.shared.show("", action: ["id": "reader", "chip": label, "run": ["kind": edits.isEmpty ? "reader.note" : "proofread"]], at: r)
                if debugLog { log("reader chip «\(label)»") }
            }
        }
        return true
    }

    static func cancel() { timer?.invalidate() }
}
