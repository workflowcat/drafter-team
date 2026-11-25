// The Dictionary page (17 November 2026, research item 2): every word in the shared dictionary (data/words.json,
// engine/dictionary.py) and every heard -> meant pair, with the words waiting to be learned (engine/edits.py) as the
// top group. Type to search, ↵ edit (on a word to learn: learn it), ⌘⌫ remove (ignore), ⌘Z undo. ⇧⌘D in the window and
// the menu's "Open dictionary" open it. The page reads the file; every change goes through the engine
// (/words/edit, /words/loose, /words/remove, /edits), which also rebuilds the terms and heard lists Voice reads.
// Rules: app/DictRules.swift. The same pattern as the Names page (app/Names.swift).
import SwiftUI

final class DictStore: ObservableObject {
    static let shared = DictStore()
    var preview = false
    /// The live windowshot draws the rows as grey bars: his words never land in a picture (numbers only).
    @Published var redact = false
    @Published var rows: [DictRules.Row] = []
    @Published var shown: [Int] = []
    @Published var query = "" { didSet { refilter() } }
    @Published var chosen: String?
    @Published var editing: String?
    @Published var notice = ""
    private var file: [String: Any] = [:]
    private var waiting: [[String: Any]] = []
    private var undos: [(op: Op, what: String)] = []
    private var stamp: Date?

    /// One change, as the engine takes it.
    enum Op {
        case edit(old: String, text: String, heard: [String])
        case loose(old: String, heard: String, meant: String)
        case remove(String)
        case decide(heard: String, fixed: String, accept: Bool)
    }

