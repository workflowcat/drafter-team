import Foundation
import CoreGraphics

// swiftc -parse-as-library app/AnchorRules.swift tests/anchor_rules.swift -o app/build/anchor-rules-test && app/build/anchor-rules-test
// Round 2026-11-17-anchor (roadmap item 6): where the ghost goes in a field that gives no caret rect. Made-up lines only.
@main
struct AnchorRulesChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }
    static func near(_ a: CGFloat, _ b: CGFloat, _ e: CGFloat = 1) -> Bool { abs(a - b) <= e }

    static func main() {
        typealias R = AnchorRules
        let w10: (String, CGFloat) -> CGFloat = { s, _ in CGFloat(s.count) * 10 }   // every glyph 10 pt wide
        let doc = CGRect(x: 100, y: 200, width: 600, height: 400)
        let box = CGRect(x: 100, y: 200, width: 400, height: 30)

        // (a) the caret rect wins, whatever else is there
        var i = AnchorInput(caret: CGRect(x: 300, y: 210, width: 2, height: 18), span: CGRect(x: 108, y: 210, width: 50, height: 18), frame: doc, before: "hello")
        var a = R.pick(i, measure: w10)
        check(a?.kind == .exact && a?.source == "caret" && a?.rect.minX == 300 && a?.rect.width == 1, "caret rect: exact, as today")
        i.caret = CGRect(x: 0, y: 0, width: 1, height: 18)
        check(R.pick(i, measure: w10)?.source != "caret", "a caret rect at the origin is no caret rect")
        i.caret = CGRect(x: 300, y: 210, width: 1, height: 1)
        check(R.pick(i, measure: w10)?.source != "caret", "a flat caret rect is no caret rect")

        // a field that gave a caret rect a moment ago: a missed read, stay quiet as today
        check(R.pick(AnchorInput(frame: doc, before: "hi", recentExact: true), measure: w10) == nil, "recent exact rect: no fallback")

        // (b) the span from the line start: its right edge
        i = AnchorInput(span: CGRect(x: 108, y: 210, width: 50, height: 18), lineStart: CGRect(x: 108, y: 210, width: 9, height: 18), frame: doc, before: "hello")
        a = R.pick(i, measure: w10)
        check(a?.kind == .estimate && a?.source == "span" && a?.rect.minX == 158 && a?.rect.minY == 210, "span: caret at its right edge")
        i.span = CGRect(x: 108, y: 210, width: 580, height: 54)   // a wrapped paragraph: three rows, its right edge is not the caret
        a = R.pick(i, measure: w10)
        check(a?.source == "line", "a span over several rows is not trusted; the line start is")
        // (b) the line start and a measure
        check(a.map { near($0.rect.minX, 158) && $0.rect.minY == 210 } ?? false, "line start + 5 glyphs: x 158")
        i = AnchorInput(lineStart: CGRect(x: 108, y: 210, width: 9, height: 18), frame: doc, before: "first\n" + String(repeating: "a", count: 70))
        a = R.pick(i, measure: w10)   // 700 pt on a 584 pt row: one wrap
        check(a?.source == "line" && a.map { near($0.rect.minY, 228) && near($0.rect.minX, 108 + 700 - 584) } ?? false, "line start, wrapped once: next row")
        i.lineStart = CGRect(x: 2000, y: 210, width: 9, height: 18)
        check(R.pick(i, measure: w10)?.source != "line", "a line start outside the frame is not trusted")

        // (c) frame + measure: a one-line field, text centred in its height
        a = R.pick(AnchorInput(frame: box, role: "AXTextField", before: "abc"), measure: w10)
        check(a?.kind == .estimate && a?.source == "frame", "one-line field: estimate from the frame")
        check(a.map { near($0.rect.minX, 100 + 8 + 30) && $0.rect.minY >= 200 && $0.rect.maxY <= 230 } ?? false, "one-line field: x after the text, inside the frame")
        check(R.pick(AnchorInput(frame: box, role: "AXTextField", before: String(repeating: "b", count: 60)), measure: w10)?.kind == .chip,
              "one-line field whose text runs past its width (scrolled): chip")
        // a multi-line box: rows add up
        a = R.pick(AnchorInput(frame: doc, role: "AXTextArea", before: "one\ntwo\nthree"), measure: w10)
        let lh = (CGFloat(14) * 1.3).rounded()
        _ = lh
        check(a?.kind == .chip, "three paragraphs: rows are a guess, the chip (18 November 2026)")
        check(R.pick(AnchorInput(frame: doc, role: "AXGroup", before: "hi"), measure: w10)?.kind == .chip, "a group is no text field: the chip")
        a = R.pick(AnchorInput(frame: doc, role: "AXTextArea", before: ""), measure: w10)
        check(a?.source == "frame" && a.map { near($0.rect.minX, 108) && near($0.rect.minY, 206) } ?? false, "empty box: its first row, left padding")
        a = R.pick(AnchorInput(frame: doc, role: "AXTextArea", before: "x", fontSize: 20), measure: { s, size in CGFloat(s.count) * size })
        check(a.map { near($0.rect.height, 26) && near($0.rect.minX, 128) } ?? false, "the field's own font size is used when known")

        // (d) the chip: too many rows to guess
        let long = Array(repeating: "a line", count: 9).joined(separator: "\n")
        a = R.pick(AnchorInput(frame: doc, role: "AXGroup", before: long), measure: w10)
        check(a?.kind == .chip && a?.source == "field", "a long document: chip")
        check(a.map { $0.rect.minX == 108 && near($0.rect.minY, 600 + R.chipGap - 1) } ?? false, "chip: under the frame's lower-left corner")
        // the screen ends under the field: the chip goes inside its bottom edge
        a = R.pick(AnchorInput(frame: doc, role: "AXGroup", before: long, visible: CGRect(x: 0, y: 25, width: 1440, height: 575)), measure: w10)
        check(a.map { $0.rect.maxY + R.chipH <= 600 && $0.rect.minY > 200 } ?? false, "chip: inside the frame when the screen ends at its bottom")
        // a frame taller than the screen
        a = R.pick(AnchorInput(frame: CGRect(x: 0, y: 0, width: 1400, height: 5000), role: "AXWebArea", before: long, visible: CGRect(x: 0, y: 25, width: 1440, height: 875)), measure: w10)
        check(a.map { $0.kind == .chip && $0.rect.maxY + R.chipH <= 900 && $0.rect.minX >= 8 } ?? false, "chip: on screen for a frame taller than the screen")

        // nothing to anchor on
        check(R.pick(AnchorInput(before: "hi"), measure: w10) == nil, "no rect, no frame: nil (quiet, as today)")
        check(R.pick(AnchorInput(frame: CGRect(x: 10, y: 10, width: 1, height: 1), before: "hi"), measure: w10) == nil, "a 1x1 frame (an offscreen text target): nil")

        // font guess
        check(R.guessFont(role: "AXTextField", frame: CGRect(x: 0, y: 0, width: 200, height: 22)) >= 11, "a small field: at least 11 pt")
        check(R.guessFont(role: "AXTextArea", frame: doc) == 14, "a box: 14 pt")
        check(R.roughWidth("abcd", 10) > 0, "the rough measure counts")

        // one log line per kind change per app
        var seen: [String: AnchorKind] = [:]
        check(R.change(&seen, app: "a.b", kind: .exact, source: "caret", role: "AXTextArea") == nil, "first exact: no line")
        let l1 = R.change(&seen, app: "a.b", kind: .chip, source: "field", role: "AXGroup")
        check(l1 == "anchor a.b exact -> chip via field role=AXGroup", "exact to chip: one line")
        check(R.change(&seen, app: "a.b", kind: .chip, source: "field", role: "AXGroup") == nil, "same kind again: no line")
        check(R.change(&seen, app: "c.d", kind: .estimate, source: "frame", role: "AXTextArea") == "anchor c.d none -> estimate via frame role=AXTextArea", "first fallback in an app: one line")
        check(R.change(&seen, app: "a.b", kind: .exact, source: "caret", role: "AXGroup") != nil, "back to exact: one line")

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("anchor rules: all passed")
    }
}
