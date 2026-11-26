// A read-only sheet over Journal snapshots and the engine's local context/source indexes.
import AppKit
import SwiftUI

struct EntityWorkspaceSelection: Identifiable {
    let id: String
    let entry: NameRules.Entry
}

private final class EntityWorkspaceStore: ObservableObject {
    @Published private(set) var model = EntityWorkspaceModel()
    @Published private(set) var building = false
    @Published private(set) var loadingLinks = false
    @Published private(set) var loadingPromises = false
    @Published private(set) var loadingContext = false
    @Published private(set) var context = ""
    @Published private(set) var shareSummary = ""
    @Published private(set) var vaultLinks: [LinkItem] = []
    @Published private(set) var contextError = ""
    @Published private(set) var linksError = ""
    @Published private(set) var promisesError = ""
    @Published private(set) var level = EntityContextLevel.name
    private var entity = EntityWorkspaceIdentity()
    private var preview = false
    private var active = false
    private var lifetime = UUID()
    private var contextToken = UUID()
    private var linksToken = UUID()
    private var promisesToken = UUID()
    private var buildToken = UUID()
    private var debounceWork: DispatchWorkItem?
    private var work: DispatchWorkItem?
    private var local = EntityWorkspaceModel()
    private static let queue = DispatchQueue(label: "drafter.entity-workspace", qos: .userInitiated)

    func start(_ entry: NameRules.Entry, rows: [TapeItem], preview: Bool) {
        stop()
        entity = EntityWorkspaceRules.identity(entry)
        self.preview = preview
        active = true
        rebuild(rows)
        loadShareContext()
        loadContext(.name)
        loadLinks()
        loadPromises()
    }

    func stop() {
        active = false
        lifetime = UUID()
        contextToken = UUID(); linksToken = UUID(); promisesToken = UUID(); buildToken = UUID()
        debounceWork?.cancel(); debounceWork = nil
        work?.cancel(); work = nil
        // Engine.get has no cancellation handle. Invalidating these tokens discards every late callback.
        loadingContext = false; loadingLinks = false; loadingPromises = false; building = false
        context = ""; shareSummary = ""; vaultLinks = []; remote = []; promises = []
        model = EntityWorkspaceModel(); local = EntityWorkspaceModel()
    }

