// The Names page (2026-11-15): every name in the names reference (data/names.json, engine/names.py) - people,
// projects, companies, places, terms - with its forms, phone, email and where it shows up. Fix a spelling, merge two,
// hide one; each change undoes from the notice at the bottom (⌘Z). Edits go to data/names-edits.json (the nightly
// build applies them again) and into data/names.json at once; `engine/names.py derive` then refreshes the derived
// files (known words for autocorrect, the dictionary's terms and mishearings for voice). Rules: app/NameRules.swift.
import SwiftUI

final class NamesStore: ObservableObject {
    static let shared = NamesStore()
    var preview = false
    @Published var entries: [NameRules.Entry] = []
    @Published var query = "" { didSet { refilter() } }
    @Published var kind = "" { didSet { refilter() } }
    @Published var sortMode: NameRules.SortMode = .weight { didSet { refilter() } }
    @Published var rows: [Int] = []
    @Published var maxWeight: Double = 1
    @Published var revision = 0
    @Published var chosen: String?
    @Published var editing: String?
    @Published var merging: String?          // the entry being merged; the chosen row is where it goes
    @Published var notice = ""
    @Published var counts: [String: Int] = [:]
    private var top: [String: Any] = [:]     // the rest of names.json, written back as it was
    private var edits: [NameRules.Entry] = []
    private var undos: [(entries: [NameRules.Entry], edits: Int, what: String)] = []
    private var stamp: Date?
    private var deriveWork: DispatchWorkItem?

    var file: URL { Home.data.appendingPathComponent("names.json") }
    var editsFile: URL { Home.data.appendingPathComponent("names-edits.json") }

    /// Read again when names.json changed on disk (the nightly build, or derive after an edit).
    func load() {
        guard !preview else { return }
        let m = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard m != stamp || entries.isEmpty else { return }
        stamp = m
        guard let d = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        top = j; entries = j["entries"] as? [NameRules.Entry] ?? []
        edits = (try? JSONSerialization.jsonObject(with: Data(contentsOf: editsFile))) as? [NameRules.Entry] ?? []
        refilter()
    }

    func use(_ es: [NameRules.Entry]) { entries = es; refilter() }

    func refilter() {
        rows = NameRules.sort(NameRules.filter(entries, kind: kind, query: query), in: entries, by: sortMode)
        var topW: Double = 0
        for i in rows { topW = max(topW, NameRules.entryWeight(entries[i])) }
        maxWeight = topW > 0 ? topW : 1
        var c: [String: Int] = ["": 0, "hidden": 0]
        for e in entries {
            if e["hidden"] as? Bool == true { c["hidden", default: 0] += 1; continue }
            c[""]! += 1; c[NameRules.str(e, "kind"), default: 0] += 1
        }
        counts = c
        revision += 1
        if let ch = chosen, !rows.contains(where: { NameRules.str(entries[$0], "id") == ch }) { chosen = nil }
        if chosen == nil, let f = rows.first { chosen = NameRules.str(entries[f], "id") }
    }

    func entry(_ id: String?) -> NameRules.Entry? { id.flatMap { i in entries.first { NameRules.str($0, "id") == i } } }

    /// One edit: applied here, kept for undo, written to both files.
    func change(_ edit: NameRules.Entry, _ what: String) {
        undos.append((entries, edits.count, what))
        var es = entries
        guard NameRules.apply(&es, [edit]) > 0 else { undos.removeLast(); return }
        entries = es; edits.append(edit)
        notice = what; refilter(); save()
    }

    /// Multiple edits applied and undone as a single step.
    func changeBatch(_ batch: [NameRules.Entry], _ what: String) {
        guard !batch.isEmpty else { return }
        undos.append((entries, edits.count, what))
        var es = entries
        guard NameRules.apply(&es, batch) > 0 else { undos.removeLast(); return }
        entries = es; edits.append(contentsOf: batch)
        notice = what; refilter(); save()
    }

    func undo() {
        guard let u = undos.popLast() else { return }
        entries = u.entries; edits = Array(edits.prefix(u.edits))
        notice = "Undone · " + u.what
        refilter(); save()
    }
    var canUndo: Bool { !undos.isEmpty }

    func spell(_ id: String, uk: String, latin: String) {
        guard let e = entry(id) else { return }
        var ed: NameRules.Entry = ["op": "spell", "id": id]
        if uk != NameRules.str(e, "uk") { ed["uk"] = uk }
        if latin != NameRules.str(e, "latin") { ed["latin"] = latin }
        editing = nil
        guard ed.count > 2 else { return }
        change(ed, "Spelling of \(NameRules.display(e)) fixed")
    }

