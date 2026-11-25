// Renders Drafter's app icon candidates. Colours: the fixed values in `T` below.
//   swift make_icon.swift <name>            Drafter.iconset + preview.png for one candidate; then
//                                           iconutil -c icns Drafter.iconset   (replaces Drafter.icns)
//   swift make_icon.swift --sheet <dir>     <dir>/<name>.png at 1024 for every candidate + <dir>/sheet.png
//   swift make_icon.swift --nib-sheet <dir> the same for the nib round + <dir>/nib-sheet.png
// Names: pixel, ghost, nib, strip, ibeam, pen (the old icon); nib-1 .. nib-5 (nib round). Drawing space is 1024 x 1024, y up;
// the plate follows the macOS grid: 824 px rounded square at a 100 px inset, nothing outside it.
import AppKit

// MARK: colours (fixed values for the icon)
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}
enum T {
    static let paper = hex(0x151517), card = hex(0x1c1c1f), soft = hex(0x222223), key = hex(0x2a2a2c)
    static let keyEdge = hex(0x444445), ink = hex(0xebebe7), muted = hex(0xb9bab5), faint = hex(0xa1a29d)
    static let coral = hex(0xd0603f), blue = hex(0x4a7dd6), mint = hex(0x379d70), violet = hex(0x9268cc)
    static let lPaper = hex(0xf3f3f2), lCard = hex(0xfbfbf7), lSoft = hex(0xe8e8e7), lInk = hex(0x141518)
    static let lPrimary = hex(0x333437), lCoral = hex(0xc04f31)
    static func ghost(_ a: CGFloat = 0.42) -> CGColor { hex(0xa1a29d, a) }
}

let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let plateR: CGFloat = 185

func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: min(rad, r.width / 2, r.height / 2), cornerHeight: min(rad, r.width / 2, r.height / 2), transform: nil) }

func fill(_ c: CGContext, _ p: CGPath, _ col: CGColor) { c.addPath(p); c.setFillColor(col); c.fillPath() }

/// The plate: a very soft top-to-bottom gradient and a hairline edge.
func drawPlate(_ c: CGContext, top: CGColor, bottom: CGColor, edge: CGColor) {
    let p = rr(plate, plateR)
    c.saveGState(); c.addPath(p); c.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    c.restoreGState()
    c.addPath(rr(plate.insetBy(dx: 3, dy: 3), plateR - 3)); c.setStrokeColor(edge); c.setLineWidth(6); c.strokePath()
}
func darkPlate(_ c: CGContext) { drawPlate(c, top: T.key, bottom: T.paper, edge: hex(0xffffff, 0.10)) }

/// A text-line bar: a pill of the given width starting at x, centred on y.
func bar(_ c: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, _ col: CGColor) {
    fill(c, rr(CGRect(x: x, y: y - h / 2, width: w, height: h), h / 2), col)
}
/// A vertical sound bar centred on (x, y).
func vbar(_ c: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, _ col: CGColor) {
    fill(c, rr(CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h), w / 2), col)
}

// MARK: Candidates

/// (a) pixel: a hand-placed pixel pen that writes a line; the line runs on as ghost pixels.
func drawPixel(_ c: CGContext) {
    darkPlate(c)
    let map = [
        "........ccc.",
        ".......cccc.",
        "......cccc..",
        ".....mmmm...",
        "....###m....",
        "...###m.....",
        "..###m......",
        ".fff........",
        ".ff.........",
        ".#..........",
        "............",
        "###.gg.ggg..",
    ]
    let n = CGFloat(map.count), cell: CGFloat = 54, gap: CGFloat = 5
    let ox = 512 - n * cell / 2, oy = 512 + n * cell / 2
    for (row, line) in map.enumerated() {
        for (col, ch) in line.enumerated() {
            let col0: CGColor?
            switch ch {
            case "#": col0 = T.ink
            case "m": col0 = T.muted
            case "c": col0 = T.coral
            case "f": col0 = T.faint
            case "g": col0 = T.ghost(0.5)
            default: col0 = nil
            }
            guard let fillCol = col0 else { continue }
            let r = CGRect(x: ox + CGFloat(col) * cell + gap / 2, y: oy - CGFloat(row + 1) * cell + gap / 2, width: cell - gap, height: cell - gap)
            c.setFillColor(fillCol); c.fill(r)
        }
    }
}

