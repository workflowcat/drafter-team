import SwiftUI

/// Network callbacks run on the main queue. Tokens discard stale reads and callbacks after dismissal.
private final class TodayPromisesStore: ObservableObject {
    @Published var rows: [TodayPromise] = []
    @Published var notice = ""
    @Published var pending: Set<String> = []
    private var active = false
    private var preview = false
    private var generation = UUID()
    private var lifetime = UUID()
    private var loading = false

    func start(preview: Bool) { self.preview = preview; active = true; refresh() }
    func stop() { active = false; lifetime = UUID(); generation = UUID(); loading = false; pending = [] }
    func refresh() {
        guard active, !preview, !loading, pending.isEmpty else { return }
        generation = UUID(); let token = generation
        loading = true
        Engine.shared.get("/promises") { [weak self] response in
            guard let self, self.active, self.generation == token else { return }
            self.loading = false
            guard let rows = response?["promises"] as? [[String: Any]] else {
                self.notice = "Promises unavailable"; return
            }
            self.rows = TodayThreadRules.parsePromises(rows); self.notice = ""
        }
    }
    func resolve(_ id: String, drop: Bool) {
        guard active, !pending.contains(id) else { return }
        if preview { rows.removeAll { $0.id == id }; return }
        generation = UUID(); let token = generation, life = lifetime
        loading = false; pending.insert(id)
        Engine.shared.post(drop ? "/promises/drop" : "/promises/done", ["id": id]) { [weak self] response in
            guard let self, self.active, self.lifetime == life else { return }
            self.pending.remove(id)
            if response?["ok"] as? Bool == true {
                self.rows.removeAll { $0.id == id }
                if self.generation == token { self.notice = "" }
            } else { self.notice = "Could not update promise" }
            if self.pending.isEmpty { self.refresh() }
        }
    }
}

struct TodayThreadView: View {
    @EnvironmentObject var m: WindowModel
    let items: [TodayItem]
    let topics: [TodayTopic]
    let openTopic: (TodayTopic) -> Void
    @AppStorage("drafter.todayThread.collapsed") private var collapsed = false
    @StateObject private var promises = TodayPromisesStore()
    @State private var tidy = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { clock in
            let digest = TodayThreadRules.summarize(items: items, topics: topics, promises: promises.rows, now: clock.date)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button { collapsed.toggle() } label: {
                        HStack(spacing: 6) {
                            Glyph(collapsed ? "chevron-right" : "chevron-down", size: 12)
                            Text(digest.headline).font(NativeFont.text(12, .medium)).lineLimit(1)
                        }.frame(height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(collapsed ? "Expand today's thread" : "Collapse today's thread")
                        .accessibilityLabel("Today's thread, " + digest.headline)
                        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                    if digest.overdueCount > 0 {
                        Text("\(digest.overdueCount) past due").font(NativeFont.text(11)).foregroundStyle(UIInk.muted)
                            .padding(.horizontal, 6).background(Capsule().fill(UIInk.soft))
                    }
                    Spacer(minLength: 0)
                    Button("Tidy") { tidy = true }.controlSize(.small)
                }
                if !collapsed {
                    VStack(alignment: .leading, spacing: 8) {
                        if !digest.topics.isEmpty {
                            FlowRow(spacing: 6) {
                                ForEach(digest.topics) { topic in
                                    Button { openTopic(topic) } label: {
                                        Text(topic.title).font(NativeFont.text(12)).lineLimit(1)
                                            .padding(.horizontal, 8).frame(height: 28)
                                            .background(Capsule().fill(UIInk.soft))
                                    }.buttonStyle(.plain).help("Open topic in Journal")
                                }
                            }
                        }
                        let activity = [(digest.voiceTakes, "voice notes"), (digest.drafts, "drafts"), (digest.clips, "clips")]
                            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
                        if !activity.isEmpty { Text(activity).font(NativeFont.text(11)).foregroundStyle(UIInk.muted) }
                        if !digest.promises.isEmpty {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(digest.promises) { row in promise(row) }
                                }
                            }.frame(maxHeight: min(160, CGFloat(digest.promises.count) * 42))
                        }
                        if !promises.notice.isEmpty {
                            HStack {
                                Text(promises.notice).font(NativeFont.text(11)).foregroundStyle(UIInk.muted)
                                Button("Retry") { promises.refresh() }.controlSize(.small)
                            }
                        }
                    }.padding(.bottom, 10)
                }
            }.padding(.horizontal, 12)
                .background(UIInk.well)
                .overlay(alignment: .bottom) { Rectangle().fill(UIInk.line).frame(height: 0.5) }
        }
        .onAppear { promises.start(preview: m.preview) }
        .onDisappear { promises.stop() }
        .onReceive(timer) { _ in promises.refresh() }
        .sheet(isPresented: $tidy) { TopicTidyView().environmentObject(m) }
    }
    private func promise(_ row: TodayPromise) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.what.isEmpty ? "Follow up" : row.what).font(NativeFont.text(12)).lineLimit(2)
                let detail = [row.person, row.app, row.due.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(NativeFont.text(11)).foregroundStyle(UIInk.muted).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Done") { promises.resolve(row.id, drop: false) }.help("Mark promise done")
            Button("Drop") { promises.resolve(row.id, drop: true) }.help("Remove this promise")
        }.controlSize(.small).disabled(promises.pending.contains(row.id))
    }
}
