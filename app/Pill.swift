// The voice strip under the notch, in the style picked in Settings > Look > Strip (setting `stripStyle`, 14 November
// 2026: the user found the two-line strip "a little weird" and asked for one place where the words show):
//   composer  the default: a band beside the camera housing (state left, level and keys right), the words under it
//             (app/ComposerStrip.swift, layout in app/StripRules.swift)
//   classic   the one-row strip from before the Tape round, restored as it was (app/ClassicStrip.swift)
// Everything outside calls `Pill.shared`; this file only passes each call to the style in use. Clicks go through the
// strip; only its buttons take them (StripButton, HitView below).
import AppKit

/// What every strip style answers to (the calls Voice, Call, Offer and the rest make).
protocol StripFace: AnyObject {
    func listening()
    func level(_ pk: Float, them: Float?)
    func draft(_ text: String)
    func note(_ text: String?)
    func reading()
    func landed()
    func recording(call: Bool, seconds: Int, title: String, outline: [String], event: String, shots: Int, warning: String?)
    func offer(_ rows: [String], kind: String, side: String, controls list: [StripButton], seconds: Double)
    func offerRow(_ i: Int, _ text: String)
    func hide(after: Double)
    func show(_ text: String, seconds: Double, lines n: Int)
    func flash(_ text: String, button: StripButton?)
    func preview(_ folder: String) throws
    // the voice note's way to the field (app/VoiceFlowRules.swift)
    func finishing(insert: Bool)
    func held()
    func armed(_ text: String)
    func kept(_ text: String)
    func inserted()
    func copied(_ reason: String)
    func target(_ place: String, button: String)
    // round three: Return while the user speaks puts in what the user said so far and the note goes on
    func segment(_ line: String)                       // "Inserting → Claude": the closed segment is on its way
    func segmentDone(ok: Bool, reason: String)         // it is in the field, or on the clipboard (reason)
    func waking(_ on: Bool)                            // the voice engine loads; the audio is kept meanwhile
    func langMark(_ mark: String)                      // the take's language pin: "UK", "EN", "" unpinned
}

/// The classic strip says the flow's states with what it always had: its reading mark, a message, its receipt.
extension StripFace {
    func finishing(insert: Bool) { reading() }
    func held() { show("Finishing · press ↩ again", seconds: 2, lines: 1) }
    func armed(_ text: String) { show(text + "\n↩ Insert · Esc Drop", seconds: VoiceFlowRules.armedFor, lines: 4) }
    func kept(_ text: String) {
        let st = Drafter.shared.settings
        flash("In the journal" + (StripRules.againKey(tap: st.againTap && st.voice, chord: st.againKey).map { " · \($0) Insert again" } ?? ""), button: nil)
    }
    func inserted() { landed() }
    func copied(_ reason: String) { show("On the clipboard · " + reason, seconds: 3, lines: 2) }
    func target(_ place: String, button: String) {}
    func segment(_ line: String) { draft("") }
    func segmentDone(ok: Bool, reason: String) { if !ok { note("on the clipboard · " + reason) } }
    func waking(_ on: Bool) { note(on ? "waking" : nil) }
}

final class Pill {
    static let shared = Pill()
    /// Set by the preview renders, so they never read the settings file.
    var forced: StripStyle?
    private var last: StripFace?

    static func face(_ s: StripStyle) -> StripFace { s == .classic ? ClassicStrip.shared : ComposerStrip.shared }
    var style: StripStyle { forced ?? StripStyle.of(Drafter.shared.settings.stripStyle) }
    /// The style in use; a style changed in Settings while a strip shows puts the old one away first.
    private var cur: StripFace {
        let f = Pill.face(style)
        if let l = last, l !== f { l.hide(after: 0) }
        last = f
        return f
    }

    /// A long note or call shows in the recording window and the small notch, not in the strip (app/RecordWindow.swift).
    /// Push-to-talk keeps the strip.
    private var windowed: Bool {
        RecordLive.shared.active || (forced == nil && Talk.shared.long && Talk.shared.state == .listening && Drafter.shared.settings.recordWindow)
    }
    func listening() { if windowed { return }; cur.listening() }
    func level(_ pk: Float, them: Float? = nil) { if RecordLive.shared.active { RecordLive.shared.level(pk, them: them); return }; cur.level(pk, them: them) }
    func draft(_ text: String) { cur.draft(text) }
    func pin(_ mark: String) { cur.langMark(mark) }
    func note(_ text: String?) { cur.note(text) }
    func reading() { cur.reading() }
    func landed() { cur.landed() }
    func recording(call: Bool, seconds: Int, title: String, outline: [String], event: String = "", shots: Int = 0, warning: String? = nil) {
        if RecordLive.shared.active { RecordLive.shared.update(call: call, seconds: seconds, title: title, outline: outline, event: event, warning: warning); return }
        cur.recording(call: call, seconds: seconds, title: title, outline: outline, event: event, shots: shots, warning: warning)
    }
    func offer(_ rows: [String], kind: String, side: String = "", controls list: [StripButton], seconds: Double) {
        // a call's record offer hangs from the notch, small (17 November 2026), with the recording window setting on
        if kind == "Call", forced == nil, Drafter.shared.settings.recordWindow, !RecordLive.shared.active {
            if RecordNotch.shared.offering == false { cur.hide(after: 0) }
            RecordNotch.shared.offer(rows.first ?? "Record this call?", ([side] + rows.dropFirst().prefix(1)).filter { !$0.isEmpty }.joined(separator: " · "), seconds: seconds)
            return
        }
        cur.offer(rows, kind: kind, side: side, controls: list, seconds: seconds)
    }
    func offerRow(_ i: Int, _ text: String) {
        if RecordNotch.shared.offering { if i == 1 { RecordNotch.shared.offerDetail(text) }; return }
        cur.offerRow(i, text)
    }
    func hide(after: Double = 0) { if after == 0 { RecordNotch.shared.endOffer() }; cur.hide(after: after) }
    func show(_ text: String, seconds: Double, lines n: Int = 2) { cur.show(text, seconds: seconds, lines: n) }
    func flash(_ text: String, button: StripButton? = nil) { cur.flash(text, button: button) }
    func preview(_ folder: String) throws { try cur.preview(folder) }
    func finishing(insert: Bool) { cur.finishing(insert: insert) }
    func held() { cur.held() }
    func armed(_ text: String) { cur.armed(text) }
    func kept(_ text: String) { cur.kept(text) }
    func inserted() { cur.inserted() }
    func copied(_ reason: String) { cur.copied(reason) }
    func target(_ place: String, button: String) { cur.target(place, button: button) }
    func segment(_ line: String) { cur.segment(line) }
    func segmentDone(ok: Bool, reason: String = "") { cur.segmentDone(ok: ok, reason: reason) }
    func waking(_ on: Bool) { if windowed { return }; cur.waking(on) }
    /// A level as a share of the meter: -50 dB .. -6 dB as 0 ... 1.
    static func share(_ pk: Float) -> CGFloat { CGFloat(max(0, min(1, (20 * log10(max(pk, 1e-5)) + 50) / 44))) }
}

