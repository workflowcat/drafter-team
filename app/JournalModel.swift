// The journal's state and actions, as one stream (stream round, 23 November 2026; before it: the outline of time,
// the sidebar, the gallery and the reader, 14-22 November). The build off the main thread; the search through the
// journal's index (JournalSearch, with its ranking) under the stream's scope words (StreamRules); the stream's lines in
// time order, or best first while words are searched; the keys (StreamKeys.route decides, this file does); and what the user
// does to an item: Insert, Copy, Edit, Pin, Combine, Revert, Delete, Undo. The stored history is never rewritten: the user's
// changes and drafts go to JournalStore (data/journal.json); Delete goes through the history's own forget, after 8
// seconds in which ⌘Z (or the notice's Undo) brings the item back. Editing, Combine, the player, Go to:
// app/StreamModel.swift.
import AppKit
import SwiftUI

extension WindowModel {
    // MARK: building

    /// Builds the journal off the main thread (sessions, repeats, tags, chunks); the newest build wins. Then the search
    /// and the filter run on it (`refilter`).
    func rebuildTape() {
        tapeSeq += 1
        let mine = tapeSeq
        let hidden = journalStore.hidden
        // Filter before repeat folding, so an archived source cannot reappear through a representative row.
        let t = takes.filter { !hidden.contains("v:" + $0.id) }
        let c = clips.filter { !hidden.contains("c:\(Int($0.when.timeIntervalSince1970 * 1000)):\($0.text.count)") }
        let ty = typed.filter { !hidden.contains("t:" + $0.id) }
        let d = docs.filter { !hidden.contains("d:" + $0.id) }
        let own = journalStore.file.items.filter { !hidden.contains("j:" + $0.id) }, changes = journalStore.changes
        let at = preview ? now : Date().timeIntervalSince1970
        if !preview { now = at }
        let store = Entities.store
        let url = preview ? previewTagFile : TapeBuild.diskURL, later = !preview || previewDefer
        let pv = preview, made = previewPastes
        // the paste trail (where clips went): read off the main thread, a week back; the preview has its own
        let work = { TapeBuild.journal(takes: t, clips: c, typed: ty, docs: d, own: own, changes: changes, now: at, store: store, diskURL: url, deferTags: later,
                                       pastes: pv ? made : PasteWatch.read(since: at - 7 * 86400)) }
        let apply: (JournalBuild) -> Void = { [weak self] b in
            guard let self, mine == self.tapeSeq else { return }
            self.journal = b
            var items = b.items
            for i in items.indices where !items[i].ownDraft {
                if let q = items[i].quick, !items[i].text.isEmpty { items[i].pinned = !self.preview && Quick.shared.isPinned(q, items[i].text) }
            }
            if self.preview { for i in items.indices where self.previewPins.contains(items[i].id) { items[i].pinned = true } }
            self.rows = items
            self.buildTick += 1
            self.refilter()
            self.warmSearch()
        }
        // the tags the first paint did not have: worked out after it, then the counts and chips again
        let patch: (JournalBuild) -> Void = { [weak self] f in
            guard let self, mine == self.tapeSeq, self.rows.count == f.items.count else { return }
            var rows = self.rows   // one change of the published list, not one per row
            for i in f.missing { rows[i].tags = f.items[i].tags }
            self.rows = rows
            self.journal.facts = f.facts; self.journal.items = f.items; self.journal.missing = []
            self.buildTick += 1
            self.refilter()
            self.warmSearch()
        }
        if preview {
            let b = work(); apply(b)
            if !b.missing.isEmpty { let t0 = Date(); var f = b; TapeBuild.fillTags(&f, store: store); patch(f); fillMs = Date().timeIntervalSince(t0) * 1000 }
            return
        }
        TapeBuild.queue.async {
            let b = work()
            DispatchQueue.main.async { apply(b) }
            guard !b.missing.isEmpty else { return }
            var f = b; TapeBuild.fillTags(&f, store: store)
            DispatchQueue.main.async { patch(f) }
        }
    }

