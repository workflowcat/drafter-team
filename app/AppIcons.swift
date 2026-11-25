// Real app icons by name, for the journal's rows (kept from the gallery, which the stream round of 23 November 2026
// replaced with one column, app/Stream.swift).
import AppKit

/// Real app icons by name, cached; nil when the app is not on this Mac (the card draws a neutral glyph).
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]
    static let ids = ["Safari": "com.apple.Safari", "Mail": "com.apple.mail", "Notes": "com.apple.Notes", "Terminal": "com.apple.Terminal",
                      "Finder": "com.apple.finder", "Messages": "com.apple.MobileSMS", "Calendar": "com.apple.iCal", "Preview": "com.apple.Preview",
                      "Xcode": "com.apple.dt.Xcode", "Claude": "com.anthropic.claudefordesktop", "Slack": "com.tinyspeck.slackmacgap",
                      "Telegram": "ru.keepcoder.Telegram", "Google Chrome": "com.google.Chrome", "Beeper": "com.automattic.beeper.desktop"]
    static func icon(_ name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        if let c = cache[name] { return c }
        var url: URL?
        if let id = ids[name] { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
        if url == nil {
            for d in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices",
                      "/System/Cryptexes/App/System/Applications", NSHomeDirectory() + "/Applications"] {
                let u = URL(fileURLWithPath: d).appendingPathComponent(name + ".app")
                if FileManager.default.fileExists(atPath: u.path) { url = u; break }
            }
        }
        let img = url.map { small(NSWorkspace.shared.icon(forFile: $0.path)) }
        if cache.count > 300 { cache.removeAll() }
        cache[name] = img
        return img
    }
    /// The icon drawn once into a 32 pt bitmap (64 px): a card draws it at 14-16 pt, and drawing the full icon
    /// (every size it holds) on each card was a third of a gallery draw (window2 round).
    static func small(_ i: NSImage) -> NSImage {
        let px = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return i }
        rep.size = NSSize(width: 32, height: 32)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        i.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let o = NSImage(size: rep.size); o.addRepresentation(rep)
        return o
    }
}
