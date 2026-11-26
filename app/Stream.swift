// The journal as one calm column, search first (stream round, 23 November 2026; the user chose direction C: "c feels
// right, but with some better controls over recording and editing especially"). A big search field on top, then the
// items as one stream: newest first under day headings, or best first while words are searched (the journal's own
// search, JournalSearch; scope words narrow it, app/StreamRules.swift). Each item is one row that opens in place to its
// whole text, its tags, a player when it has audio, and its actions as standard bordered buttons, each with its key.
// The Record control sits at the top right beside ⋯. Model: app/JournalModel.swift and app/StreamModel.swift.
import AppKit
import SwiftUI

/// The journal's keys, for Help (tests/key_map.swift reads `JournalKeys.all` there).
enum JournalKeys {
    static let all: [(String, String)] = [
        ("a letter", "Search: it goes to the search field"), ("↓ ↵", "From the field: the best row, or open it"),
        ("↑ ↓", "Move: the row before or after"), ("⇞ ⇟", "Move by eight rows"), ("⌘↑ ⌘↓", "The day before or after"),
        ("↵", "Open the row in place; on an open text: edit it; on an open recording: its page"),
        ("space", "Play or pause an open voice note or recording; else open or close the row"),
        ("E", "Edit the open row in place (a recording: its title and points)"), ("⌘↵", "Insert into the app you came from; in the editor: save"),
        ("esc", "Step out: the editor (nothing saved), the picked rows, the open row, the search; then close the window"),
        ("⌘C", "Copy"), ("⇧⌘C", "Copy as… another written form"), ("⌘P", "Pin or Unpin"), ("⇧⌘A", "Copy for agent"),
        ("⇧↑ ⇧↓ ⌘-click", "Pick several rows"), ("⌘⇧E", "Combine the picked rows into one draft"),
        ("⌥⌘O", "Show original (a changed item)"), ("⌥⌘R", "Revert: the original text again"),
        ("⌘⌫", "Delete (Undo in the notice for 8 s)"), ("⌘Z", "Undo the last Delete, Edit, Combine or Revert"),
        ("⌘L", "Play a voice note or a recording"), ("⌘O", "Open a recording as a page (Call Studio)"),
        ("⌘T", "Go to: a day (\"last Tuesday\", \"12 березня\"), a kind, a person, an app"),
        ("⌘[ ⌘]", "Back and forward: where you were before or after"),
        ("⌘1-9", "Scopes: everything, drafts, voice, clips, calls, links, screens, files, pinned"),
        ("⌘F", "Search the journal"), ("⌘K", "Ask Drafter (a command)"),
        ("@name links calls screens in:app today", "Scope words in the field narrow the stream")]
}

// MARK: the bar

/// The journal's bar: the Record control and one ⋯ menu (Find, Go, the pages). Every item shows its real key.
struct StreamBar: View {
    @EnvironmentObject var m: WindowModel
    var title = ""
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 20, height: 1)   // the window's three dots sit over the rail and here
            if m.page != .tape { BackRow(title: m.page == .doc ? title : "") }   // Rebuild B: the page names itself in a chip
            Spacer()
            RecordControl(live: RecordLive.shared, clock: RecordLive.shared.clock)
            SwiftUI.Menu {
                Section("Go") {
                    Button("Search") { m.page = .tape; m.commandMode = false; m.nav.region = .search; m.focusField += 1 }.keyboardShortcut("f")
                    Button("Go to a day…") { m.page = .tape; m.openPalette() }.keyboardShortcut("t")
                    Button("Back") { m.historyStep(true) }.keyboardShortcut("[").disabled(!m.canBack)
                    Button("Forward") { m.historyStep(false) }.keyboardShortcut("]").disabled(!m.canForward)
                    Button("Ask Drafter…") { m.startCommand() }.keyboardShortcut("k")
                }
                Section("Find in the journal") {
                    Button("People and projects…") { m.query = "@"; m.focusField += 1 }
                    Button("Links") { m.query = "links "; m.flushSearch(); m.focusField += 1 }
                    Button("Screens and pictures") { m.query = "screens "; m.flushSearch(); m.focusField += 1 }
                    Button("Tidy topics…") { m.stream.tidyOpen = true }
                    Toggle("Fold past days into summaries", isOn: Binding(get: { m.stream.foldPast }, set: { m.stream.foldPast = $0 }))
                }
                Section("Pages") {
                    Button("Names") { m.show(.names) }.keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("Links & Files") { m.show(.links) }.keyboardShortcut("l", modifiers: [.command, .shift])
                    Button("What Drafter sees") { m.show(.screen) }.keyboardShortcut("i", modifiers: [.command, .shift])
                    Button("Dictionary") { m.show(.dictionary) }.keyboardShortcut("d", modifiers: [.command, .shift])
                    Button("Shortcuts") { m.show(.shortcuts) }.keyboardShortcut("j")
                }
                Divider()
                Button("Settings…") { m.show(.settings) }.keyboardShortcut(",")
                Button("Help") { m.show(.help) }.keyboardShortcut("/")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Go to a day, Names, Links, Screen, Settings and Help")
        }
        .padding(.horizontal, 14).frame(height: m.page == .tape ? 44 : 44)
        .overlay(alignment: .bottom) { if m.page != .tape { Rectangle().fill(UIInk.line).frame(height: 0.5) } }
        .sheet(isPresented: Binding(get: { m.stream.tidyOpen }, set: { m.stream.tidyOpen = $0 })) { TopicTidyView().environmentObject(m) }
    }
}

