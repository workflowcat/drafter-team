// Markup's model (round three, Part C, 14 November 2026): the marks on a captured picture, the tool keys, undo and
// redo, the crop, and how a point in the editor maps onto the picture. Pure (CoreGraphics types only), tested in
// tests/shot_rules.swift. Drawing and the editor panel: app/Markup.swift. Our own layer, no dependency (the options
// weighed: docs/rounds/2026-11-14-quick.md, Part C).
// Look round (15 November 2026): five colours (R Y G B V), three stroke sizes ([ and ]), a click on a mark selects it,
// a drag moves it, ⌫ deletes it; undo and redo take back every change (add, move, delete, recolour) as whole states.
import Foundation
import CoreGraphics

// The pen (17 November 2026, app/PenRules.swift): a freehand stroke, key P (digits are given back, docs/plans/2026-11-17-key-map.md),
// next to the arrow in the pill. Raw values stay as they were (1-7 are the tools' keys); the pen is 8.
enum MarkTool: Int, CaseIterable { case arrow = 1, pen = 8, box = 2, highlight = 3, label = 4, pixelate = 5, crop = 6, pin = 7
    /// The key that picks it, as the pill shows it.
    var key: String { self == .pen ? "P" : "\(rawValue)" }
    var word: String {
        switch self { case .arrow: return "arrow"; case .pen: return "pen"; case .box: return "box"; case .highlight: return "highlight"
        case .label: return "text"; case .pixelate: return "blur"; case .crop: return "crop"; case .pin: return "pin" }
    }
    /// Takes a click (a point), not a drag.
    var clicks: Bool { self == .label || self == .pin }
    /// The symbol on its pill button (Native.symbols in app/Look.swift).
    var glyph: String {
        switch self { case .arrow: return "arrow-up-right"; case .pen: return "scribble"; case .box: return "square"; case .highlight: return "highlight"
        case .label: return "text"; case .pixelate: return "blur"; case .crop: return "crop"; case .pin: return "circle-number" }
    }
}

/// One mark, in picture pixels (origin top-left).
struct PicMark: Equatable {
    var tool: MarkTool
    var from: CGPoint
    var to: CGPoint
    var text = ""
    var n = 0                             // a pin's number (1, 2, 3...), given when it is added
    var color = 0                         // Markup.colors index (0 red)
    var size = 1                          // 0 thin, 1 normal, 2 thick
    var points: [CGPoint] = []            // a pen stroke, thinned (from and to: its first and last point)
    var rect: CGRect {
        if tool == .pen, !points.isEmpty { return PenRules.box(points) }
        return CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(from.x - to.x), height: abs(from.y - to.y))
    }
    func moved(_ dx: CGFloat, _ dy: CGFloat) -> PicMark {
        var m = self; m.from = CGPoint(x: from.x + dx, y: from.y + dy); m.to = CGPoint(x: to.x + dx, y: to.y + dy)
        m.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return m
    }
}

struct Markup: Equatable {
    let size: CGSize                      // the picture, in pixels
    var tool = MarkTool.arrow
    var color = 0                         // the colour the next mark gets
    var stroke = 1                        // the size the next mark gets
    var selected: Int?                    // the mark picked by a click (an index into marks)
    private(set) var marks: [PicMark] = []
    private var past: [[PicMark]] = []    // whole states before each change, for undo
    private var future: [[PicMark]] = []

    init(size: CGSize) { self.size = size }

    /// Keys 1-7 pick the tool (key codes 18 19 20 21 23 22 26 on any layout), P the pen (code 35).
    static let toolCodes: [Int: MarkTool] = [18: .arrow, 19: .box, 20: .highlight, 21: .label, 23: .pixelate, 22: .crop, 26: .pin, 35: .pen]

    // MARK: colours and sizes