    func setKind(_ id: String, to newKind: String) {
        guard let e = entry(id), NameRules.kinds.contains(newKind), NameRules.str(e, "kind") != newKind else { return }
        change(["op": "kind", "id": id, "kind": newKind], "\(NameRules.display(e)) → \(NameRules.kindTitle(newKind))")
    }

    func hide(_ id: String) {
        guard let e = entry(id) else { return }
        let on = !(e["hidden"] as? Bool ?? false)
        change(["op": "hide", "id": id, "on": on], (on ? "Hidden: " : "Shown again: ") + NameRules.display(e))
    }

    func hideMany(_ ids: [String]) {
        let batch: [NameRules.Entry] = ids.compactMap { id in
            guard let e = entry(id), !(e["hidden"] as? Bool ?? false) else { return nil }
            return ["op": "hide", "id": id, "on": true]
        }
        guard !batch.isEmpty else { return }
        changeBatch(batch, "Hidden \(batch.count) \(batch.count == 1 ? "entry" : "entries")")
    }

    func merge(_ id: String, into: String) {
        guard let a = entry(id), let b = entry(into), id != into else { merging = nil; return }
        merging = nil; chosen = into
        change(["op": "merge", "id": id, "into": into], "\(NameRules.display(a)) merged into \(NameRules.display(b))")
    }

    func mergeAll(_ pairs: [(source: String, target: String)]) {
        let batch: [NameRules.Entry] = pairs.compactMap { p in
            guard p.source != p.target else { return nil }
            return ["op": "merge", "id": p.source, "into": p.target]
        }
        guard !batch.isEmpty else { return }
        merging = nil
        changeBatch(batch, "Merged \(batch.count) duplicate \(batch.count == 1 ? "pair" : "pairs")")
    }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex { NameRules.str(entries[$0], "id") == chosen } ?? -1
        let to = max(0, min(rows.count - 1, at + d))
        chosen = NameRules.str(entries[rows[to]], "id")
    }

    private func save() {
        guard !preview else { return }
        top["entries"] = entries
        do {
            try JSONSerialization.data(withJSONObject: top).write(to: file, options: .atomic)
            try JSONSerialization.data(withJSONObject: edits, options: [.prettyPrinted]).write(to: editsFile, options: .atomic)
            stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        } catch { notice = "Not saved: \(error.localizedDescription)"; return }
        // the derived files a moment later (several quick edits: one run)
        deriveWork?.cancel()
        let w = DispatchWorkItem {
            let p = Process(); p.executableURL = Home.python
            p.arguments = [Home.root.appendingPathComponent("engine/names.py").path, "derive"]
            p.currentDirectoryURL = Home.root
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            log("names: derived after an edit (exit \(p.terminationStatus))")
        }
        deriveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}

