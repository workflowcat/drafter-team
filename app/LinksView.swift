// The Links & Files page. Window.swift owns navigation; this view only uses the journal's in-memory rows.
import AppKit
import SwiftUI

/// One store per open page. Extraction runs once per journal revision, away from the main thread.
private final class LinksHubStore: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { refilter() } } }
    @Published var source: LinkSource? { didSet { refilter() } }
    @Published var host: String? { didSet { refilter() } }
    @Published private(set) var shown: [LinkItem] = []
    @Published private(set) var counts: [LinkSource: Int] = [:]
    @Published private(set) var allCount = 0
    @Published private(set) var hosts: [(host: String, count: Int)] = []
    @Published private(set) var extracting = false

    private var local: [LinkItem] = []
    private var items: [LinkItem] = []
    private var active = false
    private var revision: Int?
    private var buildToken = 0
    private static let queue = DispatchQueue(label: "drafter.links", qos: .userInitiated)

    func start() {
        active = true
        revision = nil
    }

    func stop() {
        active = false
        buildToken &+= 1
    }

    func rebuild(_ rows: [TapeItem], revision: Int) {
        guard active, self.revision != revision else { return }
        self.revision = revision
        buildToken &+= 1
        let token = buildToken
        extracting = true
        // The captured value snapshot never touches WindowModel, AX or disk on the worker queue.
        Self.queue.async { [weak self] in
            let input = rows.flatMap { row -> [LinkRowInput] in
                let entry = row.entry
                var text = row.current
                var title = entry?.title ?? ""
                if let clipTitle = entry?.clipTitle, !clipTitle.isEmpty { title = clipTitle }
                if let doc = row.doc {
                    title = doc.title
                    text = ([text, doc.details, doc.mine] + doc.points + doc.todos + doc.turns.map(\.text)).joined(separator: "\n")
                }
                let clip = entry?.clip.rawValue ?? "text"
                let tags = row.tags.map(\.name)
                // Multi-file clipboard rows join paths with newlines; split into individual openable file entries.
                if entry?.clip == .file {
                    let paths = row.current.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if paths.count > 1 {
                        return paths.map { path in
                            LinkRowInput(id: row.id, kind: row.kind.word, clip: clip, text: "",
                                         title: (path as NSString).lastPathComponent, app: row.app, when: row.at,
                                         tags: tags, filePath: path)
                        }
                    }
                    return [LinkRowInput(id: row.id, kind: row.kind.word, clip: clip, text: text,
                                         title: title, app: row.app, when: row.at, tags: tags,
                                         filePath: paths.first ?? row.current)]
                }
                return [LinkRowInput(id: row.id, kind: row.kind.word, clip: clip, text: text,
                                     title: title, app: row.app, when: row.at, tags: tags, filePath: "")]
            }
            let links = LinksRules.extract(from: input)
            DispatchQueue.main.async {
                guard let self, self.active, self.buildToken == token else { return }
                self.local = links
                self.extracting = false
                self.combine()
            }
        }
    }

    private func combine() {
        items = LinksRules.merge(local: local, remote: [])
        refilter()
    }

    private func refilter() {
        shown = LinksRules.filter(items, query: query, source: source, host: host)
        let forSources = LinksRules.filter(items, query: query, source: nil, host: host)
        counts = LinksRules.sourceCounts(forSources)
        allCount = forSources.count
        hosts = LinksRules.topHosts(LinksRules.filter(items, query: query, source: source, host: nil))
    }
}

struct LinksView: View {
    /// A local file that would run if opened (an app, a script, an installer): Open shows it in Finder instead.
    static func runsCode(_ u: URL) -> Bool {
        let ext = u.pathExtension.lowercased()
        if ["app", "command", "sh", "zsh", "bash", "tool", "pkg", "mpkg", "workflow", "scpt", "terminal", "jar", "py", "rb", "pl"].contains(ext) { return true }
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && !dir.boolValue && FileManager.default.isExecutableFile(atPath: u.path)
    }
    @EnvironmentObject var m: WindowModel
    @StateObject private var s = LinksHubStore()
    @FocusState private var searchFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader("Links & Files", subtitle: "Links and files you copied or mentioned", count: s.allCount) {
                PageSearchField(
                    placeholder: "Search links and files",
                    text: $s.query,
                    loading: s.extracting,
                    focus: $searchFocus,
                    accessibility: "Search links and files"
                )
                .frame(width: PageLayout.searchWidth)
            }
            sourceBar
            if s.host != nil || !s.hosts.isEmpty {
                hostBar
            }
            TimelineView(.periodic(from: .now, by: 60)) { clock in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(s.shown) { item in
                            LinksHubRow(item: item, now: clock.date.timeIntervalSince1970, wide: m.width >= 1000) {
                                guard let jid = item.journalId else { return }
                                m.reveal(jid)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay {
                    if s.shown.isEmpty {
                        Text(s.extracting ? "Loading links and files…" : emptyText)
                            .font(NativeFont.text(14)).foregroundStyle(UIInk.muted)
                            .padding(24).allowsHitTesting(false)
                    }
                }
            }
        }
        .padding(.horizontal, PageLayout.margin)
        .padding(.bottom, 14)
        .onAppear {
            s.start()
            s.rebuild(m.rows, revision: m.rowsGen)
            searchFocus = true
        }
        .onChange(of: m.rowsGen) { _, revision in s.rebuild(m.rows, revision: revision) }
        .onDisappear { s.stop() }
    }

    private var emptyText: String {
        s.query.isEmpty && s.source == nil && s.host == nil ? "No links or files yet." : "No matching links or files."
    }

