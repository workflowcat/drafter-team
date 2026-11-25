// swiftc -parse-as-library app/StitchRules.swift tests/stitch_rules.swift -o app/build/stitch-rules-test && app/build/stitch-rules-test
import Foundation

@main
struct StitchRulesTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL: \(what)") } }

    /// A made-up page: row i of the page has its own signature, some rows blank (0), as text lines with gaps.
    static func page(_ n: Int) -> [UInt64] {
        var out: [UInt64] = []
        for i in 0..<n { let v: UInt64 = UInt64(i) &* 2_654_435_761 &+ 17; out.append(i % 7 == 3 ? 0 : v) }
        return out
    }
    /// A frame of `h` rows showing the page from row `y`, with a fixed header and footer.
    static func frame(_ p: [UInt64], y: Int, h: Int, header: Int = 0, footer: Int = 0) -> [UInt64] {
        let head: [UInt64] = (0..<header).map { UInt64(900_000 + $0) }
        let foot: [UInt64] = (0..<footer).map { UInt64(800_000 + $0) }
        let mid: [UInt64] = Array(p[(y + header)..<(y + h - footer)])
        return head + mid + foot
    }

    static func main() {
        let p = page(2000)
        // the same frame: nothing new
        let a = frame(p, y: 0, h: 400)
        check(StitchRules.match(a, a) == .init(shift: 0, top: 0, bottom: 0), "same frame: shift 0")
        // scrolled down 120 rows
        let b = frame(p, y: 120, h: 400)
        check(StitchRules.match(a, b)?.shift == 120, "scrolled 120: \(String(describing: StitchRules.match(a, b)))")
        check(StitchRules.newRows(StitchRules.match(a, b)!, height: 400) == 280..<400, "the new foot: rows 280..<400")
        // a sticky header and footer stay out of the shift
        let c = frame(p, y: 0, h: 400, header: 30, footer: 20), d = frame(p, y: 90, h: 400, header: 30, footer: 20)
        let m = StitchRules.match(c, d)
        check(m == .init(shift: 90, top: 30, bottom: 20), "header 30, footer 20, shift 90: \(String(describing: m))")
        check(StitchRules.newRows(m!, height: 400) == 290..<380, "the new rows sit above the footer")
        // scrolled up, or too far at once: no match, the frame is skipped
        check(StitchRules.match(b, a) == nil, "scrolled up: skipped")
        check(StitchRules.match(a, frame(p, y: 390, h: 400)) == nil, "too far (10 rows overlap): skipped")
        // a frame of blank rows only never matches a shift
        let blank = [UInt64](repeating: 0, count: 400), blank2 = [UInt64](repeating: 0, count: 399) + [5]
        check(StitchRules.match(blank, blank2) == nil, "blank frames: no guess")
        // stitching a whole scroll gives the page back
        var kept = frame(p, y: 0, h: 300), out = kept
        for y in stride(from: 70, through: 1700, by: 70) {
            let f = frame(p, y: y, h: 300)
            guard let mm = StitchRules.match(kept, f) else { check(false, "step \(y) matched"); break }
            out += f[StitchRules.newRows(mm, height: 300)]
            kept = f
        }
        check(out == Array(p[0..<1980]), "a whole scroll stitches the page back, rows 0..<1980 (\(out.count) rows)")
        // signatures: anti-aliasing noise (low bits) does not split rows
        let g1: [UInt8] = [10, 200, 30, 40], g2: [UInt8] = [12, 201, 31, 46]
        check(StitchRules.signatures(g1, width: 4, rows: 1) == StitchRules.signatures(g2, width: 4, rows: 1), "noise below 8 grey levels is the same row")
        check(StitchRules.signatures(g1, width: 2, rows: 2).count == 2, "one signature per row")
        check(StitchRules.height(first: 400, strips: [100, 50], footer: 20) == 550, "height: first + strips")
        check(StitchRules.height(first: 400, strips: [40_000], footer: 0) == StitchRules.maxHeight, "height is capped")
        print(failed == 0 ? "stitch rules: all passed" : "stitch rules: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
