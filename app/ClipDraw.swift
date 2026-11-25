// How a link, file or picture row looks on a tape (round three, 14 November 2026): the Quick panel and the window's
// tape both draw a copied row through these, so the kinds read the same in both. Pure drawing, no state but the
// thumbnail cache. Kinds and keys: app/ClipRules.swift.
import AppKit
import ImageIO

extension TapeDraw {
    /// The glyph a copied row shows for what it is (nil: the source's own glyph).
    static func clipMark(_ k: ClipKind) -> String? {
        switch k { case .link: return "globe"; case .file: return "file"; case .image: return "image"; case .text: return nil }
    }

    /// One line for a link, file or picture row: the main part in ink, the rest muted. nil for plain text.
    /// Clip kinds round (17 November 2026): `shape` and its `note` (ClipRules.note) add several files, a PDF, a table,
    /// code and a colour; without them a row reads as before.
    static func clipParts(_ k: ClipKind, text: String, title: String, bytes: Int, ocr: String, shape: ClipShape? = nil, note: String = "",
                          look: [String]? = nil, picture: Bool = false) -> (main: String, rest: String)? {
        switch (k, shape) {
        case (.file, _) where shape == .files || text.contains("\n"):
            let paths = text.split(separator: "\n").map(String.init)
            return (ClipKindRules.filesLine(count: paths.count, bytes: bytes), ClipKindRules.names(paths, max: 6))
        case (.file, .pdf?):
            let p = ClipRules.fileParts(text)
            return (p.name, [note, bytes > 0 ? ClipRules.bytes(bytes) : "", p.folder].filter { !$0.isEmpty }.joined(separator: " · "))
        case (.image, .pdf?):
            let words = ocr.split(whereSeparator: \.isNewline).joined(separator: " ")
            return (text, [bytes > 0 ? ClipRules.bytes(bytes) : "", String(words.prefix(160))].filter { !$0.isEmpty }.joined(separator: " · "))
        case (.text, .table?):
            let size = note.split(separator: "×").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { Int($0) }
            let head = size.count == 2 ? ClipKindRules.tableLine(cols: size[0], rows: size[1]) : "Table"
            let first = ClipKindRules.cells(text, rows: 1, cols: 6, chars: 18).first ?? []
            return (head, first.joined(separator: " · "))
        case (.text, .code?):
            let first = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            let lines = text.split(whereSeparator: \.isNewline).count
            return (note.isEmpty ? "Code" : note, ([String(first.prefix(200))] + (lines > 1 ? ["\(lines) lines"] : [])).joined(separator: " · "))
        case (.text, .color?):
            return (text, note.isEmpty || note.caseInsensitiveCompare(text) == .orderedSame ? "" : note)
        default: break
        }
        switch k {
        case .link:
            let p = ClipRules.parts(text)
            let label = ClipRules.linkTitle(text, title: title)
            let rest = label == p.host ? "" : label
            return (p.host, rest)
        case .file:
            let p = ClipRules.fileParts(text)
            return (p.name, ([bytes > 0 ? ClipRules.bytes(bytes) : ""] + [p.folder]).filter { !$0.isEmpty }.joined(separator: " · "))
        case .image where picture:
            // pictures round (24 November 2026): what it is first ("Code · import Foundation"), then size and bytes
            let size = text.replacingOccurrences(of: "Image · ", with: "")
            let kind = PictureLookRules.kind(ocr: ocr, labels: look ?? [])
            return (PictureLookRules.line(kind: kind, ocr: ocr, labels: look ?? [], size: size),
                    [size, bytes > 0 ? ClipRules.bytes(bytes) : ""].filter { !$0.isEmpty }.joined(separator: " · "))
        case .image:
            let size = text.replacingOccurrences(of: "Image · ", with: "")
            let words = ocr.split(whereSeparator: \.isNewline).joined(separator: " ")
            return (size, [bytes > 0 ? ClipRules.bytes(bytes) : "", String(words.prefix(160))].filter { !$0.isEmpty }.joined(separator: " · "))
        case .text: return nil
        }
    }

