// Tidy Names sheet: review and merge duplicate entries, or bulk-hide unused / noisy clutter.
// Suggestions are computed lazily when the sheet opens (never on every NamesView body rebuild).
// Every merge and bulk hide uses NamesStore's undoable edit stack.
import SwiftUI

struct NamesTidyView: View {
    @ObservedObject var s = NamesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var query = ""
    @State private var duplicates: [NameRules.DuplicateSuggestion] = []
    @State private var clutter: [NameRules.ClutterSuggestion] = []
    @State private var swapped: Set<String> = []
    @State private var selectedClutter: Set<String> = []

    private var byId: [String: NameRules.Entry] {
        Dictionary(s.entries.compactMap { e in
            let id = NameRules.str(e, "id")
            return id.isEmpty ? nil : (id, e)
        }, uniquingKeysWith: { a, _ in a })
    }

    private var filteredDuplicates: [NameRules.DuplicateSuggestion] {
        let map = byId
        let q = NameRules.fold(query.trimmingCharacters(in: .whitespaces))
        return duplicates.filter { sug in
            guard let a = map[sug.sourceId], let b = map[sug.targetId] else { return false }
            if q.isEmpty { return true }
            return NameRules.matches(a, q) || NameRules.matches(b, q) || sug.reason.localizedCaseInsensitiveContains(q)
        }
    }

    private var highConfidencePairs: [(source: String, target: String)] {
        filteredDuplicates.filter { $0.score >= 95 }.map { pairDirection($0) }
    }

    private var filteredClutter: [NameRules.ClutterSuggestion] {
        let map = byId
        let q = NameRules.fold(query.trimmingCharacters(in: .whitespaces))
        return clutter.filter { sug in
            guard let e = map[sug.id] else { return false }
            if q.isEmpty { return true }
            return NameRules.matches(e, q) || sug.reason.localizedCaseInsensitiveContains(q)
        }
    }

    private func pairDirection(_ sug: NameRules.DuplicateSuggestion) -> (source: String, target: String) {
        swapped.contains(sug.id) ? (sug.targetId, sug.sourceId) : (sug.sourceId, sug.targetId)
    }