    /// Reads the file again when it changed on disk, and asks the engine for the words waiting to be learned.
    func load() {
        guard !preview else { return }
        let m = (try? FileManager.default.attributesOfItem(atPath: Home.words.path))?[.modificationDate] as? Date
        if m != stamp || file.isEmpty, let d = try? Data(contentsOf: Home.words),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            stamp = m; file = j; rebuild()
        }
        Engine.shared.get("/edits") { [weak self] j in
            guard let self, let e = j?["edits"] as? [[String: Any]] else { return }
            self.waiting = e; Learn.waiting = e; self.rebuild()
        }
    }

    func use(_ f: [String: Any], waiting w: [[String: Any]]) { file = f; waiting = w; rebuild() }

    private func rebuild() { rows = DictRules.rows(file, waiting: waiting); refilter() }

    func refilter() {
        shown = DictRules.filter(rows, query: query)
        if let c = chosen, !shown.contains(where: { rows[$0].id == c }) { chosen = nil }
        if chosen == nil, let f = shown.first { chosen = rows[f].id }
    }

    func row(_ id: String?) -> DictRules.Row? { id.flatMap { i in rows.first { $0.id == i } } }

    func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        let at = shown.firstIndex { rows[$0].id == chosen } ?? -1
        chosen = rows[shown[max(0, min(shown.count - 1, at + d))]].id
    }

    /// ↵: a word to learn is learned at once; any other row opens its fields.
    func enter() {
        guard let r = row(chosen) else { return }
        if r.group == .learn { run(.decide(heard: r.heard.first ?? "", fixed: r.text, accept: true), "Learned: \(r.text)", undo: nil) }
        else { editing = r.id }
    }

    /// ⌘⌫: removes a word or a pair (undo puts it back); ignores a word to learn.
    func remove(_ id: String? = nil) {
        guard let r = row(id ?? chosen) else { return }
        editing = nil
        switch r.group {
        case .learn: run(.decide(heard: r.heard.first ?? "", fixed: r.text, accept: false), "Ignored: \(r.heard.first ?? "") → \(r.text)", undo: nil)
        case _ where r.loose:
            run(.loose(old: r.heard.first ?? "", heard: "", meant: ""), "Removed: \(r.heard.first ?? "") → \(r.text)",
                undo: .loose(old: "", heard: r.heard.first ?? "", meant: r.text))
        default: run(.remove(r.text), "Removed: \(r.text)", undo: .edit(old: r.text, text: r.text, heard: r.heard))
        }
    }

    /// The edit fields' ↵: the word's spelling and its heard forms.
    func save(_ id: String, text: String, heard field: String) {
        editing = nil
        guard let r = row(id), DictRules.valid(text) else { return }
        let t = text.trimmingCharacters(in: .whitespaces), hs = DictRules.heard(field, word: t)
        if r.loose {
            guard let h = hs.first else { remove(id); return }
            guard h != r.heard.first || t != r.text else { return }
            run(.loose(old: r.heard.first ?? "", heard: h, meant: t), "Changed: \(h) → \(t)",
                undo: .loose(old: h, heard: r.heard.first ?? "", meant: r.text))
        } else {
            guard t != r.text || hs != r.heard else { return }
            run(.edit(old: r.text, text: t, heard: hs), t == r.text ? "Heard forms of \(t) changed" : "\(r.text) → \(t)",
                undo: .edit(old: t, text: r.text, heard: r.heard))
            chosen = DictRules.Row(group: hs.isEmpty ? .word : .pair, text: t).id
        }
    }

    func add(text: String, heard field: String = "") {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard DictRules.valid(t) else { return }
        let hs = DictRules.heard(field, word: t)
        run(.edit(old: "", text: t, heard: hs), "Added: \(t)", undo: .remove(t))
        chosen = DictRules.Row(group: hs.isEmpty ? .word : .pair, text: t).id
    }

    func undo() {
        guard let u = undos.popLast() else { return }
        run(u.op, "Undone · " + u.what, undo: nil, keep: false)
    }
    var canUndo: Bool { !undos.isEmpty }

    private func run(_ op: Op, _ what: String, undo: Op?, keep: Bool = true) {
        if keep, let undo { undos.append((undo, what)) }
        if preview { local(op); notice = what; rebuild(); return }
        let (path, body): (String, [String: Any]) = {
            switch op {
            case .edit(let o, let t, let h): return ("/words/edit", ["old": o, "text": t, "heard": h])
            case .loose(let o, let h, let m): return ("/words/loose", ["old": o, "heard": h, "meant": m])
            case .remove(let t): return ("/words/remove", ["text": t])
            case .decide(let h, let f, let a): return ("/edits", ["heard": h, "fixed": f, "accept": a])
            }
        }()
        notice = "Saving…"
        Engine.shared.post(path, body, timeout: 30) { [weak self] j in
            guard let self else { return }
            if j?["ok"] as? Bool == true { self.notice = what; log("dictionary: \(path) saved") }
            else {
                if keep, undo != nil { self.undos.removeLast() }
                if case .edit(_, let t, _) = op, j != nil { self.notice = "Not saved: \(t) is in the dictionary already" }
                else { self.notice = j == nil ? "Not saved: the engine is not answering" : "Not saved" }
            }
            self.stamp = nil; self.load()
        }
    }

    /// The preview's copy of what the engine does (engine/dictionary.py edit, loose, remove; edits.decide).
    private func local(_ op: Op) {
        var words = file["words"] as? [[String: Any]] ?? [], loose = file["loose_heard"] as? [String: String] ?? [:]
        switch op {
        case .edit(let o, let t, let h):
            let key = (o.isEmpty ? t : o).lowercased()
            var w = words.first { ($0["text"] as? String ?? "").lowercased() == key } ?? ["source": "menu"]
            words.removeAll { ($0["text"] as? String ?? "").lowercased() == key }
            w["text"] = t; w["heard"] = h.isEmpty ? nil : h
            words.append(w); h.forEach { loose[$0] = nil }
        case .loose(let o, let h, let m):
            loose[o] = nil; if !h.isEmpty, !m.isEmpty { loose[h] = m }
        case .remove(let t): words.removeAll { ($0["text"] as? String ?? "").lowercased() == t.lowercased() }
        case .decide(let h, let f, let a):
            waiting.removeAll { $0["heard"] as? String == h && $0["fixed"] as? String == f }
            if a { local(.edit(old: f, text: f, heard: (row("word:" + f.lowercased())?.heard ?? []) + [h.lowercased()])); return }
        }
        file["words"] = words; file["loose_heard"] = loose
    }
}

