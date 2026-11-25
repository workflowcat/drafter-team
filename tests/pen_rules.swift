// swiftc -parse-as-library app/PenRules.swift app/QuickRules.swift app/PictureLookRules.swift app/ClipRules.swift app/ShotRules.swift app/MarkupRules.swift app/ShotPackRules.swift tests/pen_rules.swift -o app/build/pen-rules-test && app/build/pen-rules-test
// The markup pen (app/PenRules.swift): thinning, the Catmull-Rom smoothing, the bounding box, the mark in the model
// (one ⌘Z per stroke, moving, the crop) and its line in the "Marks" text. Made-up strokes only.
import Foundation
import CoreGraphics

@main struct PenChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }
    static func near(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.001) -> Bool { abs(a.x - b.x) <= e && abs(a.y - b.y) <= e }

    static func main() {
        // thinning: close points go, the first and the last stay
        let dense = (0...100).map { CGPoint(x: CGFloat($0) * 0.5, y: 10) }      // 101 points, 0.5 px apart
        let thin = PenRules.thin(dense, gap: 2)
        check(thin.first == dense.first && thin.last == dense.last, "thin keeps both ends")
        check(thin.count == 26, "thin: one point per 2 px on a 50 px line, got \(thin.count)")
        check(zip(thin, thin.dropFirst()).allSatisfy { hypot($1.x - $0.x, $1.y - $0.y) >= 1 }, "thin: no two points on top of each other")
        check(PenRules.thin([CGPoint(x: 1, y: 1), CGPoint(x: 1.2, y: 1)], gap: 2).count == 2, "2 points stay 2")

        // smoothing: through every point, nothing beyond the ends, a corner rounded
        let zig = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 10)]
        let s = PenRules.smooth(zig, steps: 8)
        check(s.count == 1 + 3 * 8, "8 samples per segment: \(s.count)")
        check(near(s[0], zig[0]) && near(s[8], zig[1]) && near(s[16], zig[2]) && near(s[24], zig[3]), "the curve passes through each point")
        check(!s.contains { near($0, CGPoint(x: 10, y: 10)) == false && $0.y > 10.9 }, "no big overshoot at a corner")
        check(s[4].y > 4.9 && s[4].x > 4 && s[4].x < 6, "between points it bends, not a straight line: \(s[4])")
        let straight = PenRules.smooth([CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 5)])
        check(straight.allSatisfy { abs($0.y - 5) < 0.0001 }, "a straight stroke stays straight")
        check(PenRules.smooth([CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]).count == 2, "2 points: the line itself")

        // the box
        let b = PenRules.box([CGPoint(x: 40, y: 30), CGPoint(x: 12, y: 80), CGPoint(x: 95, y: 55)])
        check(b == CGRect(x: 12, y: 30, width: 83, height: 50), "box: \(b)")
        check(PenRules.box([]).isNull, "no points, no box")
        check(!PenRules.long([CGPoint(x: 5, y: 5), CGPoint(x: 6, y: 7)]) && PenRules.long([CGPoint(x: 5, y: 5), CGPoint(x: 9, y: 5)]), "a stroke counts from 4 px")
        check(PenRules.distance(CGPoint(x: 10, y: 3), [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0)]) == 3, "distance to the stroke")

        // in the model: added with its points, one undo takes back one stroke
        var m = Markup(size: CGSize(width: 400, height: 300))
        func stroke(_ pts: [CGPoint]) -> PicMark { var p = PicMark(tool: .pen, from: pts[0], to: pts[pts.count - 1]); p.points = pts; return p }
        m.add(stroke([CGPoint(x: 5, y: 5), CGPoint(x: 6, y: 5)]))
        check(m.marks.isEmpty, "a 1 px stroke is a click, not a mark")
        m.add(stroke((0...60).map { CGPoint(x: 50 + CGFloat($0), y: 100 + 20 * CGFloat(Foundation.sin(Double($0) / 10))) }))
        m.add(stroke([CGPoint(x: 300, y: 50), CGPoint(x: 330, y: 90), CGPoint(x: 500, y: 120)]))   // runs off the picture
        check(m.marks.count == 2 && m.marks.allSatisfy { $0.tool == .pen }, "2 strokes")
        check(m.marks[1].points.last == CGPoint(x: 400, y: 120) && m.marks[1].rect.maxX == 400, "points kept on the picture")
        check(m.marks[0].points.count < 61 && m.marks[0].points.count > 20, "thinned on add: \(m.marks[0].points.count)")
        check(m.hit(CGPoint(x: 80, y: 100 + 20 * CGFloat(Foundation.sin(3.0))), slop: 2) == 0, "a click on the stroke picks it")
        check(m.hit(CGPoint(x: 80, y: 160), slop: 2) == nil, "a click inside its box but off the line does not")
        m.move(0, by: 10, -5)
        check(m.marks[0].points[0] == CGPoint(x: 60, y: 95) && m.marks[0].rect.minX == 60, "moving moves every point")
        m.undo()
        check(m.marks[0].points[0] == CGPoint(x: 50, y: 100), "undo the move")
        m.undo()
        check(m.marks.count == 1, "one ⌘Z takes back one stroke")
        m.redo()
        check(m.marks.count == 2, "redo puts it back")
        check(Markup.key(35, cmd: false, shift: false) == .tool(.pen), "P picks the pen")
        check(MarkTool.pen.key == "P" && MarkTool.arrow.key == "1" && MarkTool.allCases[1] == .pen, "the pill: the pen next to the arrow, its key P")

        // the Marks text: the count and the box, never the point list; the crop moves it
        m.add(PicMark(tool: .crop, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 400, y: 300)))
        let sm = m.shotMarks
        check(sm.count == 2 && sm.allSatisfy { $0.kind == "pen" }, "both strokes in the shot marks")
        let first = sm[0]
        check(first.x == 10 && first.points?.first == [10, 60], "crop origin taken off: \(first.x),\(first.y) \(first.points?.first ?? [])")
        let lines = ShotPack.markLines(sm)
        let want = "- " + PenRules.line(points: first.points!.count, x0: first.x, y0: first.y, x1: first.x + first.w, y1: first.y + first.h)
        check(lines[0] == want && lines[0].hasPrefix("- pen, ") && lines[0].contains(" points, box "), "the Marks line: \(lines[0])")
        check(!lines[0].contains("[") && lines[0].filter { $0 == "," }.count == 4, "no point list in the text: 2 commas of words, 2 in the corners")
        check(PenRules.line(points: 1, x0: 1, y0: 2, x1: 3, y1: 4) == "pen, 1 point, box 1,2 to 3,4", "one point")

        // shot.json and back ("mark up again"): the same stroke
        let back = Markup.picMarks(sm, crop: m.shotCrop)
        check(back.first?.tool == .pen && back.first?.points == m.marks[0].points.map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }, "points survive shot.json, to the whole pixel")
        let json = try? JSONEncoder().encode(sm[0]), dec = json.flatMap { try? JSONDecoder().decode(ShotMark.self, from: $0) }
        check(dec == sm[0], "a pen mark round-trips through JSON")
        let old = try? JSONDecoder().decode(ShotMark.self, from: Data(#"{"kind":"box","x":1,"y":2,"w":3,"h":4,"text":""}"#.utf8))
        check(old?.points == nil && old?.kind == "box", "an older shot.json without points still reads")

        if failures > 0 { print("pen rules: \(failures) failed"); exit(1) }
        print("pen rules: all checks passed")
    }
}