/// Record, at the top right. Idle: a menu with the same jobs as ⇧ Right Option and the menu bar's first item.
/// Recording: what records, the time, a level meter, Pause or Resume, Stop (a second click within 3 s), Open.
struct RecordControl: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var live: RecordLive
    @ObservedObject var clock: RecordClock
    @State private var stopArmed = false
    var body: some View {
        if let r = m.recordingNow {
            HStack(spacing: 8) {
                Circle().fill(r.paused ? UIInk.faint : UIInk.coral).frame(width: 8, height: 8)
                Text(r.title).font(NativeFont.text(12, .medium)).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                Text(PlayerRules.clock(Double(m.preview ? r.seconds : max(r.seconds, clock.seconds))))
                    .font(NativeFont.num(12)).foregroundStyle(UIInk.muted).frame(minWidth: 36, alignment: .leading)
                LevelMeter(call: r.call, paused: r.paused)
                Button(r.paused ? "Resume" : "Pause") { m.togglePauseRecording() }
                    .help(r.paused ? "Go on recording" : "Pause: nothing is recorded until Resume")
                Button(stopArmed || live.stopArmed ? "Click to stop" : "Stop") { stop() }
                    .tint(UIInk.coral)
                    .help("Stop and keep the recording (a second click within 3 s, so a stray click never ends a call)")
                if let d = m.docs.first(where: \.live) {
                    Button("Open") { m.openDoc(d) }.help("The recording's page, with its live transcript")
                }
            }
            .buttonStyle(.bordered).controlSize(.regular)
            .onAppear { if !m.preview, live.active { live.flush() } }
        } else {
            SwiftUI.Menu {
                Button { m.startLongNote() } label: { Label("Long note, or the call on now  ⇧ Right Option", systemImage: "waveform") }
                Button { m.startMeetingNotes() } label: { Label("Meeting notes for the event on now", systemImage: "calendar") }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .menuStyle(.borderedButton).controlSize(.regular).fixedSize()
            .help("Record a long note or a call (⇧ Right Option), or meeting notes")
        }
    }
    func stop() {
        if m.preview { stopArmed.toggle(); return }
        if live.active { live.stopClicked(); return }
        if !stopArmed { stopArmed = true; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { stopArmed = false }; return }
        stopArmed = false
        Talk.shared.stopRecording("the window")
    }
}

/// Two small bars: the user's microphone, and the other side on a call.
struct LevelMeter: View {
    @EnvironmentObject var m: WindowModel
    let call: Bool
    let paused: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let me = m.stream.previewRecording?.me ?? RecordLive.shared.me
            let them = m.stream.previewRecording?.them ?? RecordLive.shared.them
            VStack(spacing: 3) {
                bar(paused ? 0 : me)
                if call { bar(paused ? 0 : them) }
            }
            .frame(width: 44)
            .accessibilityLabel("Sound level")
        }
    }
    func bar(_ v: CGFloat) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(UIInk.soft)
                Capsule().fill(UIInk.ok).frame(width: max(3, g.size.width * min(1, max(0, v))))
            }
        }.frame(height: 4)
    }
}

// MARK: the column

struct StreamView: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var q: QueryBox
    @ObservedObject var st: StreamState
    var body: some View {
        // folded past days take one line each, so the list may reach further back (StreamGroupRules)
        let shown = Array(m.lines.prefix(st.foldPast && !st.ranked ? max(st.limit, 4000) : st.limit))
        let sq = StreamRules.parse(q.text)
        GeometryReader { g in
            let w = min(680, max(320, g.size.width - 48))
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    StreamField(q: q, total: m.results, query: sq)
                    if m.commandMode { CommandOptions() }
                    else { StreamUnderField(query: sq, total: m.results) }
                }
                .frame(width: w).padding(.top, 4).padding(.bottom, 8)
                if m.editing == "new" { CombineCard(st: st).frame(width: w).padding(.bottom, 8) }
                if st.zoom.summary {
                    StreamCards(st: st).frame(maxWidth: .infinity).id("zoom-" + st.zoom.name)
                } else if st.byTopic {
                    StreamTopics(st: st).frame(maxWidth: .infinity)
                } else {
                rowsList(shown: shown, sq: sq, w: w)
                }
                StreamFoot(st: st).frame(width: w)
            }
            .frame(width: g.size.width)
        }
        .overlay(alignment: .top) { if m.palette != nil { GoToPalette().padding(.top, 60) } }
    }

    /// The rows, newest first under day headings (past days folded), or best first while words are searched.
    @ViewBuilder func rowsList(shown: [JLine], sq: StreamRules.Query, w: CGFloat) -> some View {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            if st.ranked {
                                Section {
                                    ForEach(shown, id: \.id) { l in row(l, dated: true) }
                                } header: { StreamDayHead(title: "Best matches", count: m.results) }
                            } else {
                                let chosenDay = m.current.map { StreamZoomRules.dayKey($0.at, cal: .current) }
                                ForEach(days(shown), id: \.key) { day in
                                    let dk = StreamZoomRules.dayKey(day.at, cal: .current)
                                    if folded(dk, chosenDay: chosenDay) {
                                        DayFoldLine(day: day, topics: m.dayTopics(dk, day.lines), st: st, dayKey: dk).id("fold:" + day.key)
                                    } else {
                                        Section {
                                            ForEach(day.lines, id: \.id) { l in row(l, dated: false) }
                                        } header: {
                                            StreamDayHead(title: day.title, count: day.lines.count,
                                                          fold: st.openedDays.contains(dk) ? { st.openedDays.remove(dk) } : nil)
                                        }
                                    }
                                }
                            }
                            if shown.isEmpty { StreamEmpty(query: sq) }
                            if m.lines.count > shown.count {
                                Button("Show \(min(300, m.lines.count - shown.count)) more") { st.limit += 300 }
                                    .buttonStyle(.link).font(NativeFont.text(13)).padding(.vertical, 18).frame(maxWidth: .infinity)
                            }
                        }
                        .frame(width: w).padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: m.chosen) { _, id in if let id, m.nav.region != .search { withAnimation(nil) { proxy.scrollTo(id, anchor: nil) } } }
                    .onChange(of: m.open) { _, id in if let id { proxy.scrollTo(id, anchor: nil) } }
                }
    }

    @ViewBuilder func row(_ l: JLine, dated: Bool) -> some View {
        if l.item >= 0, l.item < m.rows.count {
            let it = m.rows[l.item]
            StreamRow(it: it, open: m.open == it.id, chosen: m.chosen == it.id, picked: m.picked.count > 1 && m.picked.contains(it.id), dated: dated,
                      density: st.zoom.density, st: st).id(it.id)
        }
    }

    struct Day { let key: String; let title: String; let lines: [JLine]; var at = 0.0 }
    func folded(_ dk: String, chosenDay: String?) -> Bool {
        let now = m.now, cal = Calendar.current
        return StreamGroupRules.folded(day: dk, today: StreamZoomRules.dayKey(now, cal: cal), yesterday: StreamZoomRules.dayKey(now - 86400, cal: cal),
                                       foldPast: st.foldPast, ranked: st.ranked, opened: st.openedDays, chosenDay: chosenDay)
    }
    func days(_ lines: [JLine]) -> [Day] {
        let cal = Calendar.current, now = Date(timeIntervalSince1970: m.now)
        var out: [Day] = []; var cur: [JLine] = []; var curKey = ""; var curAt = 0.0
        func flush() { if !cur.isEmpty { out.append(Day(key: curKey, title: StreamRules.dayTitle(Date(timeIntervalSince1970: curAt), now: now, cal: cal), lines: cur, at: curAt)); cur = [] } }
        for l in lines {
            if l.chunk != curKey { flush(); curKey = l.chunk; curAt = l.item >= 0 && l.item < m.rows.count ? m.rows[l.item].at : 0 }
            cur.append(l)
        }
        flush()
        return out
    }
}

