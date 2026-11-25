// How a tag looks and what he set for it (tags round, 17 November 2026; rules: TagRules in app/TapeRules.swift).
// - TagPrefs: the tags he hid or pinned (data/journal-tag-prefs.json, never in git), and how many items hold each tag,
//   so a guessed tag (TagRules.auto) shows only once it holds enough items. Main thread only.
// - Favicons: a site tag's icon, asked for ONCE per site from the site itself (https://<site>/favicon.ico, then
//   apple-touch-icon.png) and kept in data/favicons (a miss is kept too, so it is never asked again). Never in the
//   preview or the tests; only the site's name leaves the Mac, as when he opens the link.
// - TagMark: the tag's mark in SwiftUI (site icon, app icon, initials, else the kind's glyph); TagLook.draw the same
//   in the list's own drawing.
import AppKit
import SwiftUI

final class TagPrefs {
    static let shared = TagPrefs()
    private(set) var prefs = TagRules.Prefs()
    private(set) var counts: [String: Int] = [:]
    var url: URL? = Home.data.appendingPathComponent("journal-tag-prefs.json")
    private var loaded = false

    func load() {
        guard !loaded else { return }
        loaded = true
        if let url, let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(TagRules.Prefs.self, from: d) { prefs = p }
    }
    /// The preview: made-up prefs, nothing read or written.
    func preview(_ p: TagRules.Prefs = TagRules.Prefs()) { url = nil; loaded = true; prefs = p }

    func set(_ p: TagRules.Prefs) {
        load()
        guard p != prefs else { return }
        prefs = p
        guard let url, let d = try? JSONEncoder().encode(p) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
    /// Items per tag over every row (not the search's): once per build of the rows.
    func count(_ rows: [TapeItem]) {
        var n: [String: Int] = [:]
        for r in rows { for t in r.tags where t.kind != "app" { n[TagRules.key(t), default: 0] += 1 } }
        counts = n
    }
    func shows(_ t: TapeTag) -> Bool { load(); return TagRules.sure(t, count: counts[TagRules.key(t)] ?? 0, prefs: prefs) }
    func shown(_ tags: [TapeTag]) -> [TapeTag] { load(); return TagRules.shown(tags, prefs: prefs) }
}

/// Bumps when a site icon arrives, so the marks draw again.
final class FaviconTick: ObservableObject {
    static let shared = FaviconTick()
    @Published var n = 0
}

enum Favicons {
    static var forcedOffline = false
    /// The preview, the speed harness and the tests (made-up entities): no network, ever.
    static var offline: Bool { forcedOffline || Entities.previewStore != nil }
    static var root: URL { Home.data.appendingPathComponent("favicons") }
    private static var cache: [String: NSImage] = [:]
    private static var asked = Set<String>()
    static let arrived = Notification.Name("drafter.favicon")

    /// The icon of a site, when kept; else nil, and (once per site, never offline) asked for in the background.
    static func icon(_ name: String) -> NSImage? {
        guard let h = TagRules.host(name) else { return nil }
        if let i = cache[h] { return i }
        let png = root.appendingPathComponent(h + ".png"), miss = root.appendingPathComponent(h + ".none")
        if let i = NSImage(contentsOf: png) { cache[h] = i; return i }
        if offline || asked.contains(h) || FileManager.default.fileExists(atPath: miss.path) { return nil }
        asked.insert(h)
        fetch(h, TagRules.faviconURLs(h), png: png, miss: miss)
        return nil
    }

    private static func fetch(_ h: String, _ urls: [URL], png: URL, miss: URL) {
        guard let u = urls.first else {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: miss.path, contents: Data())
            return
        }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.setValue("Drafter", forHTTPHeaderField: "User-Agent")
        req.httpShouldHandleCookies = false
        URLSession.shared.dataTask(with: req) { d, r, _ in
            let ok = (r as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok, let d, d.count > 0, d.count < 300_000, let img = NSImage(data: d), img.isValid,
                  let small = AppIcons.small(img).tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) else {
                fetch(h, Array(urls.dropFirst()), png: png, miss: miss); return
            }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? small.write(to: png, options: .atomic)
            DispatchQueue.main.async {
                if let i = NSImage(data: small) { cache[h] = i }
                FaviconTick.shared.n += 1
                NotificationCenter.default.post(name: arrived, object: nil)
            }
        }.resume()
    }
}

enum TagLook {
    /// A picture for the tag, when there is one: a site's icon, an app's (or a tool that is an app on this Mac).
    static func image(_ t: TapeTag) -> NSImage? {
        switch t.kind {
        case "site": return Favicons.icon(t.name)
        case "app", "tool": return AppIcons.icon(t.name)
        default: return nil
        }
    }
    static func person(_ t: TapeTag) -> Bool { t.kind == "person" || t.kind == "chat" }

    /// The list's own drawing (flipped view): the picture, the initials in a soft circle, else the glyph.
    static func draw(_ t: TapeTag, in r: NSRect, color: NSColor) {
        if let i = image(t) {
            i.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else if person(t), !TagRules.initials(t.name).isEmpty {
            Native.rule.setFill(); NSBezierPath(ovalIn: r).fill()
            let s = TagRules.initials(t.name)
            let f = NSFont.systemFont(ofSize: r.height * (s.count > 1 ? 0.42 : 0.5), weight: .semibold)
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
            let z = (s as NSString).size(withAttributes: a)
            (s as NSString).draw(at: NSPoint(x: r.midX - z.width / 2, y: r.midY - z.height / 2), withAttributes: a)
        } else {
            TapeDraw.glyph(t.glyph, r, color: color)
        }
    }
}

/// A tag's mark: the site's icon, the app's icon, the person's initials, else the kind's glyph (a folder for a project).
struct TagMark: View {
    let tag: TapeTag
    var size: CGFloat = 14
    var ink: Color = UIInk.muted
    @ObservedObject private var tick = FaviconTick.shared
    var body: some View {
        if let i = TagLook.image(tag) {
            Image(nsImage: i).resizable().interpolation(.high).frame(width: size, height: size)
        } else if TagLook.person(tag), !TagRules.initials(tag.name).isEmpty {
            let s = TagRules.initials(tag.name)
            Text(s).font(.system(size: size * (s.count > 1 ? 0.42 : 0.5), weight: .semibold)).foregroundStyle(ink)
                .frame(width: size, height: size).background(Circle().fill(UIInk.rule))
        } else {
            Glyph(tag.glyph, size: size).foregroundStyle(ink)
        }
    }
}