struct NamesView: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var s = NamesStore.shared
    @FocusState private var searchFocus: Bool
    @State private var workspace: EntityWorkspaceSelection?
    @State private var showTidy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader("Names", subtitle: "People, projects, companies, places & terms", count: s.rows.count) {
                HStack(spacing: 8) {
                    SwiftUI.Menu {
                        ForEach(NameRules.SortMode.allCases, id: \.self) { mode in
                            Button { s.sortMode = mode } label: {
                                HStack {
                                    Text(mode.title)
                                    if s.sortMode == mode { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Glyph("arrows-vertical", size: 12)
                            Text(s.sortMode.title).font(NativeFont.text(12, .medium))
                            Glyph("chevron-down", size: 10)
                        }
                        .foregroundStyle(UIInk.ink)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(UIInk.well))
                        .overlay { Capsule().strokeBorder(UIInk.line, lineWidth: 0.5) }
                        .contentShape(Capsule())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Sort names")
                    .accessibilityLabel("Sort: \(s.sortMode.title)")

                    PagePillButton(title: "Tidy Names", glyph: "sparkle") { showTidy = true }
                        .help("Find duplicates and clean up unused entries")

                    PageSearchField(
                        placeholder: "Search names, forms, phones, emails",
                        text: $s.query,
                        focus: $searchFocus,
                        onSubmit: { if let c = s.chosen { s.merging != nil ? s.merge(s.merging!, into: c) : (s.editing = c) } }
                    )
                    .frame(width: PageLayout.searchWidth)
                }
            }
            KindPick()
            if let id = s.merging, let e = s.entry(id) {
                HStack(spacing: 6) {
                    Glyph("arrow-up-right", size: 13)
                    Text("\(NameRules.display(e)) into ").foregroundStyle(UIInk.muted) + Text(s.entry(s.chosen).map(NameRules.display) ?? "…")
                    KeyChip("↵"); KeyChip("esc")
                }.font(NativeFont.text(12.5))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(s.rows, id: \.self) { i in
                            let e = s.entries[i], id = NameRules.str(e, "id")
                            NameRow(e: e, chosen: s.chosen == id, editing: s.editing == id, top: s.maxWeight, wide: m.width >= 1000,
                                    onWorkspace: { workspace = EntityWorkspaceSelection(id: id, entry: e) }).id(id)
                                .contentShape(Rectangle())
                                .onTapGesture { if let mg = s.merging { s.merge(mg, into: id) } else { s.chosen = id } }
                        }
                    }
                }
                .onChange(of: s.chosen) { _, c in if let c { proxy.scrollTo(c) } }
            }
            if !s.notice.isEmpty {
                HStack(spacing: 8) {
                    Text(s.notice).font(NativeFont.text(12.5)).foregroundStyle(UIInk.muted).lineLimit(1)
                    if s.canUndo { Button("Undo") { s.undo() }.buttonStyle(.plain).font(NativeFont.text(12.5, .medium)).foregroundStyle(UIInk.blue).help("Undo (⌘Z)") }
                    Spacer()
                }.frame(height: 22)
            }
        }
        .padding(.horizontal, PageLayout.margin)
        .padding(.bottom, 14)
        .background { if workspace == nil && !showTidy { NamesKeys() } }
        .sheet(item: $workspace) { selected in
            EntityWorkspaceView(entry: selected.entry).environmentObject(m)
        }
        .sheet(isPresented: $showTidy) {
            NamesTidyView()
        }
        .onAppear { s.preview = m.preview; s.load(); searchFocus = true }
    }
}