    /// The search under the scope words. The words (with the core's own filters) go to the journal's search
    /// (JournalSearch.run, JournalEngine): the stream keeps what it shows until the answer comes, a newer key drops an
    /// older search, and the same words over the same rows are answered from the last hits at once. No words: every
    /// row, in time order. The scope (kind, @person, in:app, today) is applied on top (`show`).
    func refilter() {
        let q = StreamRules.coreText(query)
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            if searchSide.view != JournalSearchView(ready: searchSide.view.ready) { searchSide.view = JournalSearchView(ready: searchSide.view.ready) }
            searchSide.rankedFor = ""
            show(hits: Array(rows.indices), ranked: false)
            return
        }
        let v = searchVersion, rv = rowsVersion
        if let c = searchSide.cache, c.query == q, c.version == v { show(hits: c.hits, ranked: true); return }
        let eng = searchEngine
        let at: Double? = preview ? now : nil
        let pq = JournalSearch.parse(q, now: at)
        let full = query
        if openedAt != nil, !preview { firstAnswer = (firstAnswer?.from ?? Date(), full) }   // from the user's first key
        JournalSearch.run(q, rows, version: v, engine: eng, now: at) { [weak self] hits, r in
            guard let self, self.query == full, self.rowsVersion == rv else { return }   // the indices still point at these rows
            if let fa = self.firstAnswer, fa.query == full, self.openedAt != nil {
                self.openedAt = nil
                log("window: first answer \(Int(Date().timeIntervalSince(fa.from) * 1000)) ms, \(r != nil ? "index" : "plain, index not ready")")
            }
            let idx = hits.map(\.index)
            var view = JournalSearchView(chips: pq.chips, suggestions: pq.offers, ready: r != nil || eng.ready)
            if let r {
                view.didYouMean = r.didYouMean; view.didYouMeanWhy = r.didYouMeanWhy; view.ms = r.ms
                self.searchSide.cache = (q, v, idx)
            }
            self.objectWillChange.send()
            self.searchSide.view = view
            self.show(hits: idx, ranked: r != nil)
        }
    }

    /// A key in the search field (window2 round, 16 November 2026). A lone key is answered at once; keys typed less
    /// than `JournalSearchSide.burst` apart are answered once, that long after the last of them, so a fast word costs
    /// one answer and each key only redraws the field. Clearing the field answers at once.
    func queryChanged() {
        let side = searchSide
        let now = Date().timeIntervalSince1970
        let fast = now - side.lastKey < JournalSearchSide.burst
        side.lastKey = now
        side.pending?.cancel(); side.pending = nil
        guard fast, !preview || side.burstInPreview, !query.trimmingCharacters(in: .whitespaces).isEmpty else { refilter(); return }
        let w = DispatchWorkItem { [weak self] in self?.searchSide.pending = nil; self?.refilter() }
        side.pending = w
        if !preview { DispatchQueue.main.asyncAfter(deadline: .now() + JournalSearchSide.burst, execute: w) }
    }
    /// The answer a burst is waiting for, now (the preview's timing).
    func flushSearch() { if let w = searchSide.pending { searchSide.pending = nil; w.perform() } }

    /// The index gets the rows as soon as they are built, off the main thread, so the first key after an open is
    /// answered by it (speed round, 15 November 2026: it was made at the first search, a cold build under the user's key).
    /// Only what changed since the last hand-over is indexed again (JournalEngine.update).
    func warmSearch() {
        guard !preview else { return }
        let rows = self.rows
        searchEngine.update(version: searchVersion, count: rows.count, id: { rows[$0].id }, sig: { rows[$0].searchSig }, doc: { rows[$0].searchDoc })
    }

    /// Changes when the list of rows is rebuilt (row indices move).
    var rowsVersion: Int { buildTick &* 1_000_003 &+ rows.count }
    /// Changes whenever the rows do (a build, a tag patch, a pin, a change): the index re-reads them only then.
    var searchVersion: Int { buildTick &* 1_000_003 &+ tapeTick &* 31 &+ rows.count }

    /// The search's own state for this window (an extension cannot hold stored properties).
    var searchSide: JournalSearchSide {
        let k = ObjectIdentifier(self)
        if let s = JournalSearchSide.all[k] { return s }
        let s = JournalSearchSide()
        JournalSearchSide.all[k] = s
        return s
    }
    /// The index, made at the first search (previews: on the main thread, at once).
    var searchEngine: JournalEngine {
        if let e = searchSide.engine { return e }
        let e = JournalEngine(inline: preview)
        let store = Entities.store
        let names = { NameFormTable(store.surfaces.mapValues { $0.map { ($0.index, $0.how) } },
                                    needsContext: Set(store.surfaceFlags.filter { $0.value.needs_context == true }.keys)) }
        if preview { e.service.index.names = names() } else { e.service.queue.async { e.service.index.names = names() } }
        e.onReady = { [weak self] in
            guard let self else { return }
            log("window: search index built, \(self.rows.count) items, \(Int(e.buildMs)) ms")
            self.refilter()
        }
        searchSide.engine = e
        return e
    }

    /// What the window can draw beside the search field: the query's filters (`searchChips`), date words offered as
    /// filters (`searchSuggestions`), the corrected query (`searchDidYouMean`), counts of the found set per kind word and
    /// per chunk id. Plain data; the typed words work without any of it.
    var searchChips: [SearchChip] { searchSide.view.chips }
    var searchSuggestions: [SearchOffer] { searchSide.view.suggestions }
    var searchDidYouMean: (query: String, why: String)? { searchSide.view.didYouMean.map { ($0, searchSide.view.didYouMeanWhy) } }
    /// A chip's ✕ or a suggestion picked: the query text changes (and the search runs again).
    func dropChip(_ c: SearchChip) { query = JournalSearch.parse(query).removing(c) }
    func takeSuggestion(_ o: SearchOffer) { query = JournalSearch.parse(query).applying(o) }

    /// The stream's lines from the found rows: deleted (still undoable) and hidden rows left out, the scope applied,
    /// best first when the index ranked them, else newest first. A new query chooses its first (best) row.
    private func show(hits found: [Int], ranked: Bool) {
        searchSide.shown = StreamRules.coreText(query)   // the marks follow the words these hits answer
        searchSide.last = (found, ranked)
        let ids = rowCols.ids, gone = goneIds.union(journalStore.hidden)
        let sq = StreamRules.parse(query)
        let order = ranked ? found : found.sorted()
        let at = preview ? now : Date().timeIntervalSince1970
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.calendar = Calendar.current
        var out: [JLine] = []
        out.reserveCapacity(order.count)
        var dayCache: [Int: String] = [:]
        for i in order where i < ids.count && i < rows.count && !gone.contains(ids[i]) {
            let r = rows[i]
            guard StreamRules.inScope(streamFacts(r), sq, now: at) else { continue }
            let dk = Int(r.at / 3600)   // the day key, once per hour of rows
            let day = dayCache[dk] ?? { let s = df.string(from: Date(timeIntervalSince1970: r.at)); dayCache[dk] = s; return s }()
            out.append(JLine(kind: .row, id: r.id, item: i, chunk: day))
        }
        stream.ranked = ranked && !StreamRules.coreText(query).trimmingCharacters(in: .whitespaces).isEmpty
        results = out.count
        lines = out
        let q = query
        if searchSide.rankedFor != q {
            searchSide.rankedFor = q
            chosen = lines.first?.id; open = nil
            if stream.limit > 160 { stream.limit = 160 }
        } else if let c = chosen, lines.contains(where: { $0.id == c }) {} else {
            chosen = lines.first?.id; open = nil
        }
        if !picked.isEmpty { let s = Set(lines.map(\.id)); picked.removeAll { !s.contains($0) } }
        if firstPaint == nil, !rows.isEmpty { firstPaint = Date().timeIntervalSince1970 }
        warmCards()   // every zoom level's cards for these rows, off the main thread (StreamModel)
    }
    /// The stream again from the last hits (a pin, a delete, a hidden row): no search.
    func reflow() { let l = searchSide.last; show(hits: l.hits, ranked: l.ranked) }

    /// One row's facts the scope words read.
    func streamFacts(_ r: TapeItem) -> StreamRules.Facts {
        StreamRules.Facts(kindId: r.kindId, pinned: r.pinned, app: r.app, tags: r.tags.map(\.name), at: r.at,
                          hay: r.hay.isEmpty ? (r.current + " " + r.app).lowercased() : r.hay,
                          shot: r.shot != nil || r.entry?.shot.isEmpty == false)
    }

    // MARK: moving

    var currentLine: JLine? { chosen.flatMap { c in lines.first { $0.id == c } } }
    /// The chosen item.
    var current: TapeItem? {
        guard let l = currentLine, l.item >= 0, l.item < rows.count else { return nil }
        return rows[l.item]
    }
    func item(_ id: String) -> TapeItem? { rowCols.ids.firstIndex(of: id).flatMap { $0 < rows.count ? rows[$0] : nil } }

    func choose(_ id: String) {
        if chosen != id { open = nil; showOriginal = false; if editing != nil, editing != "new" { cancelEdit() } }
        chosen = id
        if !NSEvent.modifierFlags.contains(.shift) && !NSEvent.modifierFlags.contains(.command) { picked = [] }
        record()
    }

    /// ↑ ↓ ⇞ ⇟; 0: the chosen row (or the first) gets the keys. The stream draws more rows when the move reaches its end.
    func move(_ by: Int) {
        guard page == .tape, !commandMode, !lines.isEmpty else { return }
        let i = chosen.flatMap { c in lines.firstIndex { $0.id == c } } ?? -1
        let j = by == 0 ? max(0, i) : max(0, min(lines.count - 1, i < 0 ? 0 : i + by))
        if j >= stream.limit - 1 { stream.limit = j + 60 }
        choose(lines[j].id)
    }

    /// Return from the menu or the preview: a command runs, else the chosen row opens in place.
    func enter() {
        if commandMode { plan(); return }
        guard let it = current else { return }
        open = open == it.id ? nil : it.id
    }

    /// Esc, step by step (pages: back).
    func escape() {
        if page != .tape { back(); return }
        if commandMode { commandMode = false; command = ""; options = []; return }
        if editing != nil { cancelEdit(); return }
        if open != nil { open = nil; return }
        if !query.isEmpty { query = "" }
    }

    func back() { stopPlaying(); page = .tape; focusField += 1 }
    func openDoc(_ d: CallDoc) { stopPlaying(); doc = d; page = .doc; if d.turns.isEmpty { loadWarnings(d) } }
    func show(_ p: Page) { page = page == p ? .tape : p; if page == .tape { focusField += 1 } }
    func startCommand() { page = .tape; commandMode = true; nav.region = .search; focusField += 1 }

    // MARK: several items

    /// ⇧↑ ⇧↓: the next row joins the picked ones (or leaves, going back).
    func extend(_ d: Int) {
        guard !lines.isEmpty else { return }
        let i = chosen.flatMap { c in lines.firstIndex { $0.id == c } }
        if picked.isEmpty, let c = current?.id { picked = [c] }
        let j = max(0, min(lines.count - 1, (i ?? -1) + d))
        let id = lines[j].id
        if picked.contains(id), let c = chosen, picked.count > 1 { picked.removeAll { $0 == c } } else if !picked.contains(id) { picked.append(id) }
        chosen = id; open = nil
        status = picked.count > 1 ? "\(picked.count) picked · ⌘⇧E Combine" : ""
    }
    /// A ⇧-click: every row between the chosen one and this one.
    func pickTo(_ id: String) {
        guard let a = lines.firstIndex(where: { $0.id == (chosen ?? id) }), let b = lines.firstIndex(where: { $0.id == id }) else { choose(id); return }
        picked = (min(a, b)...max(a, b)).map { lines[$0].id }
        chosen = id; open = nil
        status = "\(picked.count) picked · ⌘⇧E Combine"
    }

    // MARK: what the user does to an item

    /// An item's actions, each a verb with its key (the open row's buttons, the right-click menu).
    func actions(_ it: TapeItem, inPlace: Bool = true) -> [RowAction] {
        var out: [RowAction] = []
        if let d = it.doc {
            out.append(RowAction(key: "⌘O", word: "Open", tip: "the whole recording as a page (Call Studio), with screenshots") { [weak self] in self?.openDoc(d) })
            out.append(RowAction(key: "E", word: "Edit", tip: "the title and the points, in place") { [weak self] in self?.choose(it.id); self?.edit() })
            out.append(RowAction(key: "⌘C", word: "Copy", tip: "the notes on the clipboard: title, people, summary, to-dos") { [weak self] in self?.copyNotes(d) })
            if !d.turns.isEmpty { out.append(RowAction(key: "⇧⌘A", word: "Copy for agent", tip: "a line that points Claude or Codex at this recording, on the clipboard") { [weak self] in self?.sendToAgent(d) }) }
            return out
        }
        if it.shot != nil { return shotActions(it) }   // a screenshot: send again, mark up again, copy for agent, show file
        let kind = openKind(it)
        out.append(RowAction(key: "⌘↵", word: "Insert", tip: "into the app you came from" + (origin?.localizedName.map { " (\($0))" } ?? "")) { [weak self] in self?.choose(it.id); self?.insert() })
        out.append(RowAction(key: "⌘C", word: "Copy", tip: "on the clipboard") { [weak self] in self?.choose(it.id); self?.copyItem() })
        if kind == .text || kind == .voice {
            out.append(RowAction(key: "E", word: "Edit", tip: "change the text here; the original is kept (⌘↵ save, esc cancel)") { [weak self] in self?.choose(it.id); self?.edit() })
        }
        if !formEntries(it, insert: false).isEmpty {   // wire round: the item (or the thing in focus) in its other written forms
            out.append(RowAction(key: "⇧⌘C", word: "Copy as…", tip: "another written form, with a preview each; ⌥ keeps it as a new clip") { [weak self] in self?.choose(it.id); self?.showForms(insert: false) })
        }
        out.append(RowAction(key: "⌘E", word: "Pick parts", tip: "keep only the parts you need, as a new clip") { PickPanel.open(it) })
        if it.change != nil {
            out.append(RowAction(key: "⌥⌘O", word: showOriginal ? "Show change" : "Show original", tip: "the text as it was kept") { [weak self] in self?.showOriginal.toggle() })
            out.append(RowAction(key: "⌥⌘R", word: "Revert", tip: "drop your change: the original text again (⌘Z Undo)") { [weak self] in self?.choose(it.id); self?.revert() })
        }
        return out
    }

    func copyItem() {
        guard let it = current else { return }
        if let d = it.doc { copyNotes(d); return }
        let t = editing == it.id ? draft : it.current
        History.copy(t); notice("On the clipboard · \(t.count) characters", undo: false)
    }

    func pin() {
        guard let it = current, let i = rows.firstIndex(where: { $0.id == it.id }) else { return }
        if it.doc != nil { notice("A recording cannot be pinned", undo: false); return }
        if it.ownDraft { journalStore.pin(String(it.id.dropFirst(2)), !it.pinned) }
        else if let q = it.quick, !it.text.isEmpty, !preview { Quick.shared.togglePin(q, it.text, app: it.app, at: it.at) }
        else if preview { if it.pinned { previewPins.remove(it.id) } else { previewPins.insert(it.id) } }
        rows[i].pinned.toggle()
        notice(rows[i].pinned ? "Pinned · on top of the Quick panel" : "Not pinned", undo: false)
        tapeTick += 1; reflow()
    }
    func togglePin(_ it: TapeItem) { choose(it.id); pin() }

    /// ⌘↵: the text (the user's change, or the editor's) into the app the user came from: that app comes to the front and the text
    /// goes in at its caret through the Quick panel's way (Capture.put: never a skipped app, a password field or under
    /// secure input; there it goes on the clipboard).
    func insert() {
        let text: String
        if editing != nil, editing != "new" { text = draft } else if let it = current, it.doc == nil { text = it.current } else { return }
        guard !text.isEmpty else { return }
        guard !preview else { notice("In the field · \(text.count) characters", undo: false); return }
        guard let o = origin, !o.isTerminated else {
            History.copy(text); notice("On the clipboard · \(text.count) characters · no app to insert into", undo: false); return
        }
        guard PutBack.raise(o, "window") else {   // only over Drafter itself (PutRules)
            History.copy(text); notice("On the clipboard · \(o.localizedName ?? "the app") is not in front", undo: false); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let how = Capture.put(text: text, origin: o)
            log("window: insert \(text.count) chars, \(how)")
        }
        status = "In the field · \(o.localizedName ?? "the app")"
    }

    func revert() {
        guard let it = current, let i = rows.firstIndex(where: { $0.id == it.id }), let c = journalStore.revert(it.id) else { return }
        rows[i].change = nil; showOriginal = false
        undos.append(("Revert", { [weak self] in
            guard let self else { return }
            self.journalStore.restore(it.id, c)
            if let j = self.rows.firstIndex(where: { $0.id == it.id }) { self.rows[j].change = c.text }
            self.buildTick += 1; self.refilter(); self.notice("Your change is back", undo: false)
        }))
        buildTick += 1; refilter()
        notice("The original again · ⌘Z Undo")
    }

    // MARK: topics and reversible tidying

    func topicInput(_ row: TapeItem) -> TopicInput {
        TopicInput(id: row.id, kind: row.kind.word, text: row.current, app: row.app, at: row.at, tags: row.tags, pinned: row.pinned)
    }

    /// The already-loaded originals, before display-only folding. Never reads history files itself.
    /// Cached by row generation and action tick so opening a tab or hovering the trigger does no extra work.
    var topicTidy: TopicTidySnapshot {
        let cache = TopicTidyCache.forModel(self)
        if cache.generation == rowsGen, cache.tick == tapeTick, let snapshot = cache.snapshot { return snapshot }
        let shown = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var raw = TapeBuild.rows(takes: takes, clips: clips, typed: typed, docs: docs, own: journalStore.file.items)
        for i in raw.indices {
            let id = raw[i].id
            raw[i].change = journalStore.changed(id)
            raw[i].tags = shown[id]?.tags ?? []
            if let r = shown[id] { raw[i].pinned = r.pinned }
            else if preview { raw[i].pinned = raw[i].pinned || previewPins.contains(id) }
            else if !raw[i].ownDraft, let q = raw[i].quick { raw[i].pinned = Quick.shared.isPinned(q, raw[i].text) }
        }
        let active = raw.filter { !journalStore.isHidden($0.id) && !goneIds.contains($0.id) }
        // A saved consolidation is an output, not another raw fragment to merge on the next visit.
        let outputs = Set(journalStore.file.items.filter { !$0.sources.isEmpty }.map { "j:" + $0.id })
        let notes = active.filter { $0.doc == nil && ($0.kind == .typed || $0.kind == .said) && !outputs.contains($0.id) && !$0.current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let candidates = active.filter { $0.doc == nil && $0.shot == nil && ($0.entry?.shot.isEmpty ?? true) && ($0.entry?.clip ?? .text) == .text }
        let clusters = TopicClusterRules.cluster(notes.map(topicInput)).filter { cluster in
            guard cluster.itemIds.count > 1 else { return false }
            let ids = Set(cluster.itemIds)
            let saved = journalStore.file.items.filter { !journalStore.isHidden("j:" + $0.id) && Set($0.sources) == ids }
            guard !saved.isEmpty else { return true }
            let merged = TopicClusterRules.mergeCleanNote(notes.filter { ids.contains($0.id) }.map { ($0.at, $0.kind.word, $0.current) }, title: cluster.title)
            return !saved.contains { $0.text == merged }
        }
        let snapshot = TopicTidySnapshot(rows: raw,
            clusters: clusters,
            candidates: TopicClusterRules.findTidyCandidates(candidates.map(topicInput)),
            archivedIDs: journalStore.hidden.sorted())
        cache.generation = rowsGen; cache.tick = tapeTick; cache.snapshot = snapshot
        return snapshot
    }

    var tidyCount: Int { topicTidy.clusters.count + topicTidy.candidates.count }

    func topicPreview(_ cluster: TopicCluster) -> String {
        let ids = Set(cluster.itemIds)
        return TopicClusterRules.mergeCleanNote(topicTidy.rows.filter { ids.contains($0.id) }.map { ($0.at, $0.kind.word, $0.current) }, title: cluster.title)
    }

    func consolidateTopic(_ cluster: TopicCluster, archiveSources: Bool) {
        if editing != nil { leaveEditor(); TopicTidyCache.forModel(self).snapshot = nil }
        let ids = Set(cluster.itemIds)
        let sources = topicTidy.rows.filter { ids.contains($0.id) && !journalStore.isHidden($0.id) && !goneIds.contains($0.id) && $0.doc == nil && ($0.kind == .typed || $0.kind == .said) }
        guard sources.count >= 2 else { return }
        let text = TopicClusterRules.mergeCleanNote(sources.map { ($0.at, $0.kind.word, $0.current) }, title: cluster.title)
        // A second click or an old selection cannot create the same output twice.
        let sourceIDs = Set(sources.map(\.id))
        guard !journalStore.file.items.contains(where: { !journalStore.isHidden("j:" + $0.id) && Set($0.sources) == sourceIDs && $0.text == text }) else { return }
        let note = journalStore.add(kind: "draft", text: text, sources: sources.map(\.id), pinned: false)
        let hidden = archiveSources ? journalStore.hide(sources.filter { !$0.pinned }.map(\.id)) : []
        undos.append(("Merge topic", { [weak self] in
            guard let self else { return }
            // Keep even the generated note recoverable, including any later edits to it.
            self.journalStore.hide(["j:" + note.id])
            self.journalStore.unhide(hidden)
            self.tidyChanged(); self.status = "Merge undone · sources restored · clean note archived"
        }))
        picked = []; chosen = "j:" + note.id
        tidyChanged(); status = "Clean note saved · \(hidden.count) archived · ⌘Z Undo"
    }

    func archiveItems(_ ids: [String]) {
        if editing != nil { leaveEditor(); TopicTidyCache.forModel(self).snapshot = nil }
        let wanted = Set(ids)
        let safe = topicTidy.rows.filter { wanted.contains($0.id) && !$0.pinned && $0.doc == nil && !goneIds.contains($0.id) }.map(\.id)
        let hidden = journalStore.hide(safe)
        guard !hidden.isEmpty else { return }
        undos.append(("Archive", { [weak self] in
            guard let self else { return }
            self.journalStore.unhide(hidden); self.tidyChanged(); self.status = "\(hidden.count) restored"
        }))
        tidyChanged(); status = "\(hidden.count) archived · ⌘Z Undo"
    }

    func restoreArchived(_ ids: [String]) {
        let restored = Array(Set(ids).intersection(journalStore.hidden)).sorted()
        guard !restored.isEmpty else { return }
        journalStore.unhide(restored)
        undos.append(("Restore", { [weak self] in
            guard let self else { return }
            self.journalStore.hide(restored); self.tidyChanged(); self.status = "\(restored.count) archived again"
        }))
        tidyChanged(); status = "\(restored.count) restored · ⌘Z Undo"
    }

    private func tidyChanged() {
        tapeTick += 1
        // Hide immediately; rebuild asynchronously to unfold any remaining raw rows correctly.
        refilter(); rebuildTape()
    }

    // MARK: delete and undo

    /// ⌘⌫ (or Delete on the open row): out of the stream at once, with "Undo" in the notice and ⌘Z; out of the files
    /// when the 8 seconds are over (or at the next delete). A journal draft is taken out of journal.json, Undo puts it
    /// back. A recording is not deleted here.
    func delete() {
        guard let it = current else { return }
        if it.doc != nil { notice("Recordings are not deleted from the journal", undo: false); return }
        if it.ownDraft {
            guard let gone = journalStore.remove(String(it.id.dropFirst(2))) else { return }
            undos.append(("Delete", { [weak self] in self?.journalStore.put(gone); self?.chosen = it.id; self?.rebuildTape(); self?.notice("Back in the journal", undo: false) }))
            move(1); notice("Draft deleted · Undo (⌘Z)")
            rebuildTape(); return
        }
        guard it.quick != nil else { return }
        commitGone()
        let w = DispatchWorkItem { [weak self] in self?.commitGone() }
        gone = (it, w); goneIds.insert(it.id)
        undos.append(("Delete", { [weak self] in self?.undoRemove() }))
        if !preview { DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w) }
        open = nil
        let next = lines.firstIndex { $0.id == it.id }.flatMap { i in i + 1 < lines.count ? lines[i + 1].id : i > 0 ? lines[i - 1].id : nil }
        reflow()
        if let next { chosen = next }
        notice("Deleted · Undo within 8 s (⌘Z)")
    }
    func undoLast() { guard let u = undos.popLast() else { notice("Nothing to undo", undo: false); return }; u.run() }
    func undoRemove() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil; goneIds.remove(g.item.id)
        reflow()
        chosen = g.item.id; notice("Back in the journal", undo: false)
    }
    func commitGone() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil
        let it = g.item
        if let q = it.quick, !preview {
            if Quick.shared.isPinned(q, it.text) { Quick.shared.togglePin(q, it.text, app: it.app, at: it.at) }
            History.forget(q, it.entry?.text.isEmpty == false ? it.entry!.text : it.text, drafts: it.entry?.drafts ?? [])
        }
        switch it.kind {
        case .copied: clips.removeAll { "c:\(Int($0.when.timeIntervalSince1970 * 1000)):\($0.text.count)" == it.id }
        case .typed: typed.removeAll { "t:" + $0.id == it.id }
        case .said: takes.removeAll { "v:" + $0.id == it.id }
        case .call: break
        }
        goneIds.remove(it.id)
        undos.removeAll { $0.name == "Delete" }
        if stream.notice?.text.hasPrefix("Deleted") == true { stream.notice = nil }
        rebuildTape()
        log("window: deleted a \(it.kind.word) item")
    }

    // MARK: keys

    /// The facts StreamKeys needs, from the window's state.
    func navState() -> StreamKeys.State {
        var s = nav
        s.rows = lines.count
        s.row = chosen.flatMap { c in lines.firstIndex { $0.id == c } } ?? 0
        if let it = current, open == it.id { s.open = openKind(it) } else { s.open = .none }
        s.audio = current.map(hasAudio) ?? false
        s.picked = max(1, picked.count)
        s.query = !query.isEmpty
        s.command = commandMode
        if s.region == .editor, editing == nil, stream.lineEdit == nil { s.region = .list }
        if s.region == .palette, palette == nil { s.region = .list }
        return s
    }
    func syncNav() { nav = navState() }

    /// One key in the window. true: the window took it; false: it goes on (to the search field or the editor).
    func key(_ e: NSEvent) -> Bool {
        guard page == .tape else { return false }
        syncNav()
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(e.keyCode)
        let inEditor = nav.region == .editor
        let onItem = current != nil && nav.region != .search
        // a thing found in the chosen text (wire round): ⌥↓ ⌥↑, then ↵, its action keys and esc while it has the focus
        if !inEditor, current != nil, nav.region != .palette, let r = foundKey(code: code, mods: mods, chars: e.charactersIgnoringModifiers) { return r }
        if inEditor, stream.lineEdit != nil {
            if code == 53, mods.isEmpty { stream.lineEdit = nil; nav.region = .list; return true }
            if (code == 36 || code == 76), mods == [.command] || mods.isEmpty { saveLine(); return true }
            return false
        }
        // the window's own keys
        if !inEditor {
            switch (mods, code) {
            case ([.command], 8) where onItem && currentShot != nil: copyShotForAgent(); return true   // ⌘C a shot: copy for agent
            case ([.command], 14) where currentShot != nil: markShot(); return true                  // ⌘E a shot: mark up again
            case ([.command], 31) where currentShot != nil: showShotFile(); return true              // ⌘O a shot: show the file
            case ([.command], 8) where onItem: copyItem(); return true              // ⌘C Copy
            case ([.command, .shift], 8) where onItem: showForms(insert: false); return true             // ⇧⌘C Copy as…
            case ([.command, .shift], 36), ([.command, .shift], 76): if onItem { showForms(insert: true); return true }   // ⇧⌘↵ Insert as…
            case ([.command], 35) where current != nil: pin(); return true          // ⌘P Pin
            case ([.command], 14) where current != nil: if let it = current { PickPanel.open(it) }; return true   // ⌘E Pick parts
            case ([.command], 51) where current != nil && nav.region != .search: delete(); return true       // ⌘⌫ Delete
            case ([.command], 6) where !undos.isEmpty && !(nav.region == .search && !query.isEmpty): undoLast(); return true   // ⌘Z Undo
            case ([.command, .option], 31) where current?.change != nil: showOriginal.toggle(); return true   // ⌥⌘O
            case ([.command, .option], 15) where current?.change != nil: revert(); return true               // ⌥⌘R
            case ([.command], 31) where current?.doc != nil: if let d = current?.doc { openDoc(d) }; return true // ⌘O
            case ([.command], 27): zoom(by: -1); return true                                                    // ⌘− zoom out (StreamZoomRules)
            case ([.command], 24), ([.command, .shift], 24): zoom(by: 1); return true                           // ⌘+ zoom in
            case ([.command], 29): zoomReset(); return true                                                     // ⌘0 back to rows
            case ([], 125) where stream.zoom.summary && nav.region != .search: moveCard(1); return true
            case ([], 126) where stream.zoom.summary && nav.region != .search: moveCard(-1); return true
            case ([], 36) where stream.zoom.summary && nav.region != .search, ([], 76) where stream.zoom.summary && nav.region != .search:
                if let id = chosen, let c = zoomCards.first(where: { $0.ids.contains(id) }) { zoomInto(c) }; return true
            case ([.command], 37) where current.map(hasAudio) == true:                                         // ⌘L Play
                if let it = current { open = it.id; playPause(it) }; return true
            default: break
            }
        }
        // the search's extras: ⇥ takes the offered date filter, ⌫ at the end of a filter word removes the whole filter
        if nav.region == .search, !commandMode, mods.isEmpty {
            if code == 48, let o = searchSuggestions.first { takeSuggestion(o); return true }
            if code == 51, let c = searchChips.last, NSMaxRange(c.range) == (StreamRules.coreText(query) as NSString).length, StreamRules.coreText(query) == query { dropChip(c); return true }
        }
        let k: StreamKeys.Key
        switch (code, mods) {
        case (125, []): k = .down
        case (126, []): k = .up
        case (125, [.shift]): k = .shiftDown
        case (126, [.shift]): k = .shiftUp
        case (125, [.command]): k = .cmdDown
        case (126, [.command]): k = .cmdUp
        case (123, []): k = .left
        case (124, []): k = .right
        case (116, []): k = .pageUp
        case (121, []): k = .pageDown
        case (48, []): k = .tab
        case (48, [.shift]): k = .backTab
        case (36, []), (76, []): k = .ret
        case (36, [.command]), (76, [.command]): k = .insert
        case (53, []): k = .esc
        case (14, [.command, .shift]): k = .combine
        case (17, [.command]): k = .goTo                                          // ⌘T Go to a day
        case (33, [.command]): k = .back                                          // ⌘[
        case (30, [.command]): k = .forward                                       // ⌘]
        case (49, []): k = .space
        case (18...23, [.command]), (25, [.command]), (26, [.command]), (28, [.command]):
            let digits: [Int: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
            guard let n = digits[code] else { return false }
            k = .digit(n)
        default:
            guard mods.subtracting(.shift).isEmpty, let ch = e.characters, let c = ch.first, !c.isNewline, c.isLetter || c.isNumber || c.isPunctuation || c.isSymbol else { return false }
            k = (c == "e" || c == "E") && mods.isEmpty ? .e : .letter
        }
        let (s, eff) = StreamKeys.route(nav, k)
        nav = s
        switch eff {
        case .pass: return false
        case .none: return true
        case .move(let n): move(n)
        case .open: if let it = current { open = it.id }
        case .close: open = nil
        case .openPage: if let d = current?.doc { openDoc(d) }
        case .edit: edit()
        case .save: saveEdit()
        case .cancel: cancelEdit()
        case .insert: insert()
        case .combine: combine(); if editing == nil { nav.region = .list }
        case .extend(let d): extend(d)
        case .single: picked = []; status = ""
        case .jumpDay(let d): jumpDay(d)
        case .clearSearch: query = ""
        case .endCommand: commandMode = false; command = ""; options = []
        case .plan: plan()
        case .closeWindow: if !preview { NSApp.keyWindow?.performClose(nil) }
        case .typeInSearch: focusField += 1; return false
        case .openPalette: openPalette()
        case .closePalette: closePalette()
        case .palettePick: paletteGo()
        case .paletteMove(let d): paletteIndex = max(0, min(max(0, paletteResults.count - 1), paletteIndex + d))
        case .historyBack: historyStep(true)
        case .historyForward: historyStep(false)
        case .scope(let n): if let t = StreamRules.scopeToken(digit: n) { query = StreamRules.setting(kindToken: t, in: query); flushSearch() }
        case .playPause: if let it = current { open = it.id; playPause(it) }
        }
        tapeTick += 1
        return true
    }
}

