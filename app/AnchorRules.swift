// Where the ghost goes when the field gives no caret rect (roadmap item 6, round 2026-11-17-anchor). Pure: it gets
// what Accessibility answered and gives back a place and a kind. Focus.anchor reads the field; Ghost draws a chip-kind
// anchor as a chip. Rects are AX screen coordinates (top-left based), like Spot.rect.
import Foundation
import CoreGraphics

enum AnchorKind: String {
    case exact      // the caret rect itself
    case estimate   // from a nearby range or the field's frame and a text measure: drawn as today
    case chip       // no reliable position: the ghost words on a chip near the field, not inline
}

/// What Accessibility gave for the focused field. Every field may be nil; text is only measured, never kept.
struct AnchorInput {
    var caret: CGRect? = nil       // (a) the caret rect (today's source)
    var span: CGRect? = nil        // (b) bounds of the range from the caret's line start to the caret
    var lineStart: CGRect? = nil   // (b) bounds of the first character of the caret's line
    var frame: CGRect? = nil       // (c, d) the focused element's frame
    var role = ""
    var before = ""                // the text before the caret: line count and the last line's width
    var fontSize: CGFloat? = nil   // the field's own font size, when it answered
    var visible: CGRect? = nil     // the screen's visible area, so a chip never lands off screen
    var recentExact = false        // the same field gave a caret rect a moment ago: a missed read, stay quiet
}

struct Anchor: Equatable {
    let rect: CGRect
    let kind: AnchorKind
    let source: String             // caret, span, line, frame, field (for the log; no text)
}

enum AnchorRules {
    /// Text lines the frame estimate trusts: past this, wrapping guesses add up and the chip is safer.
    static let maxRows = 4
    static let padX: CGFloat = 8, padY: CGFloat = 6
    static let chipH: CGFloat = 26, chipGap: CGFloat = 4

    /// A rough width when no font is at hand (tests, a field without a font): average glyph about 0.52 em.
    static func roughWidth(_ s: String, _ size: CGFloat) -> CGFloat { CGFloat(s.count) * size * 0.52 }

    static func sane(_ r: CGRect?) -> CGRect? {
        guard let r, r.height > 2, r.height < 200, r.origin != .zero, r.minX.isFinite, r.minY.isFinite else { return nil }
        return r
    }

    /// Font size guessed from the role and the frame: one-line fields scale with their height.
    static func guessFont(role: String, frame: CGRect) -> CGFloat {
        var f: CGFloat = ["AXTextField", "AXComboBox", "AXSearchField"].contains(role) ? 13 : 14
        if frame.height < 40 { f = min(f, max(11, (frame.height - 8) * 0.75)) }
        return f
    }