/// (b) ghost: two lines of writing, a coral caret, and grey ghost text after it.
func drawGhost(_ c: CGContext) {
    darkPlate(c)
    let h: CGFloat = 76, x0: CGFloat = 228
    bar(c, x: x0, y: 640, w: 420, h: h, T.ink)
    bar(c, x: x0 + 448, y: 640, w: 120, h: h, T.ink)
    bar(c, x: x0, y: 430, w: 230, h: h, T.ink)
    // caret
    fill(c, rr(CGRect(x: x0 + 262, y: 430 - 130, width: 40, height: 260), 20), T.coral)
    bar(c, x: x0 + 334, y: 430, w: 234, h: h, T.ghost(0.45))
}

/// (c) nib: a fountain-pen nib whose slit runs on into a sound wave.
func drawNib(_ c: CGContext) {
    darkPlate(c)
    let tip = CGPoint(x: 512, y: 452)
    let nib = CGMutablePath()
    nib.move(to: tip)
    nib.addCurve(to: CGPoint(x: 376, y: 664), control1: CGPoint(x: 470, y: 520), control2: CGPoint(x: 376, y: 590))
    nib.addLine(to: CGPoint(x: 376, y: 712))
    nib.addLine(to: CGPoint(x: 400, y: 712))   // shoulder
    nib.addLine(to: CGPoint(x: 400, y: 800))
    nib.addQuadCurve(to: CGPoint(x: 428, y: 828), control: CGPoint(x: 400, y: 828))
    nib.addLine(to: CGPoint(x: 596, y: 828))
    nib.addQuadCurve(to: CGPoint(x: 624, y: 800), control: CGPoint(x: 624, y: 828))
    nib.addLine(to: CGPoint(x: 624, y: 712))
    nib.addLine(to: CGPoint(x: 648, y: 712))
    nib.addLine(to: CGPoint(x: 648, y: 664))
    nib.addCurve(to: tip, control1: CGPoint(x: 648, y: 590), control2: CGPoint(x: 554, y: 520))
    nib.closeSubpath()
    fill(c, nib, T.ink)
    // breather hole and slit, cut in the plate's own colour
    c.setFillColor(T.soft)
    c.fillEllipse(in: CGRect(x: 512 - 32, y: 630 - 32, width: 64, height: 64))
    c.fill(CGRect(x: 512 - 9, y: tip.y, width: 18, height: 160))
    // sound wave: bars under the tip, the middle one is the coral ink drop
    let hs: [CGFloat] = [90, 170, 120, 250, 120, 170, 90]
    let w: CGFloat = 50, step: CGFloat = 84, y: CGFloat = 318
    for (i, hh) in hs.enumerated() {
        let x = 512 + (CGFloat(i) - 3) * step
        vbar(c, x: x, y: y, w: w, h: hh, i == 3 ? T.coral : (abs(i - 3) == 3 ? T.ghost(0.55) : T.muted))
    }
}

// MARK: Nib round (2026-11-16): five variations of `nib`

/// The `nib` outline, relative to its tip: `s` scales it, `wx` widens it.
func nibPath(tip: CGPoint, s: CGFloat = 1, wx: CGFloat = 1) -> CGMutablePath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tip.x + (x - 512) * s * wx, y: tip.y + (y - 452) * s) }
    let n = CGMutablePath()
    n.move(to: tip)
    n.addCurve(to: p(376, 664), control1: p(470, 520), control2: p(376, 590))
    n.addLine(to: p(376, 712)); n.addLine(to: p(400, 712)); n.addLine(to: p(400, 800))
    n.addQuadCurve(to: p(428, 828), control: p(400, 828))
    n.addLine(to: p(596, 828))
    n.addQuadCurve(to: p(624, 800), control: p(624, 828))
    n.addLine(to: p(624, 712)); n.addLine(to: p(648, 712)); n.addLine(to: p(648, 664))
    n.addCurve(to: tip, control1: p(648, 590), control2: p(554, 520))
    n.closeSubpath()
    return n
}

/// Fills the nib and cuts the breather hole and slit out of it (true holes, so any plate shows through).
func drawNibGlyph(_ c: CGContext, tip: CGPoint, s: CGFloat = 1, wx: CGFloat = 1, slit: CGFloat = 18, hole: CGFloat = 64,
                  slitLen: CGFloat = 160, col: CGColor = T.ink, angle: CGFloat = 0) {
    c.saveGState()
    c.translateBy(x: tip.x, y: tip.y); c.rotate(by: angle); c.translateBy(x: -tip.x, y: -tip.y)
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    fill(c, nibPath(tip: tip, s: s, wx: wx), col)
    c.setBlendMode(.clear)
    let hy = tip.y + 178 * s
    c.fillEllipse(in: CGRect(x: tip.x - hole / 2, y: hy - hole / 2, width: hole, height: hole))
    c.fill(CGRect(x: tip.x - slit / 2, y: tip.y - 2, width: slit, height: slitLen * s))
    c.endTransparencyLayer()
    c.restoreGState()
}