/// A quiet button in the strip's last row: its label, then its key in faint mono ("Record  tab").
final class StripButton: NSButton {
    /// primary: the answer most people pick, filled light; plain: a soft dark capsule; quiet: text only (a setting
    /// change); stop: coral, ends a recording (1 November 2026, the user: "nicer buttons").
    enum Style { case primary, plain, quiet, stop }
    let label: String, key: String
    let style: Style
    private let confirm: String?          // the first click arms it ("Click again to stop"), a second within 3 s does it
    private let run: () -> Void
    private var armed = false
    var spoken: String { key.isEmpty ? label : "\(label), \(key)" }
    var hover = false { didSet { if hover != oldValue { render() } } }

    init(_ label: String, key: String, style: Style = .plain, confirm: String? = nil, run: @escaping () -> Void) {
        self.label = label; self.key = key; self.style = style; self.confirm = confirm; self.run = run
        super.init(frame: .zero)
        isBordered = false; setButtonType(.momentaryChange); focusRingType = .none
        target = self; action = #selector(fire)
        wantsLayer = true; layer?.cornerRadius = 6; layer?.cornerCurve = .continuous
        setAccessibilityLabel(spoken)
        // as wide as the longer of its two labels, so arming it never moves the row
        let w = max(title(label, armed: false).size().width, confirm.map { title($0, armed: true).size().width } ?? 0)
        setFrameSize(NSSize(width: ceil(w) + (style == .quiet ? 16 : 26), height: 26))
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var ink: NSColor {
        if armed { return .black }
        switch style {
        case .primary: return .black
        case .plain: return NSColor.white.withAlphaComponent(0.88)
        case .quiet: return hover ? NSColor.white.withAlphaComponent(0.8) : Native.faint
        case .stop: return Native.coral
        }
    }
    private var fill: NSColor? {
        if armed { return Native.coral }
        switch style {
        case .primary: return NSColor.white.withAlphaComponent(hover ? 1 : 0.9)
        case .plain: return NSColor.white.withAlphaComponent(hover ? 0.17 : 0.1)
        case .quiet: return hover ? NSColor.white.withAlphaComponent(0.07) : nil
        case .stop: return Native.coral.withAlphaComponent(hover ? 0.26 : 0.16)
        }
    }
    private func title(_ text: String, armed: Bool) -> NSAttributedString {
        let ink = armed ? NSColor.black : self.ink
        let t = NSMutableAttributedString()
        if style == .stop && !armed { t.append(NSAttributedString(string: "■ ", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: ink, .baselineOffset: 1.5])) }
        t.append(NSAttributedString(string: text, attributes: [.font: Native.text(12, style == .primary || armed ? .semibold : .medium), .foregroundColor: ink]))
        if !key.isEmpty && !armed { t.append(NSAttributedString(string: "  " + key, attributes: [.font: Native.mono(11), .foregroundColor: ink.withAlphaComponent(0.62)])) }
        return t
    }
    private func render() {
        attributedTitle = title(armed ? confirm ?? label : label, armed: armed)
        layer?.backgroundColor = fill?.cgColor
    }
    @objc func fire() {
        if confirm != nil, !armed {
            armed = true; render()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.armed = false; self?.render() }
            return
        }
        armed = false; render(); run()
    }
}

/// The clear view over the buttons' row: a click or a hover there goes to the button under it.
final class HitView: NSView {
    var buttons: [StripButton] = []
    var origin = NSPoint.zero                     // this view's origin in the strip's coordinates
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func button(_ e: NSEvent) -> StripButton? {
        let p = convert(e.locationInWindow, from: nil), q = NSPoint(x: p.x + origin.x, y: p.y + origin.y)
        return buttons.first { $0.frame.insetBy(dx: -4, dy: -3).contains(q) }
    }
    override func mouseDown(with e: NSEvent) { button(e)?.fire() }
    override func mouseMoved(with e: NSEvent) { let b = button(e); buttons.forEach { $0.hover = $0 === b } }
    override func mouseExited(with e: NSEvent) { buttons.forEach { $0.hover = false } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func draw(_ r: NSRect) { NSColor.black.withAlphaComponent(0.01).setFill(); bounds.fill() }   // clear, yet it takes clicks
}

