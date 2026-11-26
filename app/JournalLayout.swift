// The journal adapts to its window (soft round, 14 November 2026; the user: "make it adaptable, like a resizable
// window", "more navigable, more movable"). Pure rules, tested in tests/journal_layout.swift:
// - breakpoints: wide = three panes; under 900 pt the reader is a slide-over (Return opens it, Esc closes it); under
//   640 pt the left pane is a strip of glyphs;
// - the split: each pane has a minimum, a maximum and a width to go back to (double-click its divider); dragged under
//   its minimum it collapses;
// - the gallery: columns from the pane's width and the card size, card heights per size step, the arrow keys in the
//   grid (Up and Down keep the column across group labels and chunk headers, Left and Right wrap);
// - back and forward through what the user looked at, like a browser;
// - the order of pinned items the user dragged (the stored history never moves);
// - the window frame restored inside the screen it opens on.
import Foundation
import CoreGraphics

enum JournalLayout {
    static let wide: Double = 900, narrow: Double = 640
    static let minWindow = (w: 520.0, h: 380.0)

    enum Side: Equatable { case full, strip, hidden }
    enum Reader: Equatable { case pane, over, closed }

    /// The panes for a width. `sidebar`: the user wants the left pane; `reader`: the user's choice for the reader (nil: the default,
    /// open for the list, closed for the gallery so the cards get the room).
    static func panes(width: Double, sidebar: Bool, reader: Bool?, gallery: Bool) -> (side: Side, reader: Reader) {
        let side: Side = !sidebar ? .hidden : width < narrow ? .strip : .full
        if width < wide { return (side, .over) }
        return (side, (reader ?? !gallery) ? .pane : .closed)
    }

    // MARK: the split

    struct Pane: Equatable {
        let min: Double, max: Double, start: Double
        static let sidebar = Pane(min: 188, max: 340, start: 232)
        static let reader = Pane(min: 300, max: 680, start: 420)
        /// Dragged this far under its minimum, the pane collapses.
        var collapseAt: Double { min - 48 }
    }
    /// A divider dragged by `by` from `from`: the new width, or collapsed (the width it had is kept to come back to).
    static func drag(_ p: Pane, from: Double, by: Double) -> (width: Double, collapsed: Bool) {
        let w = from + by
        if w < p.collapseAt { return (from, true) }
        return (Swift.min(p.max, Swift.max(p.min, w)), false)
    }
    /// Double-click on a divider: the pane's own width again.
    static func reset(_ p: Pane) -> Double { p.start }
    /// A width read back from the settings, inside the pane's limits.
    static func kept(_ p: Pane, _ w: Double?) -> Double { w.map { Swift.min(p.max, Swift.max(p.min, $0)) } ?? p.start }

    // MARK: the gallery

    /// Card sizes: small, medium, large. The minimum card width and the one card height of each step.
    /// Wire round (15 November 2026; the lead: "a two-line text sits in a card built for seven lines"): a card is as
    /// tall as its text lines need. Medium holds 4 lines of 13 pt text, large 7 of 14.5 pt; small stays 112. A card is
    /// `cardTop` + lines + `cardFoot` (the foot line with the kind mark, the trail, the chips and the time).
    static let cardMin: [Double] = [180, 224, 300]
    static let textSize: [Double] = [12, 13, 14.5]
    static let textLines: [Int] = [4, 4, 7]
    static let cardTop: Double = 9, cardFoot: Double = 28
    /// One text line: the font's line (about 1.22 × its size for the system font) plus the 3 pt spacing.
    static func lineHeight(_ s: Int) -> Double { textSize[step(s)] * 1.22 + 3 }
    static let cardHeight: [Double] = [112, (cardTop + Double(textLines[1]) * lineHeight(1) + cardFoot).rounded(.up),
                                       (cardTop + Double(textLines[2]) * lineHeight(2) + cardFoot).rounded(.up)]
    static let gap: Double = 10, pad: Double = 16
    /// The page's own rows: a chunk header, a part of the day ("Morning"), a session label strip.
    static let chunkH: Double = 44, partH: Double = 22, labelH: Double = 22

    static func step(_ s: Int) -> Int { Swift.max(0, Swift.min(2, s)) }
    /// Columns for a pane `width` at size step `size`: as many cards of the minimum width as fit, 1 to 6.
    static func columns(width: Double, size: Int) -> Int {
        let room = width - 2 * pad + gap
        return Swift.max(1, Swift.min(6, Int((room / (cardMin[step(size)] + gap)).rounded(.down))))
    }
    /// The width of one card when `cols` share the pane.
    static func cardWidth(width: Double, cols: Int) -> Double {
        Swift.max(0, (width - 2 * pad - gap * Double(cols - 1)) / Double(Swift.max(1, cols)))
    }

    /// Each column advances by its own card height. Logical columns stay fixed for the arrow keys.
    /// `before` reserves a session label above that card only; neighboring cards never inherit that space.
    static func pack(heights: [Double], cols: Int, before: [Double] = []) -> (tops: [Double], bottom: Double) {
        guard !heights.isEmpty, cols > 0 else { return ([], 0) }
        var ends = Array(repeating: 0.0, count: cols), tops: [Double] = []
        for (i, height) in heights.enumerated() {
            let col = i % cols
            let top = ends[col] + (i < before.count ? max(0, before[i]) : 0)
            tops.append(top)
            ends[col] = top + max(0, height) + gap
        }
        return (tops, ends.max() ?? 0)
    }