/// The kinds as glyph chips with their counts (and the hidden ones); a click or ⌘1-7 picks one.
struct KindPick: View {
    @ObservedObject var s = NamesStore.shared
    private func label(_ k: String) -> String {
        switch k {
        case "": return "All"
        case "person": return "People"
        case "project": return "Projects"
        case "company": return "Companies"
        case "place": return "Places"
        case "term": return "Terms"
        case "hidden": return "Hidden"
        default: return k.capitalized
        }
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(([""] + NameRules.kinds + ["hidden"]).enumerated()), id: \.offset) { n, k in
                    let on = s.kind == k
                    let name = label(k)
                    Button { s.kind = k } label: {
                        HStack(spacing: 5) {
                            Glyph(k.isEmpty ? "list" : k == "hidden" ? "blur" : NameRules.glyph(k), size: 13)
                            Text(name).font(NativeFont.text(12.5))
                            Text("\(s.counts[k] ?? 0)").font(NativeFont.mono(11)).foregroundStyle(on ? UIInk.muted : UIInk.faint)
                        }
                        .foregroundStyle(on ? UIInk.ink : UIInk.muted)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(on ? UIInk.pick : .clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).keyboardShortcut(KeyEquivalent(Character(String(n + 1))), modifiers: .command)
                    .help("\(name) (⌘\(n + 1))").accessibilityLabel("\(name), \(s.counts[k] ?? 0)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }.frame(height: 30)
    }
}

struct NameRow: View {
    @EnvironmentObject var m: WindowModel
    let e: NameRules.Entry
    let chosen: Bool
    let editing: Bool
    let top: Double
    var wide = true
    var onWorkspace: () -> Void = {}
    @ObservedObject var s = NamesStore.shared
    @State private var uk = ""
    @State private var latin = ""
    @FocusState private var field: Int?

    var body: some View {
        let id = NameRules.str(e, "id"), kind = NameRules.str(e, "kind")
        let c = e["context"] as? [String: Any] ?? [:]
        let lines = c["lines"] as? Int ?? 0, chats = c["chats"] as? Int ?? 0, seen = c["last_seen"] as? String ?? ""
        let hidden = e["hidden"] as? Bool ?? false
        let displayName = NameRules.display(e)
        let matchNames = [displayName, NameRules.str(e, "uk"), NameRules.str(e, "latin")] + NameRules.list(e, "short")
        let jMatch = m.journalMatch(for: matchNames)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SwiftUI.Menu {
                ForEach(NameRules.kinds, id: \.self) { k in
                    Button { s.setKind(id, to: k) } label: {
                        HStack {
                            Text(NameRules.kindTitle(k))
                            if k == kind { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Glyph(NameRules.glyph(kind), size: 15)
                    .foregroundStyle(UIInk.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Change kind (\(NameRules.kindTitle(kind)))")
            .accessibilityLabel("Kind: \(NameRules.kindTitle(kind))")
            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    HStack(spacing: 6) {
                        TextField("Українською", text: $uk)
                            .textFieldStyle(.plain).font(NativeFont.text(13.5)).focused($field, equals: 0)
                            .padding(.horizontal, 8).frame(width: 190, height: 28)
                            .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
                            .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(field == 0 ? UIInk.blue : UIInk.line, lineWidth: field == 0 ? 1 : 0.5) }
                        TextField("Latin", text: $latin)
                            .textFieldStyle(.plain).font(NativeFont.text(13.5)).focused($field, equals: 1)
                            .padding(.horizontal, 8).frame(width: 190, height: 28)
                            .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
                            .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(field == 1 ? UIInk.blue : UIInk.line, lineWidth: field == 1 ? 1 : 0.5) }
                    }
                    .onSubmit { s.spell(id, uk: uk, latin: latin) }
                    .onExitCommand { s.editing = nil }
                    .onAppear { uk = NameRules.str(e, "uk"); latin = NameRules.str(e, "latin"); field = uk.isEmpty ? 1 : 0 }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NameRules.display(e)).font(NativeFont.text(14, .medium)).foregroundStyle(hidden ? UIInk.faint : UIInk.ink)
                        if !NameRules.str(e, "uk").isEmpty, !NameRules.str(e, "latin").isEmpty {
                            Text(NameRules.str(e, "latin")).font(NativeFont.text(13)).foregroundStyle(UIInk.muted)
                        }
                    }
                }
                let more = NameRules.list(e, "short") + NameRules.list(e, "forms")
                if !more.isEmpty {
                    Text(more.prefix(8).joined(separator: " · ") + (more.count > 8 ? " +\(more.count - 8)" : ""))
                        .font(NativeFont.text(12)).foregroundStyle(UIInk.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            let phone = NameRules.list(e, "phones").first, mail = NameRules.list(e, "emails").first
            // fixed slots, so phones and emails line up from row to row; a narrow window drops the emails
            HStack(spacing: 4) { if let phone { Glyph("phone", size: 12); Text(phone).font(NativeFont.mono(11.5)).textSelection(.enabled) } }
                .foregroundStyle(UIInk.muted).lineLimit(1).frame(width: 170, alignment: .leading)
            if wide {
                HStack(spacing: 4) { if let mail { Glyph("mail", size: 12); Text(mail).font(NativeFont.mono(11.5)).truncationMode(.middle).textSelection(.enabled) } }
                    .foregroundStyle(UIInk.muted).lineLimit(1).frame(width: 230, alignment: .leading)
            }
            HStack(spacing: 6) {
                // how much the user writes it: a bar against the most used name shown
                let w = e["weight"] as? Double ?? 0
                Capsule().fill(UIInk.line).frame(width: 44, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(UIInk.blue).frame(width: 44 * CGFloat(min(1, top > 0 ? w / top : 0)), height: 4) }
                    .help("\(lines) lines · \(chats) chats")
                Text("\(lines)").font(NativeFont.mono(11)).foregroundStyle(UIInk.muted).frame(width: 34, alignment: .trailing).accessibilityLabel("\(lines) lines")
                Glyph("chat", size: 12).foregroundStyle(chats > 0 ? UIInk.muted : UIInk.line)
                Text("\(chats)").font(NativeFont.mono(11)).foregroundStyle(UIInk.muted).frame(width: 22, alignment: .leading).accessibilityLabel("\(chats) chats")
                Text(seen.isEmpty ? "-" : seen).font(NativeFont.mono(11)).foregroundStyle(UIInk.faint).frame(width: 74, alignment: .trailing).accessibilityLabel(seen.isEmpty ? "never seen" : "last seen \(seen)")
            }
            Button { m.openEntityInJournal(names: matchNames, fallback: displayName) } label: {
                HStack(spacing: 4) {
                    Glyph("list", size: 11)
                    Text(jMatch.count > 0 ? "\(jMatch.count)" : "Journal").font(NativeFont.mono(11))
                }
                .foregroundStyle(jMatch.count > 0 ? UIInk.ink : UIInk.faint)
                .padding(.horizontal, 7).frame(height: 22)
                .background(Capsule().fill(jMatch.count > 0 ? UIInk.soft : .clear))
                .overlay { Capsule().strokeBorder(UIInk.line, lineWidth: 0.5) }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show all journal items for \(displayName) (drafts, voice notes, calls, clips, screenshots)")
            .accessibilityLabel("Show \(displayName) in Journal")
            Button(action: onWorkspace) {
                HStack(spacing: 4) {
                    Glyph("app-window", size: 12)
                    if wide { Text("Workspace").font(NativeFont.text(11.5)) }
                }.frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(UIInk.muted)
                .help("Open Workspace").accessibilityLabel("Open workspace for \(displayName)")
            SwiftUI.Menu {
                Button("Open Workspace", action: onWorkspace)
                Button("Show in Journal") { m.openEntityInJournal(names: matchNames, fallback: displayName) }
                Divider()
                Button("Fix the spelling  ↵") { s.chosen = id; s.editing = id }
                Button("Merge into another  ⌘M") { s.chosen = id; s.merging = id }
                Button((hidden ? "Show again" : "Hide") + "  ⌘⌫") { s.hide(id) }
            } label: { Glyph("edit", size: 13).foregroundStyle(chosen ? UIInk.ink : UIInk.faint).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for \(NameRules.display(e))")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(chosen ? UIInk.pick : .clear))
        .overlay { if chosen, s.merging != nil { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.blue, lineWidth: 1) } }
        .overlay(alignment: .bottom) { Rectangle().fill(UIInk.line).frame(height: 1).padding(.leading, 42) }
    }
}

/// The page's keys: ↑↓ choose, ↵ fix the spelling (or merge into the chosen), ⌘M merge, ⌘⌫ hide, ⌘Z undo, esc stops a merge.
struct NamesKeys: View {
    @ObservedObject var s = NamesStore.shared
    func k(_ key: KeyEquivalent, _ mods: EventModifiers = [], _ act: @escaping () -> Void) -> some View {
        Button("", action: act).keyboardShortcut(key, modifiers: mods).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
    var body: some View {
        ZStack {
            if s.editing == nil {
                k(.downArrow) { s.move(1) }; k(.upArrow) { s.move(-1) }
                k("m", .command) { s.merging = s.merging == nil ? s.chosen : nil }
                k(.delete, .command) { if let c = s.chosen { s.hide(c) } }
                if s.merging != nil { k(.escape) { s.merging = nil } }
            }
            k("z", .command) { s.undo() }
        }
    }
}

/// Made-up names for `--ui-preview` (PREVIEW_ONLY=names) and the window shots.
enum NamesPreview {
    static func sample() -> [NameRules.Entry] {
        func e(_ id: String, _ kind: String, uk: String = "", latin: String = "", forms: [String] = [], short: [String] = [],
               phone: String? = nil, mail: String? = nil, lines: Int, chats: Int, seen: String, hidden: Bool = false) -> NameRules.Entry {
            ["id": id, "kind": kind, "uk": uk, "latin": latin, "forms": forms, "short": short, "heard": [String](),
             "phones": phone.map { [$0] } ?? [], "emails": mail.map { [$0] } ?? [], "links": [String](), "sources": ["sample"],
             "context": ["lines": lines, "chats": chats, "chat_ids": [String](), "apps": [String: Int](), "last_seen": seen],
             "weight": Double(lines + 3 * chats), "hidden": hidden, "card": false]
        }
        return [
            e("p1", "person", uk: "Ганна Квітка", latin: "Hanna Kvitka", forms: ["Ганни", "Ганну", "Ганною", "Ганні", "Квітки", "Квітці"], short: ["Ганя"],
              phone: "+380 00 000 0001", mail: "hanna@example.test", lines: 142, chats: 6, seen: "2026-11-14"),
            e("pr1", "project", latin: "Bramblix", forms: ["Bramblix-у"], lines: 96, chats: 3, seen: "2026-11-15"),
            e("p2", "person", uk: "Орест Вітер", latin: "Orest Viter", forms: ["Ореста", "Орестові", "Орестом"], phone: "+380 00 000 0002", lines: 58, chats: 2, seen: "2026-11-10"),
            e("c1", "company", latin: "Larkspur Labs", short: ["Larkspur"], mail: "office@example.test", lines: 31, chats: 1, seen: "2026-11-02"),
            e("pl1", "place", uk: "Поділ", latin: "Podil", forms: ["Подолі", "Подолом"], lines: 12, chats: 0, seen: "2026-10-28"),
            e("t1", "term", latin: "Glimmerdocs", lines: 4, chats: 0, seen: "2026-10-03"),
            e("p3", "person", latin: "Quill Contact", mail: "quill@example.test", lines: 0, chats: 0, seen: ""),
            e("p4", "person", uk: "Old Spelling", lines: 0, chats: 0, seen: "", hidden: true),
        ]
    }
}