    /// The five mark colours (red, yellow, green, blue, violet; fixed values,
    /// the same in both appearances because they are drawn into the picture). Key: the letter that picks it.
    static let colors: [(name: String, key: String, code: Int, rgb: UInt32)] = [
        ("red", "R", 15, 0xd0603f), ("yellow", "Y", 16, 0xe0a90f), ("green", "G", 5, 0x379d70),
        ("blue", "B", 11, 0x4a7dd6), ("violet", "V", 9, 0x9268cc),
    ]
    static let sizeWords = ["thin", "normal", "thick"]
    static let sizeFactors: [CGFloat] = [0.7, 1.25, 2]

    /// What a key does in the editor (no text being typed).
    enum Key: Equatable { case tool(MarkTool), color(Int), sizeStep(Int), undo, redo, delete, done, back, addAnother, none }
    static func key(_ code: Int, cmd: Bool, shift: Bool) -> Key {
        if cmd { return code == 6 ? (shift ? .redo : .undo) : code == 45 ? .addAnother : .none }
        switch code {
        case 53: return .back
        case 36, 76: return .done
        case 51, 117: return .delete
        case 33: return .sizeStep(-1)      // [
        case 30: return .sizeStep(1)       // ]
        default:
            if let t = toolCodes[code] { return .tool(t) }
            if let i = colors.firstIndex(where: { $0.code == code }) { return .color(i) }
            return .none
        }
    }

    // MARK: changes (each one undoable)

    private mutating func change(_ f: (inout [PicMark]) -> Void) {
        let before = marks
        f(&marks)
        guard marks != before else { return }
        past.append(before); future = []
    }

    /// A finished drag; a drag shorter than 4 px is a click (the label takes a click with its text, the pin any click).
    /// Crop replaces any older crop. A pin gets the next number.
    mutating func add(_ m: PicMark) {
        let len = hypot(m.to.x - m.from.x, m.to.y - m.from.y)
        switch m.tool {
        case .label: guard !m.text.isEmpty else { return }
        case .pin: break
        case .pen: guard PenRules.long(m.points) else { return }
        default: guard len >= 4 else { return }
        }
        var m = m
        m.from = clamp(m.from); m.to = clamp(m.to)
        if m.tool == .pen {
            m.points = PenRules.thin(m.points.map(clamp), gap: 2)
            m.from = m.points[0]; m.to = m.points[m.points.count - 1]
        }
        if m.tool == .pin, m.n == 0 { m.n = nextPin }
        change { ms in
            if m.tool == .crop { ms.removeAll { $0.tool == .crop } }
            ms.append(m)
        }
        selected = nil
    }
    /// The number the next pin gets: one more than the highest pin there is.
    var nextPin: Int { (marks.filter { $0.tool == .pin }.map(\.n).max() ?? 0) + 1 }
    mutating func undo() { if let s = past.popLast() { future.append(marks); marks = s; selected = nil } }
    mutating func redo() { if let s = future.popLast() { past.append(marks); marks = s; selected = nil } }
    var canUndo: Bool { !past.isEmpty }

    /// The selected mark moved by (dx, dy) picture pixels, kept on the picture (a mark keeps its shape at an edge).
    mutating func move(_ i: Int, by dx: CGFloat, _ dy: CGFloat) {
        guard marks.indices.contains(i) else { return }
        let d = Self.keepInside(marks[i], dx, dy, size)
        change { $0[i] = $0[i].moved(d.dx, d.dy) }
    }
    /// How far a mark may go: the move cut so the mark's points stay on the picture.
    static func keepInside(_ m: PicMark, _ dx: CGFloat, _ dy: CGFloat, _ size: CGSize) -> CGVector {
        let r = m.rect
        let x = min(max(dx, -r.minX), size.width - r.maxX), y = min(max(dy, -r.minY), size.height - r.maxY)
        return CGVector(dx: x, dy: y)
    }
    mutating func delete(_ i: Int) {
        guard marks.indices.contains(i) else { return }
        change { $0.remove(at: i) }
        selected = nil
    }
    /// A colour (or size) picked: the next marks get it, and the selected mark takes it too.
    mutating func pick(color c: Int) {
        guard Self.colors.indices.contains(c) else { return }
        color = c
        if let i = selected, marks.indices.contains(i) { change { $0[i].color = c } }
    }
    mutating func pick(size s: Int) {
        let s = min(max(s, 0), Self.sizeFactors.count - 1)
        stroke = s
        if let i = selected, marks.indices.contains(i) { change { $0[i].size = s } }
    }

