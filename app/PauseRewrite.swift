// The pause rewrite (17 November 2026, Andrii's design; setting `pauseRewrite`, off, with the cloud mark in Settings).
// After PauseRewriteRules.pause seconds with no key, in a field whose paragraph before the caret holds a finished
// sentence, a chip with a loading mark appears at the caret and the paragraph goes to engine `/pause_rewrite`: the ⌥Tab
// rework path (engine/rework.py "polish", Claude Haiku) with the same context, under the daily Claude cap. When
// the answer comes before his next key, the chip shows the rewrite with the changed words marked. Tab puts it in
// (selects the paragraph, pastes the rewrite: never a typed Return, never a send); Backspace as the very next key takes
// it back (Rework.takeBack, when `tabBack` is on); any other key drops the chip and goes to the app. Never in skipped
// apps, password fields or under secure input. Keys: app/KeyMap.swift ("pauseRewrite", "tabBack").
import AppKit
import Carbon

enum PauseRewrite {
    static var timer: Timer?
    static var asked = ""            // the last text asked about: one ask per text
    struct Pending { let el: AXUIElement; let pid: pid_t; let text: String; let new: String }
    static var pending: Pending?

    /// From Keys.ask, after each key's read of the field.
    static func schedule(_ s: Spot, context ctx: String, seq mine: Int) {
        timer?.invalidate()
        let st = Drafter.shared.settings
        guard PauseRewriteRules.allowed(on: st.pauseRewrite, secure: IsSecureEventInputEnabled(),
                                        skipped: st.skip.contains(s.app.bundleIdentifier ?? ""),
                                        password: s.role == "AXSecureTextField", mid: s.mid),
              let msg = PauseRewriteRules.message(Proof.span(s.before)), PauseRewriteRules.ready(msg.text), msg.text != asked else { return }
        let bundle = s.app.bundleIdentifier ?? "", app = s.app.localizedName ?? ""
        let context = s.value.contains(PauseRewriteRules.marker) ? ReaderRules.testContext(s.before, span: Proof.span(s.before)) : ctx
        timer = Timer.scheduledTimer(withTimeInterval: PauseRewriteRules.pause, repeats: false) { _ in
            let k = Keys.shared, g = Ghost.shared
            // a plain ghost may be covered; another chip is left alone
            guard mine == k.seq, Talk.shared.keysFree, g.action == nil, Engine.shared.ready, !IsSecureEventInputEnabled(),
                  let now = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(now.el, s.el), now.before == s.before,
                  !now.mid, let r = now.rect else { return }
            asked = msg.text
            k.endStat(); k.spot = now
            g.unsure = 0
            g.show("", action: ["id": "pauseRewrite", "chip": PauseRewriteRules.loading], at: r)   // no "run": Tab stays the app's
            let t0 = Date()
            let notes = WritingNotes.forApp(bundle, global: st.writingNote, perApp: st.appNotes)
            Engine.shared.post("/pause_rewrite", ["text": msg.text, "app": app, "context": context, "kb": KeyLayout.language, "notes": notes],
                               timeout: PauseRewriteRules.budget) { j in
                let elapsed = Date().timeIntervalSince(t0)
                let ours = Ghost.shared.action?["id"] as? String == "pauseRewrite"
                let new = (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                log("pause rewrite \(bundle) \(Int(elapsed * 1000))ms " + (new.isEmpty ? "none (\(j?["skip"] as? String ?? "no answer"))" : "\(msg.text.count) → \(new.count) chars"))
                guard ours, !new.isEmpty, let now2 = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(now2.el, s.el),
                      now2.app.processIdentifier == s.app.processIdentifier, let r2 = now2.rect,
                      PauseRewriteRules.fresh(sentSeq: mine, nowSeq: k.seq, sentBefore: s.before, nowBefore: now2.before, elapsed: elapsed) else {
                    if ours, mine == k.seq { Ghost.shared.hide() }   // nothing to offer: the loading chip goes
                    return
                }
                let marks = (j?["marks"] as? [[Any]] ?? []).map { $0.compactMap { ($0 as? NSNumber)?.intValue } }
                let label = PauseRewriteRules.label(new, marks: marks)
                pending = Pending(el: now2.el, pid: now2.app.processIdentifier, text: msg.text, new: new)
                k.spot = now2
                Ghost.shared.show("", action: ["id": "pauseRewrite", "chip": label.text, "marks": label.marks.map { [$0.location, $0.length] },
                                               "run": ["kind": "pauseRewrite"]], at: r2)
            }
        }
    }

    static func cancel() { timer?.invalidate() }

    /// Tab on the chip: select the rewritten text back from the caret and paste the rewrite over it.
    static func apply() {
        guard let p = pending else { return }
        pending = nil
        let st = Drafter.shared.settings
        guard !IsSecureEventInputEnabled(), let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == p.pid,
              !st.skip.contains(front.bundleIdentifier ?? ""), let el = Focus.focused(), CFEqual(el, p.el),
              (Focus.attr(el, kAXRoleAttribute) as String?) != "AXSecureTextField",
              PauseRewriteRules.stillEnds(before: Focus.before(el) ?? "", text: p.text) else {
            Ghost.shared.flash("Text has changed"); return
        }
        Keys.shared.cancel()
        Fields.left(p.text.count, shift: true)
        func put(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                let sel = PauseRewriteRules.norm(Focus.selection() ?? "")
                if sel != PauseRewriteRules.norm(p.text) {
                    if tries > 0 { put(tries - 1); return }
                    Fields.right(1)   // the selection collapses to its end: the caret is back where he left it
                    Ghost.shared.flash("Could not rewrite"); log("pause rewrite: selection did not match"); return
                }
                guard Focus.focused().map({ CFEqual($0, el) }) == true, !IsSecureEventInputEnabled() else { return }
                Focus.paste(p.new)
                if st.tabBack { Rework.last = Rework.Done(el: el, old: p.text, new: p.new, revision: Keys.shared.inputRevision, at: Date()) }
                log("pause rewrite applied, \(p.text.count) → \(p.new.count) chars")
            }
        }
        put(8)
    }
}