/// nib-1 bold: a broader, shorter nib with a wide slit and five fat bars, drawn for 32 px.
func drawNib1(_ c: CGContext) {
    darkPlate(c)
    let tip = CGPoint(x: 512, y: 478)
    drawNibGlyph(c, tip: tip, s: 0.98, wx: 1.32, slit: 40, hole: 104, slitLen: 172)
    let hs: [CGFloat] = [120, 230, 290, 230, 120]
    let w: CGFloat = 76, step: CGFloat = 124, y: CGFloat = 300
    for (i, hh) in hs.enumerated() {
        let x = 512 + (CGFloat(i) - 2) * step
        // the coral bar hangs from the tip, so the slit runs straight on into it
        if i == 2 { fill(c, rr(CGRect(x: x - w / 2, y: 182, width: w, height: tip.y - 30 - 182), w / 2), T.coral); continue }
        vbar(c, x: x, y: y, w: w, h: hh, abs(i - 2) == 2 ? T.ghost(0.6) : T.muted)
    }
}

/// nib-2 line: the slit drops as one coral stroke and swings out into a smooth wave; said = ink, next = ghost.
func drawNib2(_ c: CGContext) {
    darkPlate(c)
    let tip = CGPoint(x: 512, y: 520)
    drawNibGlyph(c, tip: tip, s: 0.86, wx: 1.12, slit: 28, hole: 84, slitLen: 170)
    let base: CGFloat = 310, lam: CGFloat = 168, x0: CGFloat = 196, x1: CGFloat = 828
    func y(_ x: CGFloat) -> CGFloat {
        let d = (x - 512) / 300
        return base + 150 * exp(-d * d * 1.6) * cos((x - 512) / lam * 2 * .pi)
    }
    func seg(_ a: CGFloat, _ b: CGFloat, _ col: CGColor) {
        let p = CGMutablePath(); p.move(to: CGPoint(x: a, y: y(a)))
        var x = a; while x < b { x = min(b, x + 4); p.addLine(to: CGPoint(x: x, y: y(x))) }
        c.addPath(p); c.setStrokeColor(col); c.setLineWidth(46); c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
    }
    seg(x0, 512 - lam / 2, T.muted)
    seg(512 + lam / 2, x1, T.ghost(0.6))
    // the coral part: from the tip down the crest and through one full swing
    let p = CGMutablePath(); p.move(to: CGPoint(x: 512, y: tip.y - 40))
    p.addLine(to: CGPoint(x: 512, y: y(512)))
    c.addPath(p); c.setStrokeColor(T.coral); c.setLineWidth(46); c.setLineCap(.round); c.strokePath()
    seg(512 - lam / 2, 512 + lam / 2, T.coral)
}

/// nib-3 trail: the nib leans as if writing; the coral bar hangs from where it touches, ghost bars run on to the right.
func drawNib3(_ c: CGContext) {
    darkPlate(c)
    let tip = CGPoint(x: 318, y: 470)
    drawNibGlyph(c, tip: tip, s: 0.92, wx: 1.25, slit: 36, hole: 96, slitLen: 170, angle: -0.5)
    let w: CGFloat = 68, step: CGFloat = 116, y: CGFloat = 300
    fill(c, rr(CGRect(x: tip.x - w / 2, y: 190, width: w, height: tip.y - 30 - 190), w / 2), T.coral)
    let hs: [CGFloat] = [230, 160, 190, 110]
    for (i, hh) in hs.enumerated() {
        vbar(c, x: tip.x + step * CGFloat(i + 1), y: y, w: w, h: hh, T.ghost(i < 2 ? 0.62 : 0.42))
    }
}

/// nib-4 light: the same bold nib, ink on a light plate, so it stands apart from dark menu bars and docks.
func drawNib4(_ c: CGContext) {
    drawPlate(c, top: T.lCard, bottom: T.lSoft, edge: hex(0x14161a, 0.12))
    let tip = CGPoint(x: 512, y: 478)
    drawNibGlyph(c, tip: tip, s: 0.98, wx: 1.32, slit: 40, hole: 104, slitLen: 172, col: T.lInk)
    let hs: [CGFloat] = [120, 230, 0, 230, 120]
    let w: CGFloat = 76, step: CGFloat = 124, y: CGFloat = 300
    fill(c, rr(CGRect(x: 512 - w / 2, y: 182, width: w, height: tip.y - 30 - 182), w / 2), T.lCoral)
    for (i, hh) in hs.enumerated() where i != 2 {
        vbar(c, x: 512 + (CGFloat(i) - 2) * step, y: y, w: w, h: hh, abs(i - 2) == 2 ? T.ghost(0.75) : T.lPrimary)
    }
}

