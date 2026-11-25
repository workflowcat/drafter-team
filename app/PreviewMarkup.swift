// The markup editor's preview (PREVIEW_ONLY=markup, 17 November 2026): a made-up picture with an arrow, a highlight
// and freehand pen strokes (app/PenRules.swift), as the editor shows it (pill and all) and as it is pasted. Never
// reads data/; the editor's panel is never shown (screenFrame stands in for the screen).
import AppKit

extension UIShots {
    static func markupShots(_ folder: String) throws {
        try markupShot(folder, dark: false)
        try markupShot(folder, dark: true)
    }

    /// `dark`: a dark-mode window with light text bars, and highlights over it (they must lighten, never read as shadows).
    static func markupShot(_ folder: String, dark: Bool) throws {
        let W = 1200, H = 760
        let bg: CGFloat = dark ? 0.12 : 0.97, bar: CGFloat = dark ? 0.2 : 0.9, strong: CGFloat = dark ? 0.85 : 0.55, soft: CGFloat = dark ? 0.55 : 0.8, rule: CGFloat = dark ? 0.22 : 0.88
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // a made-up settings window: a title bar, rows of grey text bars, a button
        ctx.setFillColor(NSColor(white: bg, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(NSColor(white: bar, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: H - 56, width: W, height: 56))
        for (i, c) in [0xee6a5f, 0xf5bd4f, 0x61c454].enumerated() {
            ctx.setFillColor(NSColor(srgbRed: CGFloat(c >> 16) / 255, green: CGFloat((c >> 8) & 255) / 255, blue: CGFloat(c & 255) / 255, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: 24 + i * 26, y: H - 36, width: 14, height: 14))
        }
        for r in 0..<8 {
            let y = H - 120 - r * 66
            ctx.setFillColor(NSColor(white: strong, alpha: 1).cgColor); ctx.fill(CGRect(x: 60, y: y, width: 180 + (r * 37) % 120, height: 14))
            ctx.setFillColor(NSColor(white: soft, alpha: 1).cgColor); ctx.fill(CGRect(x: 60, y: y - 22, width: 420 + (r * 53) % 260, height: 10))
            ctx.setFillColor(NSColor(white: rule, alpha: 1).cgColor); ctx.fill(CGRect(x: 60, y: y - 36, width: W - 120, height: 1))
        }
        ctx.setFillColor(NSColor(srgbRed: 0.29, green: 0.49, blue: 0.84, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 960, y: 70, width: 170, height: 46), cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
        guard let pic = ctx.makeImage(), let png = MarkupDraw.png(pic) else { return }

        let ed = MarkupEditor.shared
        let screen = NSRect(x: 0, y: 0, width: 1500, height: 980)
        ed.open(png, near: nil, region: NSRect(x: 150, y: 160, width: 1200, height: 760), screenFrame: screen) { _ in }
        func stroke(_ pts: [CGPoint], color: Int, size: Int = 1) {
            var p = PicMark(tool: .pen, from: pts[0], to: pts[pts.count - 1], color: color, size: size); p.points = pts; ed.model.add(p)
        }
        // a loose ring round the button, as a hand draws it: it overshoots where it closes
        stroke((0...64).map { i -> CGPoint in
            let a = Double(i) / 64 * 2.15 * .pi - 0.4, rx = 118 + 6 * Foundation.sin(a * 3), ry = 50 + 4 * Foundation.cos(a * 2)
            return CGPoint(x: 1045 + rx * Foundation.cos(a), y: 667 + ry * Foundation.sin(a))
        }, color: 0)
        // a wavy underline under the third row's label
        stroke((0...90).map { i in CGPoint(x: 58 + Double(i) * 3, y: 276 + 5 * Foundation.sin(Double(i) / 4)) }, color: 3, size: 2)
        // a tick by the first row
        stroke([CGPoint(x: 700, y: 120), CGPoint(x: 712, y: 134), CGPoint(x: 722, y: 142), CGPoint(x: 740, y: 118), CGPoint(x: 762, y: 92)], color: 2)
        ed.model.add(PicMark(tool: .highlight, from: CGPoint(x: 56, y: 377), to: CGPoint(x: 330, y: 395), color: 1))
        if dark {   // the cases from the 10:48 shot: a row in green, a large area in red
            ed.model.add(PicMark(tool: .highlight, from: CGPoint(x: 56, y: 167), to: CGPoint(x: 290, y: 185), color: 2))
            ed.model.add(PicMark(tool: .highlight, from: CGPoint(x: 40, y: 560), to: CGPoint(x: 700, y: 700), color: 0))
        }
        ed.model.add(PicMark(tool: .arrow, from: CGPoint(x: 780, y: 520), to: CGPoint(x: 925, y: 640)))
        ed.model.tool = .pen
        try save(ed.view, folder + "/markup-\(dark ? "dark" : "pen")-editor.png")
        if let out = MarkupDraw.render(pic, ed.model), let d = MarkupDraw.png(out) { try d.write(to: URL(fileURLWithPath: folder + "/markup-\(dark ? "dark" : "pen")-pasted.png")) }
        print("markup preview: \(ed.model.marks.count) marks; " + ShotPack.markLines(ed.model.shotMarks).joined(separator: " | "))
        ed.close(nil)
    }
}