    private var sourceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                sourcePill(nil)
                ForEach(LinkSource.allCases, id: \.self) { source in sourcePill(source) }
            }
        }.frame(height: 30)
    }

    private func sourcePill(_ source: LinkSource?) -> some View {
        let on = s.source == source
        let label = source?.label ?? "All"
        let count = source.map { s.counts[$0] ?? 0 } ?? s.allCount
        return Button { s.source = source } label: {
            HStack(spacing: 6) {
                Glyph(source?.glyph ?? "list", size: 13)
                Text(label).font(NativeFont.text(12))
                Text("\(count)").font(NativeFont.mono(11))
            }
            .foregroundStyle(on ? UIInk.ink : UIInk.muted)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(on ? UIInk.pick : .clear)).contentShape(Capsule())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel("\(label), \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var hostBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let host = s.host {
                    Button { s.host = nil } label: {
                        HStack(spacing: 6) {
                            Glyph("close", size: 11)
                            Text(host).font(NativeFont.text(12))
                        }.padding(.horizontal, 8).frame(height: 26)
                            .background(Capsule().fill(UIInk.pick)).contentShape(Capsule())
                    }.buttonStyle(.plain).foregroundStyle(UIInk.ink)
                        .help("Clear website filter").accessibilityLabel("Clear website filter: \(host)")
                }
                ForEach(s.hosts.filter { $0.host != s.host }, id: \.host) { entry in
                    Button { s.host = entry.host } label: {
                        HStack(spacing: 6) {
                            Glyph("globe", size: 12)
                            Text(entry.host).font(NativeFont.text(12))
                            Text("\(entry.count)").font(NativeFont.mono(11))
                        }.padding(.horizontal, 8).frame(height: 26)
                            .background(Capsule().fill(UIInk.well)).contentShape(Capsule())
                    }.buttonStyle(.plain).foregroundStyle(UIInk.muted)
                        .help("Filter by \(entry.host)").accessibilityLabel("\(entry.host), \(entry.count)")
                }
            }
        }.frame(height: 28)
    }

}

private struct LinksHubRow: View {
    let item: LinkItem
    let now: Double
    let wide: Bool
    let inJournal: () -> Void
    @State private var hover = false
    @State private var notice = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if item.host.isEmpty { Glyph("file", size: 16).foregroundStyle(UIInk.muted) }
                else { TagMark(tag: TapeTag(name: item.host, kind: "site"), size: 16) }
            }.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle).font(NativeFont.text(14, .medium)).foregroundStyle(UIInk.ink).lineLimit(1).truncationMode(.tail)
                Text(location).font(NativeFont.text(12)).foregroundStyle(UIInk.muted).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Glyph(item.source.glyph, size: 11)
                    Text(origin).lineLimit(1)
                    Text("·")
                    Text(LinksRules.relativeTime(item.when, now: now)).fixedSize()
                    if item.mentions > 1 {
                        Text("×\(item.mentions)").font(NativeFont.mono(10))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(UIInk.well))
                            .accessibilityLabel("\(item.mentions) mentions")
                    }
                }.font(NativeFont.text(11)).foregroundStyle(UIInk.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 2) {
                    action("Open", glyph: "arrow-up-right", enabled: target != nil) {
                        guard let target else { return }
                        if target.isFileURL, LinksView.runsCode(target) {
                            NSWorkspace.shared.activateFileViewerSelecting([target]); notice = ""   // shown, never run
                        } else { notice = NSWorkspace.shared.open(target) ? "" : "Could not open." }
                    }
                    if !item.url.isEmpty {
                        action("Copy URL", glyph: "link") {
                            History.copy(item.url); notice = "URL copied"
                        }
                    } else if let path = item.filePath, !path.isEmpty {
                        action("Copy Path", glyph: "copy") {
                            History.copy(path); notice = "Path copied"
                        }
                    }
                    action("Copy Markdown", glyph: "copy") {
                        History.copy(LinksRules.markdown(item)); notice = "Markdown copied"
                    }
                    if item.journalId != nil { action("In Journal", glyph: "list", act: inJournal) }
                }
                if !notice.isEmpty { Text(notice).font(NativeFont.text(11)).foregroundStyle(UIInk.muted) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Native.radius("row")).fill(hover ? UIInk.hover : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(UIInk.line).frame(height: 0.5).padding(.leading, 40) }
        .contentShape(Rectangle()).onHover { hover = $0 }
    }

    private var displayTitle: String {
        if item.url.isEmpty || item.title != item.url { return item.title }
        let parts = ClipRules.parts(item.url)
        if !parts.last.isEmpty { return parts.last }
        return parts.host.isEmpty ? item.title : parts.host
    }

    private var location: String {
        guard !item.url.isEmpty, let parts = URLComponents(string: item.url) else { return item.filePath ?? "" }
        return item.host + (parts.percentEncodedPath.removingPercentEncoding ?? parts.path)
    }

    private var origin: String {
        item.origin.isEmpty || item.origin == item.source.label ? item.source.label : item.source.label + " · " + item.origin
    }

    private var target: URL? {
        if !item.url.isEmpty { return URL(string: item.normalizedURL) }
        // A remote attachment name alone cannot be opened as a local file.
        guard let path = item.filePath, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func action(_ name: String, glyph: String, enabled: Bool = true, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 4) {
                Glyph(glyph, size: 13)
                if wide { Text(name).font(NativeFont.text(11)) }
            }.padding(.horizontal, 6).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(enabled ? UIInk.muted : UIInk.faint)
            .disabled(!enabled).help(name).accessibilityLabel(name)
    }
}