/// nib-5 slim: a taller, slimmer nib; the bars read in time: ink before the coral bar (said), ghost after it (next).
func drawNib5(_ c: CGContext) {
    darkPlate(c)
    let tip = CGPoint(x: 512, y: 452)
    drawNibGlyph(c, tip: tip, s: 1.08, wx: 0.86, slit: 30, hole: 80, slitLen: 170)
    let hs: [CGFloat] = [110, 200, 260, 200, 110]
    let w: CGFloat = 64, step: CGFloat = 116, y: CGFloat = 290
    fill(c, rr(CGRect(x: 512 - w / 2, y: 170, width: w, height: tip.y - 30 - 170), w / 2), T.coral)
    for (i, hh) in hs.enumerated() where i != 2 {
        vbar(c, x: 512 + (CGFloat(i) - 2) * step, y: y, w: w, h: hh, i < 2 ? T.ink : T.ghost(0.6))
    }
}

let nibRound: [(String, String, (CGContext) -> Void)] = [
    ("nib", "today", drawNib),
    ("nib-1", "bold", drawNib1),
    ("nib-2", "line", drawNib2),
    ("nib-3", "trail", drawNib3),
    ("nib-4", "light", drawNib4),
    ("nib-5", "slim", drawNib5),
]

/// (d) strip: the notch strip as a speech bubble on a light plate: record dot, voice bars, a ghost tail.
func drawStrip(_ c: CGContext) {
    drawPlate(c, top: T.lCard, bottom: T.lSoft, edge: hex(0x14161a, 0.10))
    let body = CGRect(x: 176, y: 396, width: 672, height: 328)
    let p = CGMutablePath()
    p.addPath(rr(body, 170))
    // tail under the left of the bubble
    p.move(to: CGPoint(x: 290, y: 420))
    p.addLine(to: CGPoint(x: 250, y: 262))
    p.addLine(to: CGPoint(x: 440, y: 410))
    p.closeSubpath()
    c.addPath(p); c.setFillColor(T.lPrimary); c.fillPath()
    c.setFillColor(T.coral)
    c.fillEllipse(in: CGRect(x: 248, y: 560 - 66, width: 132, height: 132))
    let hs: [CGFloat] = [90, 190, 120, 210]
    for (i, hh) in hs.enumerated() { vbar(c, x: 452 + CGFloat(i) * 72, y: 560, w: 44, h: hh, T.ink) }
    bar(c, x: 712, y: 560, w: 72, h: 44, T.ghost(0.6))
}

/// (e) ibeam: the text caret is the loudest bar of a voice wave; what you said is ink, what comes next is ghost.
func drawIbeam(_ c: CGContext) {
    darkPlate(c)
    let y: CGFloat = 512, w: CGFloat = 54, step: CGFloat = 104
    // caret (I-beam) in coral
    let ch: CGFloat = 520
    fill(c, rr(CGRect(x: 512 - w / 2, y: y - ch / 2, width: w, height: ch), 12), T.coral)
    fill(c, rr(CGRect(x: 512 - 92, y: y + ch / 2 - 46, width: 184, height: 46), 23), T.coral)
    fill(c, rr(CGRect(x: 512 - 92, y: y - ch / 2, width: 184, height: 46), 23), T.coral)
    let left: [CGFloat] = [170, 330], right: [CGFloat] = [300, 160]
    for (i, hh) in left.enumerated() { vbar(c, x: 512 - step * CGFloat(2 - i), y: y, w: w, h: hh, T.ink) }
    for (i, hh) in right.enumerated() { vbar(c, x: 512 + step * CGFloat(i + 1), y: y, w: w, h: hh, T.ghost(0.45)) }
}