/// The foot of the column: the notice with Undo, the picked rows' bar, or what the keys do here.
struct StreamFoot: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var st: StreamState
    var body: some View {
        HStack(spacing: 10) {
            if m.picked.count > 1, m.editing != "new" {
                Text("\(m.picked.count) picked").font(NativeFont.text(12, .medium))
                Spacer()
                Button { m.combine() } label: { KeyedLabel(word: "Combine", key: "⌘⇧E") }.buttonStyle(.borderedProminent)
                Button { m.picked = []; m.status = "" } label: { KeyedLabel(word: "Clear", key: "esc") }.buttonStyle(.bordered)
            } else if let n = st.notice {
                Image(systemName: "checkmark.circle").foregroundStyle(UIInk.muted)
                Text(n.text).font(NativeFont.text(12)).lineLimit(1)
                Spacer()
                if n.undo { Button { m.undoFromNotice() } label: { KeyedLabel(word: "Undo", key: "⌘Z") }.buttonStyle(.bordered) }
            } else {
                Text(st.zoom.summary ? "↑↓ move · ↵ or click zoom in · ⌘− ⌘+ zoom · ⌘0 rows" : StreamKeys.hints(m.navState()))
                    .font(NativeFont.text(11)).foregroundStyle(UIInk.faint).lineLimit(1)
                Spacer()
                SwiftUI.Picker("", selection: Binding(get: { st.byTopic }, set: { st.byTopic = $0 })) {
                    Text("Time").tag(false); Text("Topics").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .help("By time, or grouped by topic (what the rows share: people, projects, words)")
                ZoomControl(st: st)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 12).frame(height: 40)
    }
}

/// A button's word and its key, the key quieter.
struct KeyedLabel: View {
    let word: String
    let key: String
    var body: some View {
        HStack(spacing: 6) {
            Text(word)
            if !key.isEmpty { Text(key).font(NativeFont.num(11)).foregroundStyle(.secondary) }
        }
    }
}

/// The big field: the scope menu at its start, the words, the count and a clear button at its end. After ⌘K it takes
/// a command, as before.
struct StreamField: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var q: QueryBox
    let total: Int
    let query: StreamRules.Query
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            if m.commandMode {
                Image(systemName: "paperplane").font(.system(size: 15)).foregroundStyle(UIInk.muted).frame(width: 22)
            } else {
                ScopeMenu(q: q, query: query)
            }
            TextField(m.commandMode ? "Ask Drafter" : "Search", text: m.commandMode ? $m.command : Binding(get: { q.text }, set: { m.query = $0 }),
                      prompt: Text(m.commandMode ? "Book 30 min tomorrow · find a free slot · ;snippet" : "Search everything you typed, said and copied")
                        .foregroundColor(UIInk.faint))
                .textFieldStyle(.plain).font(NativeFont.text(17)).focused($focused)
                .accessibilityLabel(m.commandMode ? "Command" : "Search the journal")
            if m.thinking { ProgressView().controlSize(.small) }
            else if !q.text.isEmpty, !m.commandMode {
                Text("\(total)").font(NativeFont.num(12)).foregroundStyle(UIInk.faint)
                Button { m.query = ""; m.focusField += 1 } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(UIInk.faint) }
                    .buttonStyle(.plain).help("Clear (esc)")
            } else {
                KeyChip(m.commandMode ? "esc" : "⌘K").help(m.commandMode ? "Back to search (esc)" : "Ask Drafter to do something (⌘K)")
            }
        }
        .padding(.horizontal, 14).frame(height: 46)
        .glassCard(radius: 14)   // Rebuild B: the field is glass
        .overlay { if focused && m.nav.region == .search { RoundedRectangle(cornerRadius: 14).strokeBorder(UIInk.blue.opacity(0.5), lineWidth: 1) } }
        .onChange(of: m.focusField, initial: true) { _, _ in focused = true }
        .onTapGesture { m.nav.region = .search }
    }
}

