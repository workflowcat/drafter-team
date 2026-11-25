// The markup pen (17 November 2026; Andrii: "I can see the highlighting, but all of those are boxes. Would be nice to
// be able to draw as well."), pure: a freehand stroke's points thinned while he draws, drawn as a Catmull-Rom curve
// through them, its bounding box, and its line in the "Marks" text (the point count and the box, never the full list).
// The mark itself is a PicMark with tool .pen (app/MarkupRules.swift); drawing in app/Markup.swift. Tests:
// tests/pen_rules.swift.
import Foundation
import CoreGraphics

enum PenRules {
    /// Fewer points for the same stroke: a point closer than `gap` to the last kept one is dropped. The first and the
    /// last point always stay, so the stroke ends where the mouse let go.
    static func thin(_ pts: [CGPoint], gap: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for p in pts.dropFirst().dropLast() where hypot(p.x - out.last!.x, p.y - out.last!.y) >= gap { out.append(p) }
        let end = pts[pts.count - 1]
        if let l = out.last, out.count > 1, hypot(end.x - l.x, end.y - l.y) < gap / 2 { out[out.count - 1] = end } else { out.append(end) }
        return out
    }

    /// The stroke as a smooth line: a uniform Catmull-Rom curve through every point, `steps` samples per segment.
    /// The curve passes through each point he drew, so it never strays from the stroke; ends are held by repeating them.
    static func smooth(_ pts: [CGPoint], steps: Int = 8) -> [CGPoint] {
        guard pts.count > 2, steps > 1 else { return pts }
        var out = [pts[0]]
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                func c(_ a: CGFloat, _ b: CGFloat, _ cc: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + cc) * t + (2 * a - 5 * b + 4 * cc - d) * t2 + (-a + 3 * b - 3 * cc + d) * t3)
                }
                out.append(CGPoint(x: c(p0.x, p1.x, p2.x, p3.x), y: c(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        return out
    }

    /// The smallest box holding every point; .null for none.
    static func box(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .null }
        var x0 = f.x, y0 = f.y, x1 = f.x, y1 = f.y
        for p in pts { x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// A stroke counts once it reaches 4 px from where it started (as a drag does for the other tools).
    static func long(_ pts: [CGPoint]) -> Bool {
        guard let f = pts.first else { return false }
        return pts.contains { hypot($0.x - f.x, $0.y - f.y) >= 4 }
    }

    /// The nearest a point comes to the stroke (its straight segments).
    static func distance(_ p: CGPoint, _ pts: [CGPoint]) -> CGFloat {
        guard let f = pts.first else { return .infinity }
        guard pts.count > 1 else { return hypot(p.x - f.x, p.y - f.y) }
        var best = CGFloat.infinity
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1], dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
            let t = l2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
        }
        return best
    }

    /// Its line in the "Marks" text: "pen, 42 points, box 10,20 to 300,180".
    static func line(points n: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> String {
        "pen, \(n) point\(n == 1 ? "" : "s"), box \(x0),\(y0) to \(x1),\(y1)"
    }
}