struct DictionaryView: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var s = DictStore.shared
    @FocusState private var searchFocus: Bool
    @State private var adding = false
    @State private var newWord = ""
    @State private var newHeard = ""
    @FocusState private var addFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader("Dictionary", subtitle: "Custom spellings and words learned from voice edits", count: s.rows.count) {
                HStack(spacing: 8) {
                    PageSearchField(
                        placeholder: "Search words and what voice heard",
                        text: $s.query,
                        focus: $searchFocus,
                        onSubmit: { s.enter() }
                    )
                    .frame(width: PageLayout.searchWidth)
                    PagePillButton(title: "Add word", glyph: "plus", primary: adding) {
                        adding.toggle()
                        if adding { newWord = ""; newHeard = ""; addFocus = true }
                    }
                    .help("Add a custom spelling or jargon word")
                }
            }
            if adding {
                PageCard {
                    HStack(spacing: 8) {
                        TextField("Word (e.g. PixelKit, Поділ)", text: $newWord)
                            .textFieldStyle(.plain).font(NativeFont.text(13.5)).focused($addFocus)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
                            .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(addFocus ? UIInk.blue : UIInk.line, lineWidth: addFocus ? 1 : 0.5) }
                            .onSubmit { submitAdd() }
                        TextField("Heard as (optional, comma-separated)", text: $newHeard)
                            .textFieldStyle(.plain).font(NativeFont.text(13.5))
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
                            .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.line, lineWidth: 0.5) }
                            .onSubmit { submitAdd() }
                        PagePillButton(title: "Save", glyph: "check", primary: true, enabled: DictRules.valid(newWord)) { submitAdd() }
                        Button { adding = false } label: { Glyph("close", size: 13).foregroundStyle(UIInk.muted).frame(width: 26, height: 26) }
                            .buttonStyle(.plain).help("Cancel")
                    }
                }
            }
            let c = DictRules.counts(s.rows, s.shown)
            Text(DictRules.Group.allCases.map { "\(c[$0] ?? 0) \(DictRules.title($0).lowercased())" }.joined(separator: " · "))
                .font(NativeFont.text(12.5)).foregroundStyle(UIInk.faint).lineLimit(1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(s.shown.enumerated()), id: \.element) { n, i in
                            let r = s.rows[i]
                            if n == 0 || s.rows[s.shown[n - 1]].group != r.group {
                                Text(DictRules.title(r.group)).font(NativeFont.text(12, .medium)).foregroundStyle(UIInk.muted)
                                    .padding(.leading, 12).padding(.top, n == 0 ? 2 : 16).padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            DictRow(r: r, chosen: s.chosen == r.id, editing: s.editing == r.id).id(r.id)
                                .contentShape(Rectangle()).onTapGesture { s.chosen = r.id }
                        }
                    }
                }
                .redacted(reason: s.redact ? .placeholder : [])
                .onChange(of: s.chosen) { _, c in if let c { proxy.scrollTo(c) } }
            }
            if !s.notice.isEmpty {
                HStack(spacing: 8) {
                    Text(s.redact ? "" : s.notice).font(NativeFont.text(12.5)).foregroundStyle(UIInk.muted).lineLimit(1)
                    if s.canUndo { Button("Undo") { s.undo() }.buttonStyle(.plain).font(NativeFont.text(12.5, .medium)).foregroundStyle(UIInk.blue).help("Undo (⌘Z)") }
                    Spacer()
                }.frame(height: 22)
            }
        }
        .padding(.horizontal, PageLayout.margin)
        .padding(.bottom, 14)
        .background { if !adding { DictKeys() } }
        .onAppear { s.preview = m.preview; s.load(); searchFocus = true }
    }

    private func submitAdd() {
        guard DictRules.valid(newWord) else { return }
        s.add(text: newWord, heard: newHeard)
        adding = false; newWord = ""; newHeard = ""
    }
}