/// The scope at the field's start: its symbol and a menu (⌘1-9). Picking one writes its word into the field.
struct ScopeMenu: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var q: QueryBox
    let query: StreamRules.Query
    var body: some View {
        let cur = StreamRules.scopes.first { StreamRules.kindWords[$0.token] == query.kind && !$0.token.isEmpty } ?? StreamRules.scopes[0]
        SwiftUI.Menu {
            ForEach(Array(StreamRules.scopes.enumerated()), id: \.offset) { i, s in
                Button { m.query = StreamRules.setting(kindToken: s.token, in: q.text); m.flushSearch(); m.focusField += 1 } label: {
                    Label(s.name, systemImage: Native.symbolName(s.glyph))
                }
                .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
            }
            let people = m.topPeople(6)
            if !people.isEmpty {
                Section("People and projects") {
                    ForEach(people, id: \.self) { p in
                        Button("@" + p) { m.query = StreamRules.setting(who: p, in: q.text); m.flushSearch(); m.focusField += 1 }
                    }
                }
            }
        } label: {
            Image(systemName: Native.symbolName(query.who.isEmpty ? cur.glyph : "user"))
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(UIInk.muted)
        .help("Scope: what the stream shows (⌘1-9)")
    }
}

/// Under the field: the words that can be typed (empty field), or what the scope is with a way to the full page.
struct StreamUnderField: View {
    @EnvironmentObject var m: WindowModel
    let query: StreamRules.Query
    let total: Int
    var body: some View {
        HStack(spacing: 6) {
            if let dym = m.searchDidYouMean {
                Text("Did you mean").foregroundStyle(UIInk.faint)
                Button(dym.query) { m.query = dym.query; m.flushSearch() }.buttonStyle(.link).help(dym.why)
                Spacer()
            } else if query.isEmpty {
                Text("Try").foregroundStyle(UIInk.faint)
                ForEach(StreamRules.hints, id: \.self) { h in
                    Button(h) { m.query = h + " "; m.flushSearch(); m.focusField += 1 }
                        .buttonStyle(.plain).foregroundStyle(UIInk.muted)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 4).fill(UIInk.soft))
                }
                Spacer()
            } else if let line = StreamRules.scopeLine(query) {
                if let w = query.who.first, let full = fullName(w) {
                    Image(systemName: "person.crop.circle").foregroundStyle(UIInk.muted)
                    Text(full).font(NativeFont.text(12, .medium)).foregroundStyle(UIInk.ink)
                    if query.kind != nil || query.app != nil || query.day != nil { Text(line).foregroundStyle(UIInk.muted) }
                } else {
                    Text(line).foregroundStyle(UIInk.muted)
                }
                Text("· \(total)").foregroundStyle(UIInk.faint)
                Spacer()
                if let w = query.who.first {
                    Button("Open in Names") { NamesStore.shared.query = w; m.show(.names) }.buttonStyle(.link)
                } else if query.kind == "link" || query.kind == "file" {
                    Button("Links & Files page") { m.show(.links) }.buttonStyle(.link)
                } else if query.kind == "picture" {
                    Button("Live screen inspector") { m.show(.screen) }.buttonStyle(.link)
                }
            } else {
                Text(m.stream.ranked ? "Best first · \(total)" : "\(total)").foregroundStyle(UIInk.faint)
                Spacer()
            }
        }
        .font(NativeFont.text(12)).padding(.horizontal, 4).frame(height: 20)
    }
    /// The whole name behind "@mila": the first tag in the rows with a word starting so.
    func fullName(_ w: String) -> String? {
        for r in m.rows.prefix(3000) {
            for t in r.tags where ["person", "chat", "project"].contains(t.kind) {
                if t.name.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(w) }) { return t.name }
            }
        }
        return nil
    }
}

struct StreamDayHead: View {
    let title: String
    let count: Int
    var fold: (() -> Void)? = nil      // a past day the user opened: fold it back into its summary line
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(NativeFont.text(12, .semibold)).foregroundStyle(UIInk.muted)
            Text("\(count)").font(NativeFont.num(11)).foregroundStyle(UIInk.faint)
            Spacer()
            if let fold {
                Button(action: fold) { Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(UIInk.faint).help("Fold this day into its summary")
            }
        }
        .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 6)
        .background(UIInk.paper)
    }
}

// MARK: one row