    /// The order: (a) caret rect, (b) a nearby range, (c) frame + text measure, (d) a chip near the field, else nil.
    static func pick(_ i: AnchorInput, measure: (String, CGFloat) -> CGFloat = roughWidth) -> Anchor? {
        if let c = sane(i.caret) { return Anchor(rect: CGRect(x: c.minX, y: c.minY, width: 1, height: c.height), kind: .exact, source: "caret") }
        if i.recentExact { return nil }
        let frame = i.frame.flatMap { $0.width > 20 && $0.height > 8 ? $0 : nil }
        let lastLine = String(i.before.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        // (b) the range from the line start to the caret: its right edge is the caret when it is one row high
        if let s = sane(i.span), s.width > 0 {
            let row = sane(i.lineStart)?.height ?? min(s.height, 22)
            if s.height <= row * 1.5, inside(s, frame) {
                return Anchor(rect: CGRect(x: s.maxX, y: s.minY, width: 1, height: s.height), kind: .estimate, source: "span")
            }
        }
        // (b) the line's first character, then the rest of the line measured from it (wrapping inside the frame)
        if let l = sane(i.lineStart), inside(l, frame) {
            let size = i.fontSize ?? max(11, min(26, l.height * 0.78))
            let w = measure(lastLine, size)
            let right = (frame?.maxX ?? .infinity) - padX
            let usable = right - l.minX
            if usable > 20 {
                let rows = w > usable ? Int(w / usable) : 0
                let x = l.minX + w - CGFloat(rows) * usable
                let y = l.minY + CGFloat(rows) * l.height
                let r = CGRect(x: min(x, right), y: y, width: 1, height: l.height)
                if rows < maxRows, frame.map({ r.maxY <= $0.maxY + 2 }) ?? true {
                    return Anchor(rect: r, kind: .estimate, source: "line")
                }
            }
        }
        guard let frame else { return nil }
        // (c) the frame and a text measure: rows of every paragraph, the last row's width
        let size = i.fontSize ?? guessFont(role: i.role, frame: frame)
        let lineH = (size * 1.3).rounded()
        let usable = frame.width - 2 * padX
        let oneLine = frame.height < lineH * 2.2
        let top = oneLine ? frame.minY + max(0, (frame.height - lineH) / 2) : frame.minY + padY
        var rows = 0, lastW: CGFloat = 0, trusted = usable > 20
        if trusted {
            for p in i.before.split(separator: "\n", omittingEmptySubsequences: false) {
                let w = measure(String(p), size)
                let n = max(1, Int((w / usable).rounded(.up)))
                rows += n
                lastW = w - CGFloat(n - 1) * usable
                if rows > maxRows { trusted = false; break }
            }
            rows = max(rows, 1)
        }
        // only the first row of a text field (18 November 2026, Andrii: "some of the text appears somewhere almost randomly to the
        // sides"): in Beeper the focused element is often a whole AXGroup panel, and wrapped rows measured without the
        // field's font drift; anywhere else the chip is the stable place
        let textRole = ["AXTextField", "AXComboBox", "AXSearchField", "AXTextArea"].contains(i.role)
        if trusted, textRole, rows == 1 {
            let y = top + CGFloat(rows - 1) * lineH
            let x = frame.minX + padX + max(0, lastW)
            if y + lineH <= frame.maxY + 2, x <= frame.maxX - 2 {
                return Anchor(rect: CGRect(x: x, y: y, width: 1, height: lineH), kind: .estimate, source: "frame")
            }
        }
        // (d) the chip: just under the field's lower-left corner, or inside its bottom edge when the screen ends there
        return Anchor(rect: chipRect(frame, visible: i.visible), kind: .chip, source: "field")
    }

    /// A chip-kind anchor: a 1-pt rect whose bottom edge is where the chip's top goes (Ghost draws the chip under it).
    static func chipRect(_ frame: CGRect, visible: CGRect?) -> CGRect {
        var x = frame.minX + padX
        var y = frame.maxY + chipGap - 1
        if let v = visible {
            if y + 1 + chipH > v.maxY { y = min(frame.maxY, v.maxY) - chipH - chipGap - 1 }
            y = max(y, v.minY + chipGap)
            x = min(max(x, v.minX + padX), v.maxX - 200)
        }
        return CGRect(x: x, y: y, width: 1, height: 1)
    }

    /// The rect lies inside the frame (a little slack); no frame: trusted.
    static func inside(_ r: CGRect, _ frame: CGRect?) -> Bool {
        guard let f = frame else { return true }
        return f.insetBy(dx: -4, dy: -4).contains(CGPoint(x: r.minX, y: r.midY))
    }

    /// One log line per anchor-kind change per app: the kind last logged for each app; -> the line, or nil.
    static func change(_ seen: inout [String: AnchorKind], app: String, kind: AnchorKind, source: String, role: String) -> String? {
        let old = seen[app]
        seen[app] = kind
        if old == kind || (old == nil && kind == .exact) { return nil }
        return "anchor \(app) \(old?.rawValue ?? "none") -> \(kind.rawValue) via \(source) role=\(role)"
    }
}