    func rebuild(_ rows: [TapeItem], delay: Double = 0) {
        guard active else { return }
        debounceWork?.cancel()
        debounceWork = nil
        let run: () -> Void = { [weak self] in
            guard let self, self.active else { return }
            self.work?.cancel()
            self.buildToken = UUID()
            let token = self.buildToken, identity = self.entity
            self.building = true
            let work = DispatchWorkItem { [weak self] in
                let inputs = rows.map(Self.input)
                let result = EntityWorkspaceRules.build(entity: identity, journal: inputs)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.buildToken == token else { return }
                    self.local = result
                    self.combine()
                    self.building = false
                }
            }
            self.work = work
            Self.queue.async(execute: work)
        }
        if delay > 0 {
            let pending = DispatchWorkItem(block: run)
            debounceWork = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: pending)
        } else {
            run()
        }
    }

    private var remote: [LinkItem] = []
    private var promises: [EntityPromise] = []

    private func combine() {
        var combined = local
        combined.links = LinksRules.merge(local: local.links, remote: remote + vaultLinks)
        combined.promises = promises
        model = combined
    }

    func loadContext(_ level: EntityContextLevel) {
        guard active else { return }
        self.level = level
        contextToken = UUID()
        let token = contextToken, life = lifetime
        context = ""; contextError = ""; loadingContext = false
        guard !entity.display.isEmpty else { return }
        if preview {
            let response: [String: Any] = ["name": entity.display, "found": 1,
                "text": level == .oneLine ? "\(entity.display) - sample planning contact." : "\(entity.display)\n\nSample context pack.\n- Review the sample outline.\n- Reference: https://example.test/outline"]
            context = EntityWorkspaceRules.contextCopyText(response, entity: entity, level: level)
            return
        }
        loadingContext = true
        Engine.shared.get(path("/context", ["q": entity.display, "level": String(level.rawValue)])) { [weak self] response in
            guard let self, self.active, self.lifetime == life, self.contextToken == token else { return }
            self.loadingContext = false
            guard let response else { self.contextError = "Could not load context."; return }
            if let error = response["error"] as? String { self.contextError = error; return }
            self.context = EntityWorkspaceRules.contextCopyText(response, entity: self.entity, level: level)
        }
    }

    private func loadShareContext() {
        guard active, !preview, !entity.display.isEmpty else { return }
        let life = lifetime
        Engine.shared.get(path("/context", ["q": entity.display, "level": "3"])) { [weak self] response in
            guard let self, self.active, self.lifetime == life, let response else { return }
            self.shareSummary = ([response["who"] as? String ?? ""] + (response["facts"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }).filter { !$0.isEmpty }.joined(separator: "\n")
            let pointers = response["pointers"] as? [[String: Any]] ?? []
            self.vaultLinks = LinksRules.parseSources(pointers.compactMap { p in
                guard let value = p["value"] as? String, value.hasPrefix("obsidian://") else { return nil }
                return ["src": "obsidian", "url": value, "title": p["label"] as? String ?? "Vault note"]
            })
            self.combine()
        }
    }

    func loadLinks() {
        guard active else { return }
        linksToken = UUID()
        let token = linksToken, life = lifetime
        remote = []; linksError = ""; loadingLinks = false; combine()
        guard !entity.display.isEmpty else { return }
        if preview {
            remote = LinksRules.parseSources([["title": "Sample outline", "url": "https://example.test/outline", "src": "drive", "from": "Sample contact", "t": 1_800_000_000]])
            combine(); return
        }
        loadingLinks = true
        let who = (entity.emails + entity.names).joined(separator: ",")
        Engine.shared.get(path("/sources/find", ["q": entity.display, "who": who, "n": "30"])) { [weak self] response in
            guard let self, self.active, self.lifetime == life, self.linksToken == token else { return }
            self.loadingLinks = false
            guard let found = response?["found"] as? [[String: Any]] else { self.linksError = "Could not load sources."; return }
            self.remote = LinksRules.parseSources(found)
            self.combine()
        }
    }

    func loadPromises() {
        guard active else { return }
        promisesToken = UUID()
        let token = promisesToken, life = lifetime
        promises = []; promisesError = ""; loadingPromises = false; combine()
        guard !entity.aliases.isEmpty else { return }
        if preview {
            promises = EntityWorkspaceRules.filterPromises([["id": "sample-promise", "who": entity.display,
                "what": "Review the sample outline", "t": 1_800_000_000, "due": 1_800_086_400]], aliases: entity.aliases)
            combine(); return
        }
        loadingPromises = true
        Engine.shared.get("/promises") { [weak self] response in
            guard let self, self.active, self.lifetime == life, self.promisesToken == token else { return }
            self.loadingPromises = false
            guard let rows = response?["promises"] as? [[String: Any]] else { self.promisesError = "Could not load promises."; return }
            self.promises = EntityWorkspaceRules.filterPromises(rows, aliases: self.entity.aliases)
            self.combine()
        }
    }

    private func path(_ route: String, _ query: [String: String]) -> String {
        var parts = URLComponents()
        parts.path = route
        parts.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        return (parts.string ?? route).replacingOccurrences(of: "+", with: "%2B")
    }

    private static func input(_ row: TapeItem) -> EntityJournalInput {
        let entry = row.entry
        var input = EntityJournalInput(id: row.id, kind: row.kind.word, clip: entry?.clip.rawValue ?? "text",
                                       when: row.at, text: row.current.isEmpty ? row.line : row.current,
                                       title: entry?.clipTitle ?? "", app: row.app,
                                       tags: row.tags.map(\.name))
        if let doc = row.doc {
            input.kind = doc.call ? "call" : "spoken"
            input.documentID = doc.id
            input.title = doc.title
            input.text = [doc.details, doc.mine].filter { !$0.isEmpty }.joined(separator: "\n")
            input.related = doc.people + [doc.project, doc.place, doc.event]
            input.points = doc.points + doc.todos
            input.duration = doc.secs
            input.pictures = doc.shots.enumerated().map { index, shot in
                EntityPicture(id: row.id + ":shot:\(index)", journalID: row.id, when: row.at + shot.t,
                              title: doc.title, path: doc.dir.appendingPathComponent(shot.file).path)
            }
        } else if let shot = row.shot {
            input.clip = "image"
            input.title = shot.note.isEmpty ? "Screenshot" : shot.note
            input.text = shot.captions.joined(separator: "\n")
            input.pictures = [EntityPicture(id: row.id, journalID: row.id, when: row.at, title: input.title, shotID: shot.id)]
        } else if let entry, entry.clip == .image {
            input.title = entry.clipTitle.isEmpty ? "Picture" : entry.clipTitle
            input.text = "" // No OCR or screen-derived search haystack enters the workspace.
            input.pictures = [EntityPicture(id: row.id, journalID: row.id, when: row.at, title: input.title,
                                           path: entry.picture.isEmpty ? "" : History.clipURL(entry.picture).path)]
        } else if entry?.clip == .file {
            input.filePaths = row.current.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        return input
    }
}

struct EntityWorkspaceView: View {
    @EnvironmentObject var m: WindowModel
    @Environment(\.dismiss) private var dismiss
    let entry: NameRules.Entry
    @StateObject private var s = EntityWorkspaceStore()
    @State private var tab = EntityWorkspaceTab.overview
    @State private var notice = ""
    private var entity: EntityWorkspaceIdentity { EntityWorkspaceRules.identity(entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            contextBar
            tabs
            Divider()
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(notice).font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                Spacer()
                if m.preview { Text("Sample").font(NativeFont.text(12)).foregroundStyle(UIInk.muted) }
            }.frame(height: 18)
        }
        .padding(24).frame(width: 880, height: 640)
        .background(UIInk.paper).foregroundStyle(UIInk.ink)
        .onAppear { s.start(entry, rows: m.rows, preview: m.preview) }
        .onChange(of: m.rowsGen) { _, _ in s.rebuild(m.rows, delay: 0.3) }
        .onDisappear { s.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Glyph(NameRules.glyph(entity.kind), size: 24).foregroundStyle(UIInk.muted).padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entity.display).font(NativeFont.display(24)).lineLimit(2).textSelection(.enabled)
                    if !entity.latin.isEmpty, entity.latin != entity.display {
                        Text(entity.latin).font(NativeFont.text(14)).foregroundStyle(UIInk.muted).textSelection(.enabled)
                    }
                }
                Text(entity.kind.capitalized).font(NativeFont.text(12)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(UIInk.well))
                Spacer(minLength: 8)
                Button("Share notes") {
                    copy(ObsidianExportRules.formatShareBrief(title: entity.display, subtitle: entity.kind,
                        summary: s.shareSummary, todos: s.model.promises.map(\.what),
                        links: s.model.links.map(\.url)))
                }.controlSize(.small).help("Copy role, facts, open items and links")
                Button("Open in Journal") {
                    dismiss()
                    m.openEntityInJournal(names: entity.names + entity.emails, fallback: entity.display)
                }.controlSize(.small)
                Button { dismiss() } label: { Glyph("close", size: 14).frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close").accessibilityLabel("Close workspace")
            }
            let forms = entity.names.filter { $0 != entity.display && $0 != entity.latin }
            if !forms.isEmpty {
                Text(forms.joined(separator: " · ")).font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                    .lineLimit(2).textSelection(.enabled)
            }
            if !entity.phones.isEmpty || !entity.emails.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entity.phones, id: \.self) { copyChip($0, glyph: "phone") }
                        ForEach(entity.emails, id: \.self) { copyChip($0, glyph: "mail") }
                    }
                }.frame(height: 28)
            }
        }
    }

    private func copyChip(_ value: String, glyph: String) -> some View {
        Button { copy(value) } label: {
            HStack(spacing: 6) { Glyph(glyph, size: 12); Text(value).font(NativeFont.text(12)) }
                .padding(.horizontal, 8).frame(height: 28).background(Capsule().fill(UIInk.well)).contentShape(Capsule())
        }.buttonStyle(.plain).help("Copy \(value)").accessibilityLabel("Copy \(value)")
    }

    private var contextBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Context Pack").font(NativeFont.text(13, .medium)).padding(.trailing, 8)
                ForEach(EntityContextLevel.allCases, id: \.self) { level in
                    Button { notice = ""; s.loadContext(level) } label: {
                        Text(level.label).font(NativeFont.text(12)).padding(.horizontal, 10).frame(height: 28)
                            .background(Capsule().fill(s.level == level ? UIInk.pick : .clear)).contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(s.level == level ? .isSelected : [])
                        .accessibilityLabel("Level \(level.rawValue), \(level.label.dropFirst(3))")
                }
                Spacer()
                Button { copy(s.context) } label: {
                    HStack(spacing: 5) { Glyph("copy", size: 12); Text("Copy").font(NativeFont.text(12)) }
                }.disabled(s.context.isEmpty || s.loadingContext).help("Copy context pack")
            }
            Group {
                if s.loadingContext { status("Loading context…") }
                else if !s.contextError.isEmpty {
                    retry(s.contextError) { s.loadContext(s.level) }
                } else if s.context.count <= 140 && !s.context.contains("\n") {
                    Text(s.context.isEmpty ? "No context pack found." : s.context).font(NativeFont.text(13))
                        .foregroundStyle(s.context.isEmpty ? UIInk.muted : UIInk.ink)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        Text(s.context).font(NativeFont.text(13))
                            .foregroundStyle(UIInk.ink)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 112)
                }
            }
        }.padding(12).background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(EntityWorkspaceTab.allCases, id: \.self) { section in
                Button { tab = section } label: {
                    HStack(spacing: 6) {
                        Glyph(section.glyph, size: 13)
                        Text(section.label).font(NativeFont.text(12.5))
                        Text("\(s.model.counts.count(section))").font(NativeFont.mono(11))
                    }.padding(.horizontal, 10).frame(height: 30)
                        .background(Capsule().fill(tab == section ? UIInk.pick : .clear)).contentShape(Capsule())
                }.buttonStyle(.plain).foregroundStyle(tab == section ? UIInk.ink : UIInk.muted)
                    .accessibilityLabel("\(section.label), \(s.model.counts.count(section))")
                    .accessibilityAddTraits(tab == section ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var content: some View {
        let content = s.model.content(for: tab)
        switch tab {
        case .overview, .calls:
            if content.isEmpty { status(s.building ? "Loading journal…" : tab == .calls ? "No matching calls." : "No matching journal items.") }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(content.journal) { timelineRow($0, details: tab == .calls) }
            }
        case .links:
            if s.loadingLinks { status("Loading sources…") }
            if !s.linksError.isEmpty { retry(s.linksError, action: s.loadLinks) }
            if content.isEmpty, !s.loadingLinks, s.linksError.isEmpty { status(s.building ? "Loading links…" : "No matching links or files.") }
            LazyVStack(alignment: .leading, spacing: 0) { ForEach(content.links) { linkRow($0) } }
        case .pictures:
            if content.isEmpty { status(s.building ? "Loading pictures…" : "No matching pictures.") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(content.pictures) { picture in
                    Button { jump(picture.journalID) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            EntityWorkspaceThumbnail(picture: picture, preview: m.preview)
                            Text(picture.title).font(NativeFont.text(12)).lineLimit(1)
                            Text(date(picture.when)).font(NativeFont.mono(10.5)).foregroundStyle(UIInk.muted)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Open picture in Journal").accessibilityLabel("Open \(picture.title) in Journal")
                }
            }
        case .promises:
            if s.loadingPromises { status("Loading promises…") }
            if !s.promisesError.isEmpty { retry(s.promisesError, action: s.loadPromises) }
            if content.isEmpty, !s.loadingPromises, s.promisesError.isEmpty { status("No open promises for this name.") }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(content.promises) { promise in
                    HStack(alignment: .top, spacing: 10) {
                        Glyph("check", size: 14).foregroundStyle(UIInk.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(promise.what).font(NativeFont.text(14)).textSelection(.enabled)
                            Text([promise.who, promise.app].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                        }
                        Spacer()
                        if let due = promise.due { Text(date(due)).font(NativeFont.mono(11)).foregroundStyle(UIInk.muted) }
                    }.padding(.vertical, 12)
                }
            }
        }
    }

    private func timelineRow(_ row: EntityJournalInput, details: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { open(row) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Glyph(row.glyph, size: 15).foregroundStyle(UIInk.muted).frame(width: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.title.isEmpty ? row.text : row.title).font(NativeFont.text(14, .medium)).lineLimit(details ? 2 : 1)
                        HStack(spacing: 8) {
                            Text(date(row.when)).font(NativeFont.mono(11))
                            if row.duration > 0 { Text(CallDoc.length(row.duration)).font(NativeFont.mono(11)) }
                            if !row.pictures.isEmpty { Glyph("image", size: 11); Text("\(row.pictures.count)").font(NativeFont.mono(11)) }
                            if !row.app.isEmpty { Text(row.app).font(NativeFont.text(11)) }
                        }.foregroundStyle(UIInk.muted)
                        if details {
                            ForEach(Array(row.points.prefix(4).enumerated()), id: \.offset) { _, point in
                                Text("· " + point).font(NativeFont.text(12.5)).foregroundStyle(UIInk.muted).lineLimit(2)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(row.documentID == nil ? "Open in Journal" : "Open recording")
            if row.documentID != nil {
                Button { jump(row.id) } label: {
                    HStack(spacing: 4) { Glyph("list", size: 12); Text("Journal").font(NativeFont.text(11.5)) }
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Capsule().fill(UIInk.well)).contentShape(Capsule())
                }.buttonStyle(.plain).foregroundStyle(UIInk.muted).help("Open in Journal").accessibilityLabel("Open in Journal")
            }
        }.padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(UIInk.line).frame(height: 0.5) }
    }

    private func linkRow(_ link: LinkItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Glyph(link.url.isEmpty ? "file" : "link", size: 15).foregroundStyle(UIInk.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text(link.title).font(NativeFont.text(14, .medium)).lineLimit(1)
                Text(link.source == .obsidian ? "Obsidian vault" : link.url.isEmpty ? link.filePath ?? "" : link.url).font(NativeFont.text(12)).foregroundStyle(UIInk.muted).lineLimit(1)
                HStack(spacing: 5) {
                    Glyph(link.source.glyph, size: 11)
                    Text([link.source.label, link.origin].filter { !$0.isEmpty }.joined(separator: " · "))
                    Text(date(link.when)).font(NativeFont.mono(10.5))
                }.font(NativeFont.text(11)).foregroundStyle(UIInk.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Open") {
                guard let target = target(link) else { return }
                if !m.preview { notice = NSWorkspace.shared.open(target) ? "" : "Could not open." }
                else { notice = "Sample link" }
            }.disabled(target(link) == nil)
            SwiftUI.Menu {
                Button("Copy URL") { copy(link.url) }.disabled(link.url.isEmpty)
                Button("Copy Markdown") { copy(LinksRules.markdown(link)) }
                if let id = link.journalId { Button("Open in Journal") { jump(id) } }
            } label: { Glyph("copy", size: 13) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Copy link or open in Journal")
        }.padding(.vertical, 10)
    }

    private func status(_ text: String) -> some View {
        Text(text).font(NativeFont.text(13)).foregroundStyle(UIInk.muted).padding(.vertical, 12)
    }
    private func retry(_ text: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) { status(text); Button("Retry", action: action).controlSize(.small) }
    }
    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        if !m.preview { History.copy(text) }
        notice = m.preview ? "Sample copy" : "Copied"
    }
    private func date(_ when: Double) -> String {
        guard when.isFinite, when > 0 else { return "Unknown date" }
        return Date(timeIntervalSince1970: when).formatted(date: .abbreviated, time: .shortened)
    }
    private func target(_ link: LinkItem) -> URL? {
        if !link.normalizedURL.isEmpty { return URL(string: link.normalizedURL) }
        guard let path = link.filePath, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
    private func open(_ row: EntityJournalInput) {
        if let id = row.documentID, let doc = m.rows.first(where: { $0.id == row.id })?.doc ?? m.docs.first(where: { $0.id == id }) {
            dismiss(); m.openDoc(doc)
        } else { jump(row.id) }
    }
    private func jump(_ id: String) {
        dismiss()
        m.reveal(id)
    }
}

private struct EntityWorkspaceThumbnail: View {
    let picture: EntityPicture
    let preview: Bool
    @State private var image: NSImage?
    @State private var token = UUID()
    @State private var active = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Glyph("image", size: 28).foregroundStyle(UIInk.muted).accessibilityLabel(preview ? "Sample picture" : "Thumbnail unavailable") }
        }.frame(height: 112).clipShape(RoundedRectangle(cornerRadius: Native.corner(2)))
            .onAppear { active = true; token = UUID(); load(token) }
            .onDisappear { active = false; token = UUID(); image = nil }
    }

    private func load(_ expected: UUID) {
        guard active, expected == token, !preview else { return }
        let ready = { if active, token == expected { load(expected) } }
        if !picture.shotID.isEmpty { image = ShotJournal.thumbAsync(picture.shotID, px: 400, onReady: ready) }
        else if !picture.path.isEmpty { image = TapeDraw.thumbAsync(URL(fileURLWithPath: picture.path), px: 400, onReady: ready) }
    }
}