/// One item: one mark (its kind, or the picture itself), text, app, time. A click opens it in place; ⌘-click and
/// ⇧-click pick rows for Combine.
struct StreamRow: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    let open: Bool
    let chosen: Bool
    let picked: Bool
    let dated: Bool
    var density = 1                 // 0 compact, 1 rows, 2 detailed (StreamZoomRules)
    @ObservedObject var st: StreamState
    @State private var hover = false
    @State private var thumb: NSImage?
    static let height: CGFloat = 34
    var rowHeight: CGFloat { density == 0 && !open ? 26 : Self.height }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                mark.frame(width: 30, height: 20).scaleEffect(density == 0 && !open ? 0.8 : 1)
                Text(open ? title : oneLine).font(NativeFont.text(density == 0 && !open ? 13 : 14, open ? .semibold : .regular)).foregroundStyle(UIInk.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 12)
                if it.change != nil, !open { Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(UIInk.faint).help("Changed by you; the original is kept") }
                if it.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(UIInk.faint).help("Pinned") }
                if let len = length { Text(len).font(NativeFont.num(12)).foregroundStyle(UIInk.faint) }
                HStack(spacing: 4) {
                    if let i = AppIcons.icon(it.app) { Image(nsImage: i).resizable().frame(width: 14, height: 14) }
                    Text(it.app).font(NativeFont.text(12)).foregroundStyle(UIInk.faint).lineLimit(1)
                }.frame(maxWidth: 120, alignment: .trailing)
                Text(time).font(NativeFont.num(12)).foregroundStyle(UIInk.faint).frame(width: dated ? 84 : 38, alignment: .trailing)
            }
            .frame(height: rowHeight)
            if density == 2, !open, let more = detail {
                Text(more).font(NativeFont.text(12)).foregroundStyle(UIInk.muted).lineLimit(2).lineSpacing(2)
                    .padding(.leading, 40).padding(.trailing, 8).padding(.bottom, 8).padding(.top, -4)
            }
            if open { StreamOpen(it: it, st: st).padding(.leading, 40).padding(.bottom, 12).padding(.top, 2) }
        }
        .padding(.horizontal, 10)
        // Rebuild B: the open line lifts out of the stream as a white card with the float shadow
        .background {
            RoundedRectangle(cornerRadius: open ? 12 : 8)
                .fill(open ? Color(nsColor: Native.lift) : picked ? UIInk.blue.opacity(0.10) : chosen ? UIInk.pick : hover ? UIInk.hover : .clear)
                .shadow(color: .black.opacity(open ? (Native.dark ? 0.4 : 0.10) : 0), radius: 14, y: 5)
        }
        .overlay {
            if open { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: Native.glassEdge), lineWidth: 0.5) }
            else if picked { RoundedRectangle(cornerRadius: 8).strokeBorder(UIInk.blue.opacity(0.5), lineWidth: 1) }
        }
        .padding(.vertical, open ? 6 : 0)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { click() }
        .contextMenu { RowMenu(it: it) }
        .accessibilityElement(children: open ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
    }
    func click() {
        let f = NSEvent.modifierFlags
        if f.contains(.command) { m.togglePick(it.id); m.nav.region = .list; return }
        if f.contains(.shift) { m.pickTo(it.id); m.nav.region = .list; return }
        if open { return }   // clicks inside an open row belong to its controls
        m.choose(it.id); m.nav.region = .list
        m.open = it.id
    }
    /// The row's one mark: a picture's thumbnail in place of the kind symbol, same size as the row. The thumbnail is
    /// made off the main thread (pictures round, 24 November 2026: the list was slow with every row decoding on draw);
    /// until it is there the row shows a quiet box of the same size.
    @ViewBuilder var mark: some View {
        if StreamRow.hasPicture(it) {
            Group {
                if let p = thumb { Image(nsImage: p).resizable().aspectRatio(contentMode: .fill) } else { UIInk.well }
            }
            .frame(width: 30, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(UIInk.line, lineWidth: 0.5) }
            .task(id: it.id) { thumb = await StreamRow.picture(it) }
        } else {
            Image(systemName: Native.symbolName(JournalMeta.glyph(it.kindId))).font(.system(size: 13))
                .foregroundStyle(Color(nsColor: Native.series(JournalMeta.series(it.kindId))))
        }
    }
    static func hasPicture(_ it: TapeItem) -> Bool {
        it.shot != nil || (it.entry.map { $0.clip == .image && !$0.picture.isEmpty } ?? false)
    }
    /// A picture or a shot's image, scaled down once and kept in their caches (TapeDraw.thumb, ShotJournal.thumb),
    /// read and decoded off the main thread.
    static func picture(_ it: TapeItem, large: Bool = false) async -> NSImage? {
        let px = large ? 1200 : 120
        let shot = it.shot?.id
        let url = it.entry.flatMap { $0.clip == .image && !$0.picture.isEmpty ? History.clipURL($0.picture) : nil }
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            if let shot { return ShotJournal.thumb(shot, px: px) }
            if let url { return TapeDraw.thumb(url, px: px) }
            return nil
        }.value
    }
    /// Detailed rows: two more lines of what it holds (a recording's points, the rest of a long text, a picture's text).
    var detail: String? {
        if let d = it.doc { let p = d.points.prefix(2).joined(separator: " · "); return p.isEmpty ? nil : p }
        guard let e = it.entry else { return nil }
        let body = e.clip == .image ? e.ocr : it.current
        let flat = TapeItem.flat(body)
        let head = oneLine
        // what the line already says is left out (a chat export's header before it too)
        var rest = flat.range(of: head).map { String(flat[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? flat
        if e.clip == .image { rest = flat }
        guard rest.count >= 12, rest != head else { return nil }
        return String(rest.prefix(400))
    }
    var oneLine: String {
        let s = it.doc?.title ?? (it.shown.isEmpty ? it.current : it.shown)
        return s.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
    var title: String {
        if let d = it.doc { return d.title }
        if let t = it.entry?.clipTitle, !t.isEmpty { return t }
        return it.noun
    }
    var time: String { (dated ? Self.dayTime : Self.clock).string(from: Date(timeIntervalSince1970: it.at)) }
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static let dayTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; return f }()
    var length: String? {
        let s = it.doc?.secs ?? it.entry?.secs ?? 0
        guard s >= 1 else { return nil }
        return PlayerRules.clock(s.rounded())
    }
}

/// The right-click menu: the same actions as the open row's buttons.
struct RowMenu: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    var body: some View {
        ForEach(Array(m.actions(it).enumerated()), id: \.offset) { _, a in
            Button(a.word + "  " + a.key) { m.choose(it.id); a.run() }
        }
        Divider()
        if it.doc == nil { Button((it.pinned ? "Unpin" : "Pin") + "  ⌘P") { m.togglePin(it) } }
        if it.doc == nil { Button("Copy for agent  ⇧⌘A") { m.choose(it.id); m.copyForAgent() } }
        if it.doc == nil, it.quick != nil || it.ownDraft { Button("Delete  ⌘⌫", role: .destructive) { m.choose(it.id); m.delete() } }
    }
}

// MARK: an open row

/// An item opened in place: the whole text (or its editor), the player when it has audio, its tags, its actions.
struct StreamOpen: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    @ObservedObject var st: StreamState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = it.doc {
                RecordingBody(it: it, d: d, st: st)
            } else {
                if StreamRow.hasPicture(it) { LargePicture(it: it) }
                if m.editing == it.id {
                    TextEditorBox(text: Binding(get: { m.draft }, set: { m.draft = $0 }))
                    EditorButtons()
                } else if m.hasAudio(it) {
                    PlayerView(it: it, st: st)
                    VoiceLines(it: it, st: st)
                } else if it.entry?.clip != .image || !it.current.isEmpty {
                    Text(marked(m.showOriginal ? it.text : it.current)).font(NativeFont.text(14)).lineSpacing(3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if m.foundFocusId == it.id, let f = m.focusedThing(it) { FoundThing(it: it, f: f) }
                if it.change != nil, m.editing != it.id {
                    Text(m.showOriginal ? "The original, as it was kept" : "Changed by you · the original is kept (⌥⌘O shows it)")
                        .font(NativeFont.text(11)).foregroundStyle(UIInk.faint)
                }
            }
            if m.editing != it.id { TagChips(it: it) ; ActionRow(it: it) }
        }
    }
}