// MARK: tags the user hid or pinned (tags round, 17 November 2026)
extension WindowModel {
    private func tagsChanged(_ p: TagRules.Prefs) {
        TagPrefs.shared.set(p)
        facetCache = nil
        objectWillChange.send()
        refilter()
    }
    func hideTag(_ t: TapeTag) {
        var p = TagPrefs.shared.prefs; p.hide(t)
        tagsChanged(p)
        status = "Hid the tag \(t.name) · Show hidden tags is in the ⋯ menu"
    }
    func pinTag(_ t: TapeTag, _ on: Bool) { var p = TagPrefs.shared.prefs; p.pin(t, on); tagsChanged(p) }
    func showHiddenTags() { var p = TagPrefs.shared.prefs; p.showAll(); tagsChanged(p) }
    var hiddenTagCount: Int { TagPrefs.shared.prefs.hidden.count }
    func tagPinned(_ t: TapeTag) -> Bool { TagPrefs.shared.prefs.isPinned(t) }
    /// A tag in the reader, pressed: a site opens the item's link (or the site), an app or a name shows its items.
    func openTag(_ t: TapeTag, item it: TapeItem) {
        switch t.kind {
        case "site": if let u = TagRules.open(t, link: it.entry?.clip == .link ? it.text : nil) { NSWorkspace.shared.open(u) }
        case "app": query = "in:" + t.name.lowercased().replacingOccurrences(of: " ", with: "") + " "; flushSearch(); focusField += 1
        case "person", "chat", "project": query = StreamRules.setting(who: t.name, in: ""); flushSearch(); focusField += 1
        default: query = "\"" + t.name.lowercased() + "\" "; flushSearch(); focusField += 1
        }
    }