struct DictRow: View {
    let r: DictRules.Row
    let chosen: Bool
    let editing: Bool
    @ObservedObject var s = DictStore.shared
    @State private var text = ""
    @State private var heard = ""
    @FocusState private var field: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Glyph(r.group == .learn ? "sparkle" : r.group == .pair ? "microphone" : "text", size: 15)
                .foregroundStyle(r.group == .learn ? UIInk.blue : UIInk.muted).frame(width: 18)
            if editing {
                HStack(spacing: 6) {
                    TextField("Word", text: $text)
                        .textFieldStyle(.plain).font(NativeFont.text(13.5)).focused($field, equals: 0)
                        .padding(.horizontal, 8).frame(width: 220, height: 28)
                        .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
                        .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(field == 0 ? UIInk.blue : UIInk.line, lineWidth: field == 0 ? 1 : 0.5) }
                    TextField(r.loose ? "Heard as" : "Heard as (comma between forms)", text: $heard)
                        .textFieldStyle(.plain).font(NativeFont.text(13.5)).focused($field, equals: 1)
                        .padding(.horizontal, 8).frame(width: 320, height: 28)
                        .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
                        .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(field == 1 ? UIInk.blue : UIInk.line, lineWidth: field == 1 ? 1 : 0.5) }
                }
                .onSubmit { s.save(r.id, text: text, heard: heard) }
                .onExitCommand { s.editing = nil }
                .onAppear { text = r.text; heard = r.heard.joined(separator: ", "); field = 0 }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !r.heard.isEmpty {
                        Text(r.heard.prefix(4).joined(separator: " · ") + (r.heard.count > 4 ? " +\(r.heard.count - 4)" : ""))
                            .font(NativeFont.text(13.5)).foregroundStyle(UIInk.muted).lineLimit(1)
                        Text("→").font(NativeFont.text(13)).foregroundStyle(UIInk.faint)
                    }
                    Text(r.text).font(NativeFont.text(14, .medium)).foregroundStyle(UIInk.ink).lineLimit(1)
                    if r.count > 1 { Text("×\(r.count)").font(NativeFont.mono(11)).foregroundStyle(UIInk.faint) }
                }
            }
            Spacer(minLength: 8)
            if r.group == .learn, chosen, !editing {
                HStack(spacing: 6) {
                    Button { s.enter() } label: { HStack(spacing: 4) { Text("Learn"); KeyChip("↵") } }
                    Button { s.remove(r.id) } label: { HStack(spacing: 4) { Text("Ignore"); KeyChip("⌘⌫") } }
                }.buttonStyle(.plain).font(NativeFont.text(12.5)).foregroundStyle(UIInk.muted)
            } else if !r.source.isEmpty || r.loose {
                Text(r.loose ? "voice" : r.source).font(NativeFont.mono(11)).foregroundStyle(UIInk.faint)
            }
            if r.group != .learn {
                SwiftUI.Menu {
                    Button("Edit  ↵") { s.chosen = r.id; s.editing = r.id }
                    Button("Remove  ⌘⌫") { s.remove(r.id) }
                } label: { Glyph("edit", size: 13).foregroundStyle(chosen ? UIInk.ink : UIInk.faint).frame(width: 24, height: 24).contentShape(Rectangle()) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for \(r.text)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(chosen ? UIInk.pick : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(UIInk.line).frame(height: 1).padding(.leading, 42) }
    }
}

/// The page's keys: ↑↓ choose, ⌘⌫ remove (ignore), ⌘Z undo. ↵ is the search field's (DictStore.enter).
struct DictKeys: View {
    @ObservedObject var s = DictStore.shared
    func k(_ key: KeyEquivalent, _ mods: EventModifiers = [], _ act: @escaping () -> Void) -> some View {
        Button("", action: act).keyboardShortcut(key, modifiers: mods).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
    var body: some View {
        ZStack {
            if s.editing == nil {
                k(.downArrow) { s.move(1) }; k(.upArrow) { s.move(-1) }
                k(.delete, .command) { s.remove() }
            }
            k("z", .command) { s.undo() }
        }
    }
}

/// Made-up words for `--ui-preview` and the window shots.
enum DictPreview {
    static let file: [String: Any] = [
        "words": [
            ["text": "Bramblix", "source": "aleph", "heard": ["bram blicks", "bramble x"]],
            ["text": "Glimmerdocs", "source": "menu", "heard": ["glimmer docks"]],
            ["text": "Larkspur", "source": "aleph"],
            ["text": "Квітка", "source": "aleph", "heard": ["квитка"]],
            ["text": "Orest", "source": "typing"],
            ["text": "Zorvox", "source": "voicenotes"],
            ["text": "Поділ", "source": "aleph"],
        ],
        "loose_heard": ["kwill o": "Quillo"],
    ]
    static let waiting: [[String: Any]] = [
        ["heard": "fennik", "fixed": "Fennick", "count": 3, "state": "new"],
        ["heard": "lark spur", "fixed": "Larkspur", "count": 1, "state": "new"],
    ]
}