extension StreamOpen {
    /// The searched words marked in the open text (the answered query, not a key typed since).
    func marked(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        let q = m.searchSide.shown
        guard !q.isEmpty else { return a }
        for r in JournalSearch.ranges(q, in: s) {
            guard let rr = Range(r, in: s), let lo = AttributedString.Index(rr.lowerBound, within: a), let hi = AttributedString.Index(rr.upperBound, within: a) else { continue }
            a[lo..<hi].backgroundColor = UIInk.selected.opacity(0.3)
        }
        return a
    }
}

/// A thing found in the open text (⌥↓ ⌥↑, app/JournalFound.swift) and, after ↵, what to do with it.
struct FoundThing: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    let f: Found
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Glyph(JournalMeta.foundGlyph(f.kind.rawValue), size: 12).foregroundStyle(UIInk.muted)
                Text(FoundRules.one(f.display.isEmpty ? f.words : f.display, 48)).font(NativeFont.text(12, .medium))
                Spacer()
                if !m.foundFocus.menu { Text("↵ what to do · esc").font(NativeFont.text(11)).foregroundStyle(UIInk.faint) }
            }
            if m.foundFocus.menu {
                let acts = m.thingActions(it, f)
                ForEach(Array(acts.enumerated()), id: \.offset) { i, a in
                    HStack(spacing: 8) {
                        Text(a.key).font(NativeFont.mono(11)).foregroundStyle(UIInk.muted).frame(width: 24, alignment: .leading)
                        Text(a.name).font(NativeFont.text(13)).foregroundStyle(a.built ? UIInk.ink : UIInk.faint)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                    .background { if i == m.foundFocus.row { RoundedRectangle(cornerRadius: 6).fill(UIInk.soft) } }
                    .contentShape(Rectangle())
                    .onTapGesture { if a.built { m.foundFocus.menu = false; m.runThing(a, f, it) } }
                    .help(a.built ? a.name : a.name + " · not ready yet")
                }
            }
        }
        .padding(8)
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(UIInk.rule, lineWidth: 0.5) }
        .accessibilityLabel("What to do with " + f.kind.rawValue)
    }
}

/// A real multi-line field for an edit in place.
struct TextEditorBox: View {
    @Binding var text: String
    var minHeight: CGFloat = 90
    @FocusState private var focused: Bool
    /// Tall enough for the text (about 90 characters a line), at most 320 pt.
    var height: CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ($1.count + 89) / 90) }
        return min(320, max(minHeight, CGFloat(lines + 1) * 19 + 14))
    }
    var body: some View {
        TextEditor(text: $text)
            .font(NativeFont.text(14)).scrollContentBackground(.hidden)
            .padding(6).frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(UIInk.paper))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? UIInk.blue.opacity(0.6) : UIInk.line, lineWidth: focused ? 1 : 0.5) }
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .accessibilityLabel("Edit the text")
    }
}

/// Save and Cancel under an editor, with their keys.
struct EditorButtons: View {
    @EnvironmentObject var m: WindowModel
    var save = "Save"
    var body: some View {
        HStack(spacing: 8) {
            Button { m.saveEdit() } label: { KeyedLabel(word: save, key: "⌘↵") }.buttonStyle(.borderedProminent)
            Button { m.cancelEdit() } label: { KeyedLabel(word: "Cancel", key: "esc") }.buttonStyle(.bordered)
            Spacer()
            Text(m.editing == "new" ? "A new draft; the picked items stay as they are" : "The original is kept; ⌘Z undoes the save")
                .font(NativeFont.text(11)).foregroundStyle(UIInk.faint)
        }
        .controlSize(.regular)
    }
}

/// What it is related to: a click narrows the stream to it; right-click to hide or pin the tag.
struct TagChips: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    var body: some View {
        let tags = it.tags.filter { $0.kind != "app" && TagPrefs.shared.shows($0) }
        if !tags.isEmpty {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { t in
                    Button { m.openTag(t, item: it) } label: {
                        Label(t.name, systemImage: Native.symbolName(t.glyph)).font(NativeFont.text(12))
                    }
                    .buttonStyle(.plain).foregroundStyle(UIInk.muted)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(UIInk.soft))
                    .help("Everything related to \(t.name) · right-click to hide or pin")
                    .contextMenu {
                        Button("Everything related to \(t.name)") { m.openTag(t, item: it) }
                        Button("Pin this tag") { m.pinTag(t, true) }
                        Button("Hide this tag") { m.hideTag(t) }
                    }
                }
            }
        }
    }
}