    /// Jump from Names into the stream: "@name" (the person's or project's tag), else the name searched.
    func openEntityInJournal(names: [String], fallback: String) {
        page = .tape
        let keys = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let tagged = keys.first { n in rows.prefix(3000).contains { $0.tags.contains { $0.name.lowercased() == n.lowercased() } } }
        query = tagged.map { StreamRules.setting(who: $0, in: "") } ?? fallback
        flushSearch()
        focusField += 1
    }
    /// How many rows carry a tag for these names (Names shows the count beside "Open in the journal").
    func journalMatch(for names: [String]) -> (tag: TapeTag?, count: Int) {
        let keys = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        guard !keys.isEmpty else { return (nil, 0) }
        var tag: TapeTag?, n = 0
        for r in rows { if let t = r.tags.first(where: { keys.contains($0.name.lowercased()) }) { tag = tag ?? t; n += 1 } }
        return (tag, n)
    }
}

/// Per-window local suggestions. Weak keys let closing a window release its cached text.
struct TopicTidySnapshot {
    let rows: [TapeItem]
    let clusters: [TopicCluster]
    let candidates: [TidyCandidate]
    let archivedIDs: [String]
}
private final class TopicTidyCache {
    private static let windows = NSMapTable<WindowModel, TopicTidyCache>.weakToStrongObjects()
    var generation = -1
    var tick = -1
    var snapshot: TopicTidySnapshot?
    var groupGen = -1
    var groupVis: [Bool] = []
    var groupClusters: [TopicCluster] = []
    static func forModel(_ model: WindowModel) -> TopicTidyCache {
        if let cache = windows.object(forKey: model) { return cache }
        let cache = TopicTidyCache(); windows.setObject(cache, forKey: model); return cache
    }
}
