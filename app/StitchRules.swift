// Scrolling capture: how frames of one screen region, taken while the user scrolls, join into one tall picture
// (17 November 2026, like CleanShot X and Shottr; the capture: app/ScrollShot.swift). Each frame becomes one row
// signature per pixel row; two frames are compared by rows. A fixed header and footer (rows equal in place) stay
// once; the part between them moved up by `shift` rows, and only the new rows at its foot are added.
// Pure (Foundation only), tested in tests/stitch_rules.swift.
import Foundation

enum StitchRules {
    /// How the next frame sits on the last kept one: the moving part went up `shift` rows (0: nothing new);
    /// `top` and `bottom` rows are fixed (a sticky header or footer) and are not stitched again.
    struct Match: Equatable { var shift: Int; var top: Int; var bottom: Int }

    /// The least overlap (rows of the moving part both frames share) that counts as a match: the user scrolled less than a
    /// frame; more and the frames cannot be joined (the user scrolled too fast).
    static let minOverlap = 24
    /// The share of compared rows that must be equal at the chosen shift.
    static let minRatio = 0.92
    /// The tallest picture, in pixels; the capture stops adding rows there.
    static let maxHeight = 30_000

    /// One signature per row of an 8-bit grey bitmap (`width` pixels a row, `rows` rows). Values are cut to 5 bits so
    /// a pixel of anti-aliasing noise does not split two equal rows.
    static func signatures(_ grey: [UInt8], width: Int, rows: Int) -> [UInt64] {
        guard width > 0, rows > 0, grey.count >= width * rows else { return [] }
        var out = [UInt64](repeating: 0, count: rows)
        for r in 0..<rows {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            let base = r * width
            for c in 0..<width { h = (h ^ UInt64(grey[base + c] >> 3)) &* 0x100_0000_01b3 }
            out[r] = h
        }
        return out
    }

    /// The next frame against the last kept one (same size). nil: no shift fits (the user scrolled up, or too far at once):
    /// the frame is skipped and the last kept one stays.
    static func match(_ prev: [UInt64], _ next: [UInt64]) -> Match? {
        let h = prev.count
        guard h > 0, next.count == h else { return nil }
        if prev == next { return Match(shift: 0, top: 0, bottom: 0) }
        let cap = h / 3
        var top = 0; while top < cap, prev[top] == next[top] { top += 1 }
        var bottom = 0; while bottom < cap, prev[h - 1 - bottom] == next[h - 1 - bottom] { bottom += 1 }
        let m = Array(prev[top..<(h - bottom)]), n = Array(next[top..<(h - bottom)])
        let l = m.count
        guard l > minOverlap else { return nil }
        // rows that occur once in the last frame's moving part: they tell shifts apart (blank rows match everywhere)
        var seen: [UInt64: Int] = [:]
        for s in m { seen[s, default: 0] += 1 }
        var best: (d: Int, score: Double)? = nil
        for d in 1...(l - minOverlap) {
            var equal = 0, keyEqual = 0, keys = 0
            for i in 0..<(l - d) {
                let same = n[i] == m[i + d]
                if same { equal += 1 }
                if seen[m[i + d]] == 1 { keys += 1; if same { keyEqual += 1 } }
            }
            let ratio = Double(equal) / Double(l - d)
            guard ratio >= minRatio else { continue }
            // with distinctive rows, they decide; a frame of blank rows alone does not count
            let score = keys >= 4 ? Double(keyEqual) / Double(keys) : (keys == 0 ? 0 : ratio * 0.5)
            if score > (best?.score ?? 0) + 1e-9 { best = (d, score) }
        }
        guard let b = best, b.score >= minRatio else { return nil }
        return Match(shift: b.d, top: top, bottom: bottom)
    }

    /// The rows of `next` (frame `h` rows tall) to add for a match: the new foot of the moving part.
    static func newRows(_ m: Match, height h: Int) -> Range<Int> {
        let end = h - m.bottom
        return max(m.top, end - m.shift)..<end
    }

    /// The tall picture's height: the first frame without its footer, every new strip, the last frame's footer.
    static func height(first h: Int, strips: [Int], footer: Int) -> Int {
        min(maxHeight, h - footer + strips.reduce(0, +) + footer)
    }
}