    // MARK: picking a mark with the mouse

    /// The topmost mark under a point (picture pixels), nil for none. `slop`: how near counts, in picture pixels.
    /// Arrows by their line, boxes by their edge, highlights and blurs by their area, pins by their circle, labels by
    /// their box (`textWidth` measures a label's text; the default guesses from its length). The crop is not picked.
    func hit(_ p: CGPoint, slop: CGFloat, textWidth: ((PicMark) -> CGFloat)? = nil) -> Int? {
        for i in marks.indices.reversed() {
            let m = marks[i], lw = Self.stroke(size, level: m.size)
            switch m.tool {
            case .crop: continue
            case .arrow:
                if Self.distance(p, m.from, m.to) <= slop + lw * 2 { return i }
            case .pen:
                if PenRules.distance(p, m.points) <= slop + lw * 1.5 { return i }
            case .box:
                let r = m.rect, out = r.insetBy(dx: -(slop + lw), dy: -(slop + lw)), inn = r.insetBy(dx: slop + lw, dy: slop + lw)
                if out.contains(p), inn.isNull || !inn.contains(p) || inn.width <= 0 || inn.height <= 0 { return i }
            case .highlight, .pixelate:
                if m.rect.insetBy(dx: -slop, dy: -slop).contains(p) { return i }
            case .pin:
                let r = Self.pinRadius(size)
                if hypot(p.x - m.from.x, p.y - m.from.y) <= r + slop { return i }
                if !m.text.isEmpty, labelBox(m, at: CGPoint(x: m.from.x + r * 1.35, y: m.from.y), textWidth).insetBy(dx: -slop, dy: -slop).contains(p) { return i }
            case .label:
                if labelBox(m, at: m.from, textWidth).insetBy(dx: -slop, dy: -slop).contains(p) { return i }
            }
        }
        return nil
    }
    private func labelBox(_ m: PicMark, at a: CGPoint, _ tw: ((PicMark) -> CGFloat)?) -> CGRect {
        let fs = Self.labelSize(size), pad = fs * 0.35
        let w = tw?(m) ?? CGFloat(m.text.count) * fs * 0.56
        return CGRect(x: a.x, y: a.y - fs * 0.6 - pad / 2, width: w + 2 * pad, height: fs * 1.2 + pad)
    }
    /// The distance from a point to a segment.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// The crop (the last one), else the whole picture.
    var crop: CGRect {
        guard let c = marks.last(where: { $0.tool == .crop })?.rect, c.width >= 4, c.height >= 4 else { return CGRect(origin: .zero, size: size) }
        return c.integral.intersection(CGRect(origin: .zero, size: size))
    }
    private func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(0, p.x), size.width), y: min(max(0, p.y), size.height)) }

    /// The picture fitted into `box` (aspect kept, centred): its rectangle there and the scale.
    static func fit(_ size: CGSize, in box: CGRect) -> (rect: CGRect, scale: CGFloat) {
        let s = min(box.width / max(1, size.width), box.height / max(1, size.height), 1)
        let w = (size.width * s).rounded(), h = (size.height * s).rounded()
        return (CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h), s)
    }
    /// A point in the editor (flipped, top-left) to picture pixels.
    static func toPicture(_ p: CGPoint, fitted r: CGRect, scale s: CGFloat) -> CGPoint {
        CGPoint(x: ((p.x - r.minX) / s).rounded(), y: ((p.y - r.minY) / s).rounded())
    }
    /// Line width and label size for a picture this big (readable when it is pasted at its own size).
    static func stroke(_ size: CGSize) -> CGFloat { max(3, (max(size.width, size.height) / 260).rounded()) }
    /// The line width at a stroke size (0 thin, 1 normal, 2 thick).
    static func stroke(_ size: CGSize, level: Int) -> CGFloat {
        max(2, (stroke(size) * sizeFactors[min(max(level, 0), sizeFactors.count - 1)]).rounded())
    }
    static func labelSize(_ size: CGSize) -> CGFloat { max(16, (max(size.width, size.height) / 42).rounded()) }
    /// A pin's circle radius: big enough for two digits at the label size.
    static func pinRadius(_ size: CGSize) -> CGFloat { (labelSize(size) * 0.8).rounded() }
    /// How a highlight is drawn (17 November 2026; on dark screens the multiply marker came out as murky dark or brown
    /// boxes that read as shadows; screening the colour in still came out olive and brown). Over a light background: the
    /// marker as before, the colour multiplied in, text under it stays black. Over a dark one: a light fill (the colour
    /// mixed with white, laid over thinly, so it can only lighten) and an outline in the full colour, so it reads as a
    /// mark and never as a shadow. The background is measured round the mark (Markup.swift highlightSample), so a light
    /// text line on a dark window counts as dark.
    struct HighlightLook: Equatable {
        var lighten: Bool                 // a light fill laid over (dark background) instead of the multiply marker
        var fill: CGFloat                 // the fill's opacity
        var outline: Bool                 // a line in the full colour round it
    }
    /// Below this mean luminance (0 black, 1 white) the background counts as dark. 0.4: grey UI (mid-grey ~0.22) and
    /// dark mode count as dark; white, paper and light grey windows as light.
    static let darkBelow = 0.4
    static func highlightLook(background lum: Double) -> HighlightLook {
        lum < darkBelow ? HighlightLook(lighten: true, fill: 0.3, outline: true) : HighlightLook(lighten: false, fill: 0.72, outline: false)
    }
    /// The relative luminance of an sRGB colour (channels 0-1), as WCAG counts it.
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    /// Where the background is measured for a highlight: the mark grown by its own height on every side (at least 8 px),
    /// so the window round a text line decides, not the text under it.
    static func highlightSample(_ r: CGRect) -> CGRect { let g = max(8, r.height); return r.insetBy(dx: -g, dy: -g) }
    /// The mean luminance of RGBA pixels (8 bits each, alpha ignored); 1 (light) for none.
    static func meanLuminance(_ px: [UInt8]) -> Double {
        let n = px.count / 4
        guard n > 0 else { return 1 }
        var sum = 0.0
        for i in 0..<n { sum += luminance(Double(px[i * 4]) / 255, Double(px[i * 4 + 1]) / 255, Double(px[i * 4 + 2]) / 255) }
        return sum / Double(n)
    }

    /// The pixelate block: big enough that text under it cannot be read back.
    static func block(_ r: CGRect) -> Int { max(8, Int(min(r.width, r.height) / 6)) }
    /// The blur's Gaussian radius over the blocks: about one block, so the block edges melt and no stroke shows.
    static func blurRadius(_ r: CGRect) -> CGFloat { CGFloat(block(r)) * 0.9 }
}

