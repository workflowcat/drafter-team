// The stream's topic views (topics round, 24 November 2026; split out of Stream.swift on 25 November 2026): a folded
// past day's line, the list by topic and one topic's line. Rules: app/StreamGroupRules.swift.
import SwiftUI

// MARK: topics and folded days (topics round, 24 November 2026)

/// A past day as one line: its name, its biggest topics (else its first thing), where, how many. A click opens it.
struct DayFoldLine: View {
    @EnvironmentObject var m: WindowModel
    let day: StreamView.Day
    let topics: [String]
    @ObservedObject var st: StreamState
    let dayKey: String
    @State private var hover = false
    var apps: [String] {
        var n: [String: Int] = [:]
        for l in day.lines where l.item >= 0 && l.item < m.rows.count { let a = m.rows[l.item].app; if !a.isEmpty { n[a, default: 0] += 1 } }
        return n.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key)
    }
    var first: String {
        guard let l = day.lines.first, l.item >= 0, l.item < m.rows.count else { return "" }
        let it = m.rows[l.item]
        return StreamZoomRules.summary(it.doc?.title ?? (it.shown.isEmpty ? it.current : it.shown), max: 70)
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(day.title).font(NativeFont.text(13, .medium)).foregroundStyle(UIInk.ink).lineLimit(1).frame(width: 180, alignment: .leading)
            Text(StreamGroupRules.dayLine(topics: topics, first: first, count: day.lines.count))
                .font(NativeFont.text(13)).foregroundStyle(UIInk.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(apps, id: \.self) { a in if let i = AppIcons.icon(a) { Image(nsImage: i).resizable().frame(width: 14, height: 14).help(a) } }
            }
            Text("\(day.lines.count)").font(NativeFont.num(12)).foregroundStyle(UIInk.faint).frame(width: 30, alignment: .trailing)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(UIInk.faint)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? UIInk.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { st.openedDays.insert(dayKey) }
        .help("Open this day")
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
}

/// The list by topic: one line per topic (newest touched first), opening in place to its rows; loose ends last.
struct StreamTopics: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var st: StreamState
    var body: some View {
        let t = m.streamTopics
        GeometryReader { g in
            let w = min(680, max(320, g.size.width - 48))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(t.topics, id: \.id) { c in
                        TopicLine(key: c.id, title: c.title, sub: c.subtitle, ids: c.itemIds, latest: c.latestAt, earliest: c.earliestAt, st: st)
                    }
                    if !t.loose.isEmpty {
                        TopicLine(key: "loose", title: "Everything else", sub: "rows that share no topic", ids: t.loose,
                                  latest: m.row(id: t.loose[0])?.at ?? 0, earliest: m.row(id: t.loose.last!)?.at ?? 0, st: st, quiet: true)
                    }
                    if t.topics.isEmpty && t.loose.isEmpty {
                        Text("Nothing here").font(NativeFont.text(13)).foregroundStyle(UIInk.faint).padding(.top, 40).frame(maxWidth: .infinity)
                    }
                }
                .frame(width: w).padding(.top, 6).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct TopicLine: View {
    @EnvironmentObject var m: WindowModel
    let key: String
    let title: String
    let sub: String
    let ids: [String]
    let latest: Double
    let earliest: Double
    @ObservedObject var st: StreamState
    var quiet = false
    @State private var hover = false
    @State private var limit = 30
    var open: Bool { st.openTopics.contains(key) }
    var when: String {
        let now = Date(timeIntervalSince1970: m.now)
        let a = StreamRules.dayTitle(Date(timeIntervalSince1970: latest), now: now)
        let b = StreamRules.dayTitle(Date(timeIntervalSince1970: earliest), now: now)
        // a date in another year carries its year, and a range across years carries it at both ends
        let cal = Calendar.current, year = cal.component(.year, from: now)
        let spansYears = cal.component(.year, from: Date(timeIntervalSince1970: earliest)) != cal.component(.year, from: Date(timeIntervalSince1970: latest))
        func d(_ t: Double) -> String {
            let x = Date(timeIntervalSince1970: t)
            return StreamZoomRules.formatter(!spansYears && cal.component(.year, from: x) == year ? "d MMM" : "d MMM yyyy", cal: cal).string(from: x)
        }
        let near = a.count <= 12   // Today, Yesterday, a weekday
        if a == b { return near ? a : d(latest) }
        return d(earliest) + " – " + (near ? a : d(latest))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(UIInk.faint).frame(width: 12)
                Text(title).font(NativeFont.text(14, quiet ? .regular : .medium)).foregroundStyle(quiet ? UIInk.muted : UIInk.ink).lineLimit(1)
                Text(sub).font(NativeFont.text(12)).foregroundStyle(UIInk.faint).lineLimit(1)
                Spacer(minLength: 8)
                Text(when).font(NativeFont.text(12)).foregroundStyle(UIInk.faint).lineLimit(1)
                Text("\(ids.count)").font(NativeFont.num(12)).foregroundStyle(UIInk.faint).frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? UIInk.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { if open { st.openTopics.remove(key) } else { st.openTopics.insert(key) } }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ids.prefix(limit), id: \.self) { id in
                        if let it = m.row(id: id) {
                            StreamRow(it: it, open: m.open == it.id, chosen: m.chosen == it.id, picked: m.picked.count > 1 && m.picked.contains(it.id),
                                      dated: true, density: st.zoom.density, st: st).id(it.id)
                        }
                    }
                    if ids.count > limit {
                        Button("Show \(min(100, ids.count - limit)) more") { limit += 100 }.buttonStyle(.link).font(NativeFont.text(12)).padding(.vertical, 8).padding(.leading, 12)
                    }
                }
                .padding(.leading, 18).padding(.bottom, 10)
            }
        }
    }
}