    private func refresh() {
        duplicates = NameRules.findDuplicates(s.entries)
        clutter = NameRules.findClutter(s.entries)
        let validIds = Set(clutter.map(\.id))
        selectedClutter.formIntersection(validIds)
        let validPairs = Set(duplicates.map(\.id))
        swapped.formIntersection(validPairs)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Tidy Names", subtitle: "Merge duplicate entries and hide unused clutter") {
                PagePillButton(title: "Close", glyph: "close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, PageLayout.margin)

            HStack(spacing: 12) {
                SwiftUI.Picker("Tidy names tab", selection: $tab) {
                    Text("Duplicates (\(duplicates.count))").tag(0)
                    Text("Clutter (\(clutter.count))").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().font(NativeFont.text(12))
                PageSearchField(placeholder: "Filter", text: $query).frame(width: 190)
            }
            .padding(16)

            Group {
                if tab == 0 { duplicatesPane } else { clutterPane }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, PageLayout.margin)

            Divider().overlay(UIInk.line)
            HStack(spacing: 12) {
                Text(s.notice.isEmpty ? "Changes save to names-edits.json and survive rebuilds." : s.notice)
                    .font(NativeFont.text(12)).foregroundStyle(UIInk.muted).lineLimit(1)
                Spacer(minLength: 0)
                PagePillButton(title: "Undo", glyph: "arrow-back-up", enabled: s.canUndo) { s.undo() }
                    .keyboardShortcut("z", modifiers: .command)
            }
            .padding(16)
        }
        .frame(width: 860, height: 620)
        .background(UIInk.paper)
        .foregroundStyle(UIInk.ink)
        .onAppear { refresh() }
        .onChange(of: s.revision) { _, _ in refresh() }
        .onChange(of: tab) { _, _ in query = "" }
    }

    private var duplicatesPane: some View {
        let map = byId
        let items = filteredDuplicates
        let hi = highConfidencePairs
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(items.count) duplicate \(items.count == 1 ? "pair" : "pairs")")
                    .font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                Spacer()
                PagePillButton(
                    title: hi.isEmpty ? "Merge all high-confidence" : "Merge all high-confidence (\(hi.count))",
                    glyph: "check",
                    primary: true,
                    enabled: !hi.isEmpty
                ) {
                    s.mergeAll(hi)
                }
                .help("Merge all pairs matched by the same email or phone in one undoable step")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty {
                        empty("No duplicate names found", glyph: "check")
                    }
                    ForEach(items) { sug in
                        let dir = pairDirection(sug)
                        if let src = map[dir.source], let dst = map[dir.target] {
                            duplicateCard(sug: sug, source: src, target: dst)
                        }
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(.bottom, 16)
    }

    private func duplicateCard(sug: NameRules.DuplicateSuggestion, source: NameRules.Entry, target: NameRules.Entry) -> some View {
        let dir = pairDirection(sug)
        return PageCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(sug.reason)
                        .font(NativeFont.mono(10.5, .medium))
                        .foregroundStyle(sug.score >= 95 ? UIInk.blue : UIInk.muted)
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Capsule().fill(sug.score >= 95 ? UIInk.soft : UIInk.well))
                        .overlay { Capsule().strokeBorder(UIInk.line, lineWidth: 0.5) }
                    Spacer()
                    PagePillButton(title: "Swap", glyph: "arrows-left-right") {
                        if swapped.contains(sug.id) { swapped.remove(sug.id) } else { swapped.insert(sug.id) }
                    }
                    .help("Flip which entry is kept")
                    PagePillButton(title: "Merge", glyph: "check", primary: true) {
                        s.merge(dir.source, into: dir.target)
                    }
                    .help("Merge left entry into right entry (reversible with ⌘Z)")
                }

                HStack(alignment: .top, spacing: 12) {
                    entrySide(source, role: "Merges away", muted: true)
                    Glyph("arrow-up-right", size: 14)
                        .foregroundStyle(UIInk.muted)
                        .padding(.top, 16)
                    entrySide(target, role: "Keeps", muted: false)
                }
            }
        }
    }

    private func entrySide(_ e: NameRules.Entry, role: String, muted: Bool) -> some View {
        let kind = NameRules.str(e, "kind")
        let uk = NameRules.str(e, "uk"), latin = NameRules.str(e, "latin")
        let phone = NameRules.list(e, "phones").first
        let mail = NameRules.list(e, "emails").first
        let lines = NameRules.entryLines(e), chats = NameRules.entryChats(e)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(role.uppercased()).font(NativeFont.mono(9.5, .medium)).foregroundStyle(muted ? UIInk.faint : UIInk.blue)
                Spacer()
                HStack(spacing: 4) {
                    Glyph(NameRules.glyph(kind), size: 11)
                    Text(NameRules.kindTitle(kind)).font(NativeFont.text(11))
                }.foregroundStyle(UIInk.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(NameRules.display(e))
                    .font(NativeFont.text(13.5, .medium))
                    .foregroundStyle(muted ? UIInk.muted : UIInk.ink)
                    .lineLimit(1)
                if !uk.isEmpty, !latin.isEmpty {
                    Text(latin).font(NativeFont.text(12)).foregroundStyle(UIInk.faint).lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                Text("\(lines) lines · \(chats) chats").font(NativeFont.mono(10.5)).foregroundStyle(UIInk.muted)
                if let phone {
                    HStack(spacing: 3) { Glyph("phone", size: 10); Text(phone).font(NativeFont.mono(10.5)).lineLimit(1) }
                        .foregroundStyle(UIInk.muted)
                }
                if let mail {
                    HStack(spacing: 3) { Glyph("mail", size: 10); Text(mail).font(NativeFont.mono(10.5)).truncationMode(.middle).lineLimit(1) }
                        .foregroundStyle(UIInk.muted)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(muted ? UIInk.well : UIInk.soft))
        .overlay { RoundedRectangle(cornerRadius: Native.corner(2)).strokeBorder(UIInk.line, lineWidth: 0.5) }
    }

    private var clutterPane: some View {
        let map = byId
        let items = filteredClutter
        let reasons = ["Noise / fragment", "Unused (0 mentions)"]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PagePillButton(title: "Select all", glyph: "check", enabled: !items.isEmpty) {
                    selectedClutter.formUnion(items.map(\.id))
                }
                PagePillButton(title: "Clear selection", enabled: !selectedClutter.isEmpty) {
                    selectedClutter = []
                }
                Spacer()
                Text("\(selectedClutter.count) selected").font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                PagePillButton(title: "Hide selected", glyph: "blur", primary: true, enabled: !selectedClutter.isEmpty) {
                    let ids = items.map(\.id).filter { selectedClutter.contains($0) }
                    s.hideMany(ids)
                    selectedClutter = []
                }
                .help("Hide selected entries (reversible anytime via the Hidden tab or ⌘Z)")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if items.isEmpty {
                        empty("No clutter candidates", glyph: "check")
                    }
                    ForEach(reasons, id: \.self) { reason in
                        let group = items.filter { $0.reason == reason }
                        if !group.isEmpty {
                            PageSectionHead(title: "\(reason) (\(group.count))", glyph: reason.hasPrefix("Noise") ? "filter" : "blur")
                            ForEach(group) { sug in
                                if let e = map[sug.id] {
                                    clutterRow(sug: sug, entry: e)
                                }
                            }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(.bottom, 16)
    }

    private func clutterRow(sug: NameRules.ClutterSuggestion, entry e: NameRules.Entry) -> some View {
        let kind = NameRules.str(e, "kind")
        let uk = NameRules.str(e, "uk"), latin = NameRules.str(e, "latin")
        let sources = NameRules.list(e, "sources").joined(separator: ", ")
        return Toggle(isOn: Binding(
            get: { selectedClutter.contains(sug.id) },
            set: { on in if on { selectedClutter.insert(sug.id) } else { selectedClutter.remove(sug.id) } }
        )) {
            HStack(spacing: 10) {
                Glyph(NameRules.glyph(kind), size: 14).foregroundStyle(UIInk.muted).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(NameRules.display(e).isEmpty ? "(empty)" : NameRules.display(e))
                            .font(NativeFont.text(13, .medium)).foregroundStyle(UIInk.ink).lineLimit(1)
                        if !uk.isEmpty, !latin.isEmpty {
                            Text(latin).font(NativeFont.text(12)).foregroundStyle(UIInk.faint).lineLimit(1)
                        }
                    }
                    if !sources.isEmpty {
                        Text(sources).font(NativeFont.mono(10.5)).foregroundStyle(UIInk.faint).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(NameRules.kindTitle(kind)).font(NativeFont.mono(10.5)).foregroundStyle(UIInk.muted)
                Text("\(NameRules.entryLines(e)) lines").font(NativeFont.mono(10.5)).foregroundStyle(UIInk.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 4)
    }

    private func empty(_ title: String, glyph: String) -> some View {
        HStack(spacing: 8) {
            Glyph(glyph, size: 16)
            Text(title).font(NativeFont.text(13))
        }
        .foregroundStyle(UIInk.muted)
        .padding(.vertical, 24)
    }
}