// MARK: the marks as data (the shot pack, app/ShotPackRules.swift)

extension Markup {
    /// The marks in shot.png pixels: the crop's origin taken off, marks wholly outside the crop dropped, boxes clipped
    /// to it. The crop itself is not a mark (shot.json keeps it as `crop`).
    var shotMarks: [ShotMark] {
        let c = crop
        var out: [ShotMark] = []
        func px(_ v: CGFloat) -> Int { Int(v.rounded()) }
        for m in marks where m.tool != .crop {
            let a = CGPoint(x: m.from.x - c.minX, y: m.from.y - c.minY), b = CGPoint(x: m.to.x - c.minX, y: m.to.y - c.minY)
            let inside = CGRect(origin: .zero, size: c.size)
            switch m.tool {
            case .pin, .label:
                guard inside.contains(a) else { continue }
                out.append(ShotMark(kind: m.tool == .pin ? "pin" : "text", x: px(a.x), y: px(a.y), n: m.tool == .pin ? m.n : nil, text: m.text))
            case .arrow:
                guard inside.contains(a) || inside.contains(b) || inside.intersects(m.rect.offsetBy(dx: -c.minX, dy: -c.minY)) else { continue }
                out.append(ShotMark(kind: "arrow", x: px(a.x), y: px(a.y), toX: px(b.x), toY: px(b.y), text: m.text))
            case .pen:
                // the whole stroke (shot.json keeps it for "mark up again"); its box clipped to the crop
                let r = m.rect.offsetBy(dx: -c.minX, dy: -c.minY)
                guard inside.intersects(r.insetBy(dx: -1, dy: -1)) else { continue }
                let b = r.intersection(inside)
                var s = ShotMark(kind: "pen", x: px(b.minX), y: px(b.minY), w: px(b.width), h: px(b.height), text: m.text)
                s.points = m.points.map { [px($0.x - c.minX), px($0.y - c.minY)] }
                out.append(s)
            default:
                let r = m.rect.offsetBy(dx: -c.minX, dy: -c.minY).intersection(inside)
                guard !r.isNull, r.width > 0, r.height > 0 else { continue }
                let kind = m.tool == .pixelate ? "blur" : m.tool == .box ? "box" : "highlight"
                out.append(ShotMark(kind: kind, x: px(r.minX), y: px(r.minY), w: px(r.width), h: px(r.height), text: m.text))
            }
        }
        return out
    }
    /// The crop as shot.json keeps it: [x, y, w, h] in original.png pixels, nil when the picture is whole.
    var shotCrop: [Int]? {
        let c = crop
        return c.size == size && c.origin == .zero ? nil : [Int(c.minX), Int(c.minY), Int(c.width), Int(c.height)]
    }

