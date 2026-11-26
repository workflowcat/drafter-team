// Local suggestions, preview first. All archive actions use the journal sidecar and its Undo stack.
import SwiftUI

struct TopicTidyView: View {
    @EnvironmentObject var m: WindowModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var selectedTopic: String?
    @State private var selected: Set<String> = []
    @State private var archiveSources = true
    @State private var query = ""

    init(tab: Int = 0) { _tab = State(initialValue: tab) }

    private var snapshot: TopicTidySnapshot { m.topicTidy }
    private var topics: [TopicCluster] {
        snapshot.clusters.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }
    private var candidates: [TidyCandidate] {
        snapshot.candidates.filter { query.isEmpty || $0.preview.localizedCaseInsensitiveContains(query) }
    }
    private var topic: TopicCluster? { topics.first { $0.id == selectedTopic } ?? topics.first }
    private var archiveRows: [String: TapeItem] {
        Dictionary(snapshot.rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Tidy") {
                PagePillButton(title: "Close", glyph: "close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, PageLayout.margin)
            HStack(spacing: 12) {
                SwiftUI.Picker("Tidy view", selection: $tab) {
                    Text("Topics to consolidate").tag(0)
                    Text("Clean up clutter").tag(1)
                    Text("Archived (\(m.journalStore.hiddenCount))").tag(2)
                }.pickerStyle(.segmented).labelsHidden().font(NativeFont.text(12))
                PageSearchField(placeholder: "Find", text: $query).frame(width: 160)
            }
            .padding(16)
            Group {
                switch tab {
                case 0: topicPane
                case 1: clutterPane
                default: archivedPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, PageLayout.margin)
            Divider().overlay(UIInk.line)
            HStack(spacing: 12) {
                StatusText(live: m.live, font: NativeFont.text(12), color: UIInk.muted)
                Spacer(minLength: 0)
                if m.journalStore.hiddenCount > 0, tab != 2 {
                    PagePillButton(title: "\(m.journalStore.hiddenCount) archived · Restore", glyph: "arrow-back-up") { tab = 2; query = "" }
                }
                PagePillButton(title: "Undo", glyph: "arrow-back-up", enabled: !m.undos.isEmpty) { m.undoLast() }
                    .keyboardShortcut("z", modifiers: .command)
            }.padding(16)
        }
        .frame(width: 860, height: 620)
        .background(UIInk.paper)
        .foregroundStyle(UIInk.ink)
        .onChange(of: tab) { _, _ in query = "" }
        .onChange(of: m.tapeTick) { _, _ in selected.formIntersection(Set(snapshot.candidates.map(\.id))) }
        .onChange(of: m.rowsGen) { _, _ in selected.formIntersection(Set(snapshot.candidates.map(\.id))) }
    }

    private var topicPane: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if topics.isEmpty { empty("No topics to consolidate", glyph: "folder") }
                    ForEach(topics) { cluster in
                        Button { selectedTopic = cluster.id } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Glyph(cluster.primaryTag?.glyph ?? "folder", size: 14)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(cluster.title).font(NativeFont.text(13, .medium)).lineLimit(2)
                                    Text(cluster.subtitle).font(NativeFont.text(11)).foregroundStyle(UIInk.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(topic?.id == cluster.id ? UIInk.soft : .clear))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(topic?.id == cluster.id ? .isSelected : [])
                    }
                }
            }.frame(width: 260)
            if let topic {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        Text(m.topicPreview(topic)).font(NativeFont.text(14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
                    }
                    .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.card))
                    .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.line, lineWidth: 0.5) }
                    ShareNotesButton(brief: ShareBriefRules.formatShareBrief(title: topic.title,
                        summary: topicBody(topic), links: LinksRules.extractURLs(from: topicBody(topic))))
                    Toggle("Archive raw fragments after merge", isOn: $archiveSources)
                        .toggleStyle(.checkbox).font(NativeFont.text(12))
                        .help("Pinned notes stay visible. Archived fragments can be restored at any time.")
                    PagePillButton(title: "Merge into clean note", glyph: "file-edit", primary: true) {
                        m.consolidateTopic(topic, archiveSources: archiveSources)
                        selectedTopic = nil
                    }.keyboardShortcut(.return, modifiers: .command)
                }
            } else { Spacer() }
        }.padding(.bottom, 16)
    }

    private func topicBody(_ topic: TopicCluster) -> String {
        m.topicPreview(topic).components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var clutterPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PagePillButton(title: "Select all", glyph: "check", enabled: !candidates.isEmpty) {
                    selected.formUnion(candidates.map(\.id))
                }
                PagePillButton(title: "Clear selection", enabled: !selected.isEmpty) { selected = [] }
                Spacer()
                Text("\(selected.count) selected").font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                PagePillButton(title: "Archive selected", glyph: "folder", primary: true, enabled: !selected.isEmpty) {
                    m.archiveItems(selected.sorted()); selected = []
                }.keyboardShortcut(.return, modifiers: .command)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if candidates.isEmpty { empty("No clutter candidates", glyph: "check") }
                    ForEach(TidyReason.allCases, id: \.self) { reason in
                        let group = candidates.filter { $0.reason == reason }
                        if !group.isEmpty {
                            PageSectionHead(title: reason.title, glyph: reason == .duplicate ? "copy" : "text")
                            ForEach(group) { candidate in
                                Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { on in
                                    if on { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                                })) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Glyph(glyph(candidate.kind), size: 14)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(candidate.preview.isEmpty ? "Empty clip or draft" : candidate.preview)
                                                .font(NativeFont.text(13)).lineLimit(3)
                                            if let target = candidate.duplicateOf, let kept = archiveRows[target] {
                                                Text("Keeps: " + String(kept.current.prefix(180)))
                                                    .font(NativeFont.text(11)).foregroundStyle(UIInk.muted).lineLimit(2)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        stamp(candidate.at)
                                    }
                                }.toggleStyle(.checkbox).padding(.vertical, 4)
                            }
                        }
                    }
                }.padding(.trailing, 8)
            }
        }.padding(.bottom, 16)
    }

    private var archivedPane: some View {
        let rows = archiveRows
        let ids = snapshot.archivedIDs.filter { query.isEmpty || (rows[$0]?.current ?? $0).localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                let aa = rows[a]?.at ?? 0, bb = rows[b]?.at ?? 0
                return aa != bb ? aa > bb : a < b
            }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                PagePillButton(title: "Restore all", glyph: "arrow-back-up", enabled: !snapshot.archivedIDs.isEmpty) {
                    m.restoreArchived(snapshot.archivedIDs)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if ids.isEmpty { empty("No archived items", glyph: "folder") }
                    ForEach(ids, id: \.self) { id in
                        HStack(alignment: .top, spacing: 10) {
                            Glyph(rows[id]?.glyph ?? "file", size: 14)
                            if let row = rows[id] {
                                Text(row.current.isEmpty ? "Empty clip or draft" : String(row.current.prefix(240)))
                                    .font(NativeFont.text(13)).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                stamp(row.at)
                            } else {
                                Text("Earlier archived item").font(NativeFont.text(13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help("The original is outside the loaded journal window. Restore still removes its archive mark.")
                            }
                            PagePillButton(title: "Restore", glyph: "arrow-back-up") { m.restoreArchived([id]) }
                        }.padding(.vertical, 4)
                    }
                }.padding(.trailing, 8)
            }
        }.padding(.bottom, 16)
    }

    private func empty(_ title: String, glyph: String) -> some View {
        HStack(spacing: 8) {
            Glyph(glyph, size: 16)
            Text(title).font(NativeFont.text(13))
        }.foregroundStyle(UIInk.muted).padding(.vertical, 24)
    }
    private func stamp(_ at: Double) -> some View {
        Text(Date(timeIntervalSince1970: at), format: .dateTime.month(.abbreviated).day().hour().minute())
            .font(NativeFont.mono(10)).foregroundStyle(UIInk.muted)
    }
    private func glyph(_ kind: String) -> String {
        kind == "spoken" ? "waves" : kind == "copied" ? "copy" : "keys"
    }
}

/// Share notes only copies a plain brief to the clipboard (ShareBriefRules); nothing is written or sent.
private struct ShareNotesButton: View {
    @EnvironmentObject var m: WindowModel
    let brief: String
    @State private var notice = ""

    var body: some View {
        HStack(spacing: 8) {
            Button("Share notes") {
                if !m.preview { History.copy(brief) }
                notice = m.preview ? "Sample brief copied" : "Brief copied"
            }.disabled(brief.isEmpty).help("Copy a brief to share")
            if !notice.isEmpty { Text(notice).font(NativeFont.text(11)).foregroundStyle(UIInk.muted) }
        }.controlSize(.small)
    }
}