/// The open row's actions: standard bordered buttons at normal size, each with its key; the main one prominent
/// (Insert for text, Play for audio, Open for a recording). Pin and Delete are labelled.
struct ActionRow: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    var body: some View {
        let acts = m.actions(it)
        let audio = m.hasAudio(it)
        let mainWord = audio ? "" : acts.first?.word ?? ""   // audio: Play (the player) is the main action
        let main = acts.first { $0.word == mainWord }
        let rest = acts.filter { $0.word != mainWord }
        let inline = rest.prefix(audio ? 3 : 2)
        let more = rest.filter { a in !inline.contains { $0.word == a.word } }
        HStack(spacing: 8) {
            if let main {
                Button { m.choose(it.id); main.run() } label: { KeyedLabel(word: main.word, key: main.key) }
                    .buttonStyle(.borderedProminent).help(main.tip)
            }
            ForEach(Array(inline.enumerated()), id: \.offset) { _, a in
                Button { m.choose(it.id); a.run() } label: { KeyedLabel(word: a.word, key: a.key) }
                    .buttonStyle(.bordered).help(a.tip)
            }
            if !more.isEmpty || it.doc == nil {
                SwiftUI.Menu {
                    ForEach(Array(more.enumerated()), id: \.offset) { _, a in Button(a.word + "  " + a.key) { m.choose(it.id); a.run() } }
                    if it.doc == nil, it.shot == nil { Button("Copy for agent  ⇧⌘A") { m.choose(it.id); m.copyForAgent() } }
                } label: { Text("More") }
                .menuStyle(.borderedButton).fixedSize().help("More actions")
            }
            Spacer(minLength: 8)
            if it.doc == nil {
                Button { m.togglePin(it) } label: { Label { KeyedLabel(word: it.pinned ? "Unpin" : "Pin", key: "⌘P") } icon: { Image(systemName: it.pinned ? "pin.slash" : "pin") } }
                    .buttonStyle(.bordered).help(it.pinned ? "Take it off the top of the Quick panel" : "Keep it on top of the Quick panel")
            }
            if it.doc == nil, it.quick != nil || it.ownDraft {
                Button(role: .destructive) { m.choose(it.id); m.delete() } label: { Label { KeyedLabel(word: "Delete", key: "⌘⌫") } icon: { Image(systemName: "trash") } }
                    .buttonStyle(.bordered).help("Delete; Undo in the notice for 8 s (⌘Z)")
            }
        }
        .controlSize(.regular).labelStyle(.titleAndIcon)
    }
}

// MARK: the player

/// Play or pause (space), a scrubber with elapsed and total, back and forward 10 s, speed.
struct PlayerView: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    @ObservedObject var st: StreamState
    @State private var dragAt: Double?
    var body: some View {
        let s = m.playState(it)
        let at = dragAt ?? s.at
        HStack(spacing: 8) {
            Button { m.choose(it.id); m.playPause(it) } label: {
                Label { KeyedLabel(word: s.playing ? "Pause" : "Play", key: "Space") } icon: { Image(systemName: s.playing ? "pause.fill" : "play.fill") }
            }
            .buttonStyle(.borderedProminent).labelStyle(.titleAndIcon)
            .help(s.playing ? "Pause (space)" : "Play (space)")
            Button { m.skip(it, by: -10) } label: { Image(systemName: "gobackward.10") }.buttonStyle(.bordered).help("Back 10 s")
            Text(PlayerRules.clock(at)).font(NativeFont.num(12)).foregroundStyle(UIInk.muted).frame(minWidth: 38, alignment: .trailing)
            Slider(value: Binding(get: { at }, set: { dragAt = $0 }), in: 0...max(s.total, 0.1)) { editing in
                if !editing, let t = dragAt { m.seek(it, to: t); dragAt = nil }
            }
            .controlSize(.small).accessibilityLabel("Position")
            Text(PlayerRules.clock(s.total)).font(NativeFont.num(12)).foregroundStyle(UIInk.faint).frame(minWidth: 38, alignment: .leading)
            Button { m.skip(it, by: 10) } label: { Image(systemName: "goforward.10") }.buttonStyle(.bordered).help("Forward 10 s")
            Button(PlayerRules.speedLabel(m.playbackRate)) { m.nextSpeed() }.buttonStyle(.bordered).help("Speed: 1×, 1.5×, 2×")
                .frame(minWidth: 44)
        }
        .controlSize(.regular)
    }
}

/// A voice note's text as lines: a click plays from that line (times guessed by length); the line playing is marked.
struct VoiceLines: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    @ObservedObject var st: StreamState
    var body: some View {
        let lines = PlayerRules.sentences(it.current)
        let s = m.playState(it)
        let starts = PlayerRules.guessedStarts(lines, total: s.total)
        let now = (s.playing || s.at > 0) ? PlayerRules.line(at: s.at, starts: starts.map { Optional($0) }) : nil
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l).font(NativeFont.text(14)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(now == i ? UIInk.blue.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { m.choose(it.id); m.seek(it, to: starts[i]); if !m.playState(it).playing { m.startPlayer(it, from: starts[i]) } }
                    .help("Play from here")
            }
        }
    }
}

// MARK: a recording opened in place

struct RecordingBody: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    let d: CallDoc
    @ObservedObject var st: StreamState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !d.people.isEmpty { Text(d.people.joined(separator: " · ")).font(NativeFont.text(12)).foregroundStyle(UIInk.muted) }
            if m.editing == it.id {
                TextField("Title", text: $st.docTitle).textFieldStyle(.roundedBorder).font(NativeFont.text(14, .medium))
                Text("Points, one per line").font(NativeFont.text(11)).foregroundStyle(UIInk.faint)
                TextEditorBox(text: $st.docPoints, minHeight: 110)
                EditorButtons()
            } else if !d.points.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(d.points.enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•").foregroundStyle(UIInk.faint); Text(p).fixedSize(horizontal: false, vertical: true) }
                    }
                }.font(NativeFont.text(14))
            }
            if d.hasAudio { PlayerView(it: it, st: st) }
            if !d.turns.isEmpty, m.editing != it.id { TranscriptLines(it: it, d: d, st: st) }
        }
    }
}