/// pen: the old icon (graphite square, pencil.line, coral dot), kept for comparison.
func drawPen(_ c: CGContext) {
    drawPlate(c, top: hex(0x303036), bottom: hex(0x1a1a1c), edge: hex(0xffffff, 0.08))
    let ns = NSGraphicsContext(cgContext: c, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
    let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.92)]))
    if let sym = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let z = sym.size
        sym.draw(in: NSRect(x: 512 - z.width / 2 - 30, y: 512 - z.height / 2 - 20, width: z.width, height: z.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    c.setFillColor(T.coral); c.fillEllipse(in: CGRect(x: plate.maxX - 143 - 102, y: plate.maxY - 143 - 102, width: 143, height: 143))
}

let candidates: [(String, String, (CGContext) -> Void)] = [
    ("pixel", "pixel pen", drawPixel),
    ("ghost", "caret + ghost", drawGhost),
    ("nib", "nib + wave", drawNib),
    ("strip", "notch strip", drawStrip),
    ("ibeam", "caret wave", drawIbeam),
    ("pen", "today", drawPen),
]

// MARK: Rendering

func bitmap(_ px: Int) -> (NSBitmapImageRep, CGContext) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    return (rep, ctx)
}

func render(_ draw: (CGContext) -> Void, _ px: Int) -> NSBitmapImageRep {
    let (rep, c) = bitmap(px)
    c.interpolationQuality = .high
    c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(c)
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

func makeSheet(_ dir: String, _ list: [(String, String, (CGContext) -> Void)] = candidates, file: String = "sheet.png") {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let colW: CGFloat = 300, pad: CGFloat = 40, labelH: CGFloat = 40
    let blockH: CGFloat = 256 + 20 + 128 + 20 + 32 + 20 + 128 + 30
    let W = Int(pad * 2 + colW * CGFloat(list.count)), H = Int(blockH * 2 + labelH + pad)
    let (rep, c) = bitmap(max(W, H))
    _ = rep
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let sc = NSGraphicsContext(bitmapImageRep: sheet)!
    let g = sc.cgContext
    _ = c
    // two backgrounds: light on top, dark below
    g.setFillColor(T.lPaper); g.fill(CGRect(x: 0, y: CGFloat(H) - labelH - blockH, width: CGFloat(W), height: blockH + labelH))
    g.setFillColor(T.paper); g.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H) - labelH - blockH))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = sc
    for (i, (name, label, draw)) in list.enumerated() {
        let big = render(draw, 1024)
        try! png(big).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        let r128 = render(draw, 128), r32 = render(draw, 32)
        let x = pad + CGFloat(i) * colW
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor(cgColor: T.lInk)!]
        NSString(string: "\(name) - \(label)").draw(at: NSPoint(x: x, y: CGFloat(H) - 32), withAttributes: attrs)
        for b in 0..<2 {
            var y = CGFloat(H) - labelH - CGFloat(b) * blockH - 10
            y -= 256; big.draw(in: NSRect(x: x, y: y, width: 256, height: 256), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            y -= 20 + 128; r128.draw(in: NSRect(x: x, y: y, width: 128, height: 128), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            y -= 20 + 32; r32.draw(in: NSRect(x: x, y: y, width: 32, height: 32), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            // the 32 px render blown up 4x, nearest neighbour, to judge it
            y -= 20 + 128
            sc.imageInterpolation = .none
            r32.draw(in: NSRect(x: x, y: y, width: 128, height: 128), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
            sc.imageInterpolation = .high
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try! png(sheet).write(to: URL(fileURLWithPath: "\(dir)/\(file)"))
    print("wrote \(dir)/\(file) and \(list.count) icons")
}

func makeIconset(_ name: String) {
    guard let cand = (candidates + nibRound.dropFirst()).first(where: { $0.0 == name }) else {
        FileHandle.standardError.write("unknown candidate '\(name)'; one of: \(candidates.map { $0.0 }.joined(separator: ", "))\n".data(using: .utf8)!)
        exit(2)
    }
    try? FileManager.default.createDirectory(atPath: "Drafter.iconset", withIntermediateDirectories: true)
    for (file, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                       ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        try! png(render(cand.2, px)).write(to: URL(fileURLWithPath: "Drafter.iconset/icon_\(file).png"))
    }
    try! png(render(cand.2, 1024)).write(to: URL(fileURLWithPath: "preview.png"))
    print("wrote Drafter.iconset and preview.png for '\(name)'; next: iconutil -c icns Drafter.iconset")
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--sheet" {
    makeSheet(args.count > 1 ? args[1] : ".")
} else if args.first == "--nib-sheet" {
    makeSheet(args.count > 1 ? args[1] : ".", nibRound, file: "nib-sheet.png")
} else if let name = args.first {
    makeIconset(name)
} else {
    FileHandle.standardError.write("usage: swift make_icon.swift <\(candidates.map { $0.0 }.joined(separator: "|"))> | --sheet <dir>\n".data(using: .utf8)!)
    exit(2)
}