    /// Main part then the rest on one line inside `r`, cut at the end; returns false for plain text (nothing drawn).
    @discardableResult
    static func clipLine(_ k: ClipKind, text: String, title: String, bytes: Int, ocr: String, _ r: NSRect, font: NSFont, ink: NSColor = Native.ink,
                         shape: ClipShape? = nil, note: String = "", look: [String]? = nil, picture: Bool = false) -> Bool {
        guard let (main, rest) = clipParts(k, text: text, title: title, bytes: bytes, ocr: ocr, shape: shape, note: note, look: look, picture: picture) else { return false }
        let a = at(font, ink, cut: .byTruncatingMiddle), b = at(font, Native.muted)
        let mw = min(r.width, width(main, a))
        line(main, NSRect(x: r.minX, y: r.minY, width: mw, height: r.height), a)
        if !rest.isEmpty, r.width - mw > 40 { line(rest, NSRect(x: r.minX + mw + 10, y: r.minY, width: r.width - mw - 10, height: r.height), b) }
        return true
    }

    /// A colour value's swatch: the colour over a small checker (so a see-through colour shows), the control corner
    /// and a hairline.
    static func swatch(_ c: ClipKindRules.RGBA, in r: NSRect) {
        let path = NSBezierPath(roundedRect: r, xRadius: Native.corner(2), yRadius: Native.corner(2))
        NSGraphicsContext.saveGraphicsState(); path.addClip()
        if c.a < 0.999 {
            NSColor.white.setFill(); r.fill()
            NSColor(white: 0.82, alpha: 1).setFill()
            let u: CGFloat = 6
            for i in 0..<Int(ceil(r.width / u)) { for j in 0..<Int(ceil(r.height / u)) where (i + j) % 2 == 0 {
                NSRect(x: r.minX + CGFloat(i) * u, y: r.minY + CGFloat(j) * u, width: u, height: u).fill()
            } }
        }
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a).setFill(); r.fill()
        NSGraphicsContext.restoreGraphicsState()
        Native.line.setStroke(); let e = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Native.corner(2) - 0.5, yRadius: Native.corner(2) - 0.5); e.lineWidth = 1; e.stroke()
    }

    /// A table's top-left cells as a small grid inside `r` (hairlines between, the first row in ink). Returns the
    /// height used.
    @discardableResult
    static func grid(_ cells: [[String]], x: CGFloat, y: CGFloat, width w: CGFloat, font: NSFont, draw: Bool = true) -> CGFloat {
        guard !cells.isEmpty else { return 0 }
        let cols = max(1, cells.map(\.count).max() ?? 1), rh: CGFloat = 20, cw = w / CGFloat(cols)
        let h = CGFloat(cells.count) * rh
        guard draw else { return h }
        let box = NSRect(x: x, y: y, width: w, height: h)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Native.line.setStroke(); path.lineWidth = 1; path.stroke()
        for (j, row) in cells.enumerated() {
            if j > 0 { hairline(x0: x, x1: x + w, y: y + CGFloat(j) * rh) }
            for (i, cell) in row.enumerated() {
                if j == 0, i > 0 { Native.line.setFill(); NSRect(x: x + CGFloat(i) * cw, y: y, width: 1, height: h).fill() }
                line(cell, NSRect(x: x + CGFloat(i) * cw + 6, y: lineTop(font, mid: y + CGFloat(j) * rh + rh / 2), width: cw - 12, height: rh),
                     at(font, j == 0 ? Native.ink : Native.muted))
            }
        }
        return h
    }

    // MARK: thumbnails

    private static let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.countLimit = 240; return c
    }()
    private static let thumbQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "drafter.clip-thumb"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1   // serial: one decode at a time
        return q
    }()
    private static let thumbLock = NSLock()
    private static var thumbInFlight: [String: [() -> Void]] = [:]
    private static var thumbFailed: Set<String> = []

    private static func decodeThumb(_ url: URL, px: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: px,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func thumbKey(_ url: URL, px: Int) -> String? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return "\(url.lastPathComponent)@\(date.timeIntervalSince1970)@\(px)"
    }

    /// A stored picture scaled down once (longest side `px` pixels) and kept in memory; nil when it is gone.
    static func thumb(_ url: URL, px: Int = 360) -> NSImage? {
        guard let key = thumbKey(url, px: px) else { return nil }
        let k = key as NSString
        if let i = thumbCache.object(forKey: k) { return i }
        thumbLock.lock()
        let failed = thumbFailed.contains(key)
        thumbLock.unlock()
        if failed { return nil }
        guard let i = decodeThumb(url, px: px) else {
            thumbLock.lock()
            if thumbFailed.count > 500 { thumbFailed.removeAll() }
            thumbFailed.insert(key)
            thumbLock.unlock()
            return nil
        }
        thumbCache.setObject(i, forKey: k)
        return i
    }

    /// Non-blocking thumbnail lookup for live scrolling: returns cached image immediately, else decodes off-main
    /// on a bounded queue (negative-cached per file mtime on decode failure).
    static func thumbAsync(_ url: URL, px: Int = 360, onReady: @escaping () -> Void) -> NSImage? {
        guard let key = thumbKey(url, px: px) else { return nil }
        let nsKey = key as NSString
        if let i = thumbCache.object(forKey: nsKey) { return i }
        thumbLock.lock()
        if thumbFailed.contains(key) { thumbLock.unlock(); return nil }
        if thumbInFlight[key] != nil {
            thumbInFlight[key]?.append(onReady)
            thumbLock.unlock()
            return nil
        }
        thumbInFlight[key] = [onReady]
        thumbLock.unlock()
        thumbQueue.addOperation {
            let img = decodeThumb(url, px: px)
            if let img { thumbCache.setObject(img, forKey: nsKey) }
            thumbLock.lock()
            if img == nil {
                if thumbFailed.count > 500 { thumbFailed.removeAll() }
                thumbFailed.insert(key)
            }
            let callbacks = thumbInFlight.removeValue(forKey: key) ?? []
            thumbLock.unlock()
            guard img != nil else { return }
            DispatchQueue.main.async { callbacks.forEach { $0() } }
        }
        return nil
    }
    /// The picture fitted into `box` (aspect kept, top-left), with the theme's control corner and a hairline. Returns
    /// the rectangle it took.
    @discardableResult
    static func picture(_ img: NSImage, in box: NSRect) -> NSRect {
        let s = min(box.width / max(1, img.size.width), box.height / max(1, img.size.height))
        let r = NSRect(x: box.minX, y: box.minY, width: (img.size.width * s).rounded(), height: (img.size.height * s).rounded())
        let path = NSBezierPath(roundedRect: r, xRadius: Native.corner(1), yRadius: Native.corner(1))
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        Native.line.setStroke(); path.lineWidth = 1; path.stroke()
        return r
    }
}

extension Entry {
    /// A clipboard.jsonl row (round three: kind, title, size, stored picture and its read text).
    static func clip(_ r: [String: Any], id: String) -> Entry? {
        guard let t = r["text"] as? String else { return nil }
        var e = Entry(id: id, when: Date(timeIntervalSince1970: r["t"] as? Double ?? 0), app: r["app"] as? String ?? "", text: t, audio: "")
        e.clip = (r["kind"] as? String).flatMap(ClipKind.init(rawValue:)) ?? (r["image"] != nil ? .image : .text)
        e.clipTitle = r["title"] as? String ?? ""; e.bytes = r["bytes"] as? Int ?? 0; e.picture = r["clip"] as? String ?? ""
        if !e.picture.isEmpty { e.ocr = History.clipText(e.picture); e.look = History.clipLabels(e.picture) }
        if let id = r["shot"] as? String, ShotJournalRules.validId(id) { e.shot = id }
        return e
    }
}