/// A recording's lines: a click plays from there, the line playing is marked, the pencil edits one line in place.
struct TranscriptLines: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    let d: CallDoc
    @ObservedObject var st: StreamState
    @State private var all = false
    var body: some View {
        let s = m.playState(it)
        let starts = d.turns.map(\.start)
        let now = (s.playing || s.at > 0) ? PlayerRules.line(at: s.at, starts: starts) : nil
        let shown = all ? d.turns.count : min(d.turns.count, max(8, (now ?? 0) + 4))
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<shown, id: \.self) { i in TurnLine(it: it, d: d, i: i, now: now == i, st: st) }
            if shown < d.turns.count {
                Button("All \(d.turns.count) lines") { all = true }.buttonStyle(.link).font(NativeFont.text(12)).padding(.top, 4)
            }
        }
    }
}

struct TurnLine: View {
    @EnvironmentObject var m: WindowModel
    let it: TapeItem
    let d: CallDoc
    let i: Int
    let now: Bool
    @ObservedObject var st: StreamState
    @State private var hover = false
    var body: some View {
        let t = d.turns[i]
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !t.who.isEmpty {
                SwiftUI.Menu {
                    Section("Who is \(d.speakers[t.who] ?? t.who)?") {
                        ForEach(m.suggestions(d), id: \.self) { p in Button(p) { m.setSpeaker(d, t.who, p); m.loadDocs() } }
                    }
                } label: {
                    Text(d.speakers[t.who] ?? t.who).font(NativeFont.text(12, .medium)).foregroundStyle(UIInk.muted)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 70, alignment: .leading)
                .help("Who said it: pick the person")
            }
            if let e = st.lineEdit, e.doc == it.id, e.index == i {
                TextField("Line", text: Binding(get: { st.lineEdit?.text ?? "" }, set: { st.lineEdit?.text = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(NativeFont.text(14))
                    .onSubmit { m.saveLine() }
                Button { m.saveLine() } label: { KeyedLabel(word: "Save", key: "↵") }.buttonStyle(.borderedProminent)
                Button { st.lineEdit = nil; m.nav.region = .list } label: { KeyedLabel(word: "Cancel", key: "esc") }.buttonStyle(.bordered)
            } else {
                Text(t.text).font(NativeFont.text(14)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { m.choose(it.id); let at = t.start ?? 0; m.startPlayer(it, from: at) }
                    .help(t.start == nil ? "This line has no time" : "Play from here")
                if let s = t.start { Text(PlayerRules.clock(s)).font(NativeFont.num(11)).foregroundStyle(UIInk.faint) }
                Button { st.lineEdit = .init(doc: it.id, index: i, text: t.text); m.nav.region = .editor } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).opacity(hover || now ? 1 : 0).help("Edit this line")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(now ? UIInk.blue.opacity(0.14) : .clear))
        .onHover { hover = $0 }
    }
}

// MARK: Combine and Go to

/// The combined draft, above the stream: an editor with Save (a new draft) and Cancel.
struct CombineCard: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var st: StreamState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "square.stack.3d.up").foregroundStyle(UIInk.muted)
                Text("Combined draft · \(m.combineSources.count) items, oldest first").font(NativeFont.text(13, .semibold))
                Spacer()
            }
            TextEditorBox(text: Binding(get: { m.draft }, set: { m.draft = $0 }), minHeight: 120)
            EditorButtons(save: "Save as draft")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(UIInk.card))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(UIInk.line, lineWidth: 0.5) }
    }
}

/// ⌘T: a date in words, a day in the stream, a kind, a person, an app.
struct GoToPalette: View {
    @EnvironmentObject var m: WindowModel
    @FocusState private var focused: Bool
    var body: some View {
        let list = m.paletteResults
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(UIInk.muted)
                TextField("Go to", text: Binding(get: { m.palette ?? "" }, set: { if m.palette != nil, m.palette != $0 { m.palette = $0; m.paletteIndex = 0 } }),
                          prompt: Text("Last Tuesday · 12 March · calls · a name · an app").foregroundColor(UIInk.faint))
                    .textFieldStyle(.plain).font(NativeFont.text(15)).focused($focused)
                    .onSubmit { m.paletteGo() }
                KeyChip("esc")
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.prefix(12).enumerated()), id: \.offset) { i, c in
                        Button { m.paletteGo(c) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: Native.symbolName(c.glyph)).foregroundStyle(UIInk.muted).frame(width: 18)
                                Text(c.title).lineLimit(1)
                                Spacer()
                                Text(c.kind).font(NativeFont.text(11)).foregroundStyle(UIInk.faint)
                            }
                            .padding(.horizontal, 14).frame(height: 30).contentShape(Rectangle())
                            .background(i == m.paletteIndex ? UIInk.pick : .clear)
                        }.buttonStyle(.plain)
                    }
                    if list.isEmpty { Text("Nothing to go to").foregroundStyle(UIInk.faint).padding(14) }
                }
            }.frame(height: CGFloat(max(1, min(12, list.count))) * 30)
        }
        .frame(width: 460)
        .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(UIInk.line, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct StreamEmpty: View {
    let query: StreamRules.Query
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(UIInk.faint)
            Text(query.isEmpty ? "Nothing kept yet" : "Nothing matches").font(NativeFont.text(14, .medium)).foregroundStyle(UIInk.muted)
            Text("Words, @someone, links, calls, screens, in:app, today").font(NativeFont.text(12)).foregroundStyle(UIInk.faint)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

/// An open row's picture, up to 280 pt tall, decoded off the main thread; a quiet box of the same height until then.
struct LargePicture: View {
    let it: TapeItem
    @State private var img: NSImage?
    var body: some View {
        Group {
            if let p = img {
                Image(nsImage: p).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: 280, alignment: .leading)
            } else {
                UIInk.well.frame(maxWidth: .infinity).frame(height: 160)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6)).overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(UIInk.line, lineWidth: 0.5) }
        .task(id: it.id) { img = await StreamRow.picture(it, large: true) }
    }
}