    /// Header metadata loses whole facts, never the end of a word. The item count (last fact) has priority.
    static func headerSummary(_ text: String, fits: (String) -> Bool) -> String {
        if fits(text) { return text }
        let parts = text.components(separatedBy: " · ")
        guard let last = parts.last, fits(last) else { return "" }
        var kept = last
        for part in parts.dropLast().reversed() {
            let candidate = part + " · " + kept
            if fits(candidate) { kept = candidate }
        }
        return kept
    }

    /// Where a card is: its group (a session label or a chunk's own cards) and its place in it.
    struct Spot: Equatable { var group: Int; var index: Int }
    /// The arrow keys in the grid. `counts`: cards per group, in order; `cols`: cards per row (each group starts a new
    /// row). dy: rows up (-) or down (+), keeping the column and crossing group labels; dx: one card back or on,
    /// wrapping to the row before or after. At an edge it stays.
    static func move(_ s: Spot, dx: Int = 0, dy: Int = 0, counts: [Int], cols: Int) -> Spot {
        guard s.group >= 0, s.group < counts.count, counts[s.group] > 0, cols > 0 else { return s }
        if dx != 0 {
            var flat = counts[..<s.group].reduce(0, +) + s.index + dx
            let total = counts.reduce(0, +)
            flat = Swift.max(0, Swift.min(total - 1, flat))
            var g = 0
            while flat >= counts[g] { flat -= counts[g]; g += 1 }
            return Spot(group: g, index: flat)
        }
        var cur = s
        for _ in 0..<abs(dy) {
            let col = cur.index % cols, row = cur.index / cols, rows = (counts[cur.group] + cols - 1) / cols
            if dy > 0 {
                if row + 1 < rows { cur.index = Swift.min(counts[cur.group] - 1, (row + 1) * cols + col); continue }
                guard let g = counts.indices.first(where: { $0 > cur.group && counts[$0] > 0 }) else { break }
                cur = Spot(group: g, index: Swift.min(col, counts[g] - 1))
            } else {
                if row > 0 { cur.index = (row - 1) * cols + col; continue }
                guard let g = counts.indices.last(where: { $0 < cur.group && counts[$0] > 0 }) else { break }
                let last = (counts[g] - 1) / cols
                cur = Spot(group: g, index: Swift.min(counts[g] - 1, last * cols + col))
            }
        }
        return cur
    }
    /// The card is in the first row of the first group (↑ goes to the search field).
    static func topRow(_ s: Spot, counts: [Int], cols: Int) -> Bool {
        (counts.firstIndex { $0 > 0 } ?? 0) == s.group && s.index < cols
    }

    // MARK: back and forward

    /// One place the user looked at: the chosen line, the filter, the grouping, the search, the view.
    struct Place: Equatable { var chosen: String?; var filter: String; var group: String; var query: String; var view: String }
    struct History: Equatable {
        var back: [Place] = [], forward: [Place] = []
        var current: Place?
        var at: Double = -1e9
        var canBack: Bool { !back.isEmpty }
        var canForward: Bool { !forward.isEmpty }
    }
    /// A new place. A move of the selection alone, within `coalesce` seconds of the last one, replaces it (arrowing
    /// through a list is one step back, not forty). A new place clears forward.
    static func record(_ h0: History, _ p: Place, at t: Double, coalesce: Double = 1.5, cap: Int = 100) -> History {
        var h = h0
        guard let cur = h.current else { h.current = p; h.at = t; return h }
        if cur == p { return h }
        let onlyChosen = cur.filter == p.filter && cur.group == p.group && cur.query == p.query && cur.view == p.view
        if onlyChosen, t - h.at < coalesce { h.current = p; h.at = t; return h }
        h.back.append(cur); if h.back.count > cap { h.back.removeFirst() }
        h.forward = []
        h.current = p; h.at = t
        return h
    }
    static func goBack(_ h0: History) -> (History, Place?) {
        var h = h0
        guard let p = h.back.popLast(), let cur = h.current else { return (h, nil) }
        h.forward.append(cur); h.current = p; h.at = -1e9
        return (h, p)
    }
    static func goForward(_ h0: History) -> (History, Place?) {
        var h = h0
        guard let p = h.forward.popLast(), let cur = h.current else { return (h, nil) }
        h.back.append(cur); h.current = p; h.at = -1e9
        return (h, p)
    }

    // MARK: pinned order

    /// The pinned items in the user's order: the ones the user placed, in that order, then new pins as they come (newest first).
    static func pinned(_ order: [String], pins: [String]) -> [String] {
        let set = Set(pins)
        let kept = order.filter { set.contains($0) }
        let known = Set(kept)
        return pins.filter { !known.contains($0) } + kept
    }
    /// Items dragged to sit before `before` (nil: at the end). Only the display order changes.
    static func move(_ order: [String], _ ids: [String], before: String?) -> [String] {
        let moving = order.filter { ids.contains($0) } + ids.filter { !order.contains($0) }
        var rest = order.filter { !ids.contains($0) }
        let at = before.flatMap { b in rest.firstIndex(of: b) } ?? rest.count
        rest.insert(contentsOf: moving, at: at)
        return rest
    }

    // MARK: the window frame

    /// A frame kept for a screen, put back inside that screen's visible frame and at least the minimum size.
    static func restore(_ f: CGRect, visible v: CGRect) -> CGRect {
        let w = Swift.min(v.width, Swift.max(minWindow.w, f.width)), h = Swift.min(v.height, Swift.max(minWindow.h, f.height))
        let x = Swift.min(Swift.max(v.minX, f.minX), v.maxX - w), y = Swift.min(Swift.max(v.minY, f.minY), v.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
    /// The key a frame is kept under: the screen's size, so the same display gets its own frame back.
    static func screenKey(_ v: CGRect) -> String { "\(Int(v.width))x\(Int(v.height))" }
}