    /// shot.json's marks back on original.png (for "mark up again" from the journal): the crop's origin added back,
    /// the crop itself as a crop mark (last, as the editor keeps it).
    static func picMarks(_ marks: [ShotMark], crop: [Int]?) -> [PicMark] {
        let dx = CGFloat(crop?.first ?? 0), dy = CGFloat(crop.map { $0.count > 1 ? $0[1] : 0 } ?? 0)
        func pt(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: CGFloat(x) + dx, y: CGFloat(y) + dy) }
        var out: [PicMark] = []
        for m in marks {
            let a = pt(m.x, m.y)
            switch m.kind {
            case "pin": var p = PicMark(tool: .pin, from: a, to: a, text: m.text); p.n = m.n ?? 0; out.append(p)
            case "text": out.append(PicMark(tool: .label, from: a, to: a, text: m.text))
            case "arrow": out.append(PicMark(tool: .arrow, from: a, to: pt(m.toX ?? m.x, m.toY ?? m.y), text: m.text))
            case "pen":
                let ps = (m.points ?? []).filter { $0.count == 2 }.map { pt($0[0], $0[1]) }
                guard let f = ps.first, let l = ps.last else { continue }
                var p = PicMark(tool: .pen, from: f, to: l, text: m.text); p.points = ps; out.append(p)
            default:
                let tool: MarkTool = m.kind == "blur" ? .pixelate : m.kind == "box" ? .box : .highlight
                out.append(PicMark(tool: tool, from: a, to: pt(m.x + m.w, m.y + m.h), text: m.text))
            }
        }
        if let c = crop, c.count == 4 {
            out.append(PicMark(tool: .crop, from: CGPoint(x: c[0], y: c[1]), to: CGPoint(x: c[0] + c[2], y: c[1] + c[3])))
        }
        return out
    }
}
