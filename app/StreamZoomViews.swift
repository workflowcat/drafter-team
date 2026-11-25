// The stream's semantic zoom views (zoom round, 24 November 2026; split out of Stream.swift on 25 November 2026):
// the foot's zoom control, the cards of weeks, days and sessions, and a week's bars. Rules: app/StreamZoomRules.swift.
import SwiftUI

// MARK: semantic zoom (zoom round, 24 November 2026)

/// The foot's zoom: − the level +, the same steps as ⌘− ⌘+ and a pinch.
struct ZoomControl: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var st: StreamState
    var body: some View {
        HStack(spacing: 2) {
            Button { m.zoom(by: -1) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless).disabled(st.zoom == .weeks).help("Zoom out: sessions, days, weeks (⌘−)")
            SwiftUI.Menu {
                ForEach(StreamZoomRules.Level.allCases, id: \.rawValue) { l in
                    Button { m.zoom(by: l.rawValue - st.zoom.rawValue) } label: { Text(l.name) + Text(l == st.zoom ? "  ✓" : "") }
                }
            } label: { Text(st.zoom.name).font(NativeFont.text(12, .medium)).foregroundStyle(UIInk.muted) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("How close to look (⌘0: rows)")
            Button { m.zoom(by: 1) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless).disabled(st.zoom == .detailed).help("Zoom in: rows, then more of each row (⌘+)")
        }
        .foregroundStyle(UIInk.muted)
    }
}

/// Zoomed out: one quiet line per week, day or session, newest first; days sit under their week, sessions under their
/// day. Farther is calmer: a week is its name, its days as small bars and a count; a day adds its main thing; a session
/// is its time and its main thing. The rows (⌘0) and Detailed carry the rest.
struct StreamCards: View {
    @EnvironmentObject var m: WindowModel
    @ObservedObject var st: StreamState
    var body: some View {
        let cards = m.zoomCards
        let peak = max(1, cards.flatMap(\.perDay).max() ?? 1)
        GeometryReader { g in
            let w = min(680, max(320, g.size.width - 48))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if st.zoom == .weeks {
                            ForEach(cards, id: \.key) { c in ZoomLine(c: c, level: st.zoom, peak: peak).id(c.key) }
                        } else {
                            ForEach(m.zoomGroups(cards, level: st.zoom), id: \.key) { gr in
                                Section {
                                    ForEach(gr.cards, id: \.key) { c in ZoomLine(c: c, level: st.zoom, peak: peak).id(c.key) }
                                } header: { StreamDayHead(title: gr.title, count: gr.cards.reduce(0) { $0 + $1.ids.count }) }
                            }
                        }
                        if cards.isEmpty { Text("Nothing here").font(NativeFont.text(13)).foregroundStyle(UIInk.faint).padding(.top, 40).frame(maxWidth: .infinity) }
                    }
                    .frame(width: w).padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: st.zoomAnchor, initial: true) { _, k in if let k { withAnimation(nil) { proxy.scrollTo(k, anchor: .center) } } }
            }
        }
    }
}

/// One line of time, as quiet as a row: a click or ↵ steps one level in.
struct ZoomLine: View {
    @EnvironmentObject var m: WindowModel
    let c: StreamZoomRules.Card
    let level: StreamZoomRules.Level   // a value, so a change elsewhere in the stream's state does not redraw every line
    let peak: Int
    @State private var hover = false
    var chosen: Bool { m.chosen.map { c.ids.contains($0) } ?? false }
    var body: some View {
        HStack(spacing: 12) {
            switch level {
            case .weeks:
                Text(StreamZoomRules.weekTitle(c, now: m.now)).font(NativeFont.text(14, .medium)).foregroundStyle(UIInk.ink)
                    .frame(width: 140, alignment: .leading)
                WeekBars(perDay: c.perDay, peak: peak)
                Spacer(minLength: 8)
            case .days:
                Text(StreamRules.dayTitle(Date(timeIntervalSince1970: c.end), now: Date(timeIntervalSince1970: m.now)))
                    .font(NativeFont.text(14, .medium)).foregroundStyle(UIInk.ink).lineLimit(1).frame(width: 190, alignment: .leading)
                Text(c.lines.first ?? "").font(NativeFont.text(13)).foregroundStyle(UIInk.muted).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                icons
            default:
                Text(StreamZoomRules.span(c)).font(NativeFont.num(12.5)).foregroundStyle(UIInk.muted).frame(width: 96, alignment: .leading)
                Text(c.lines.first ?? "").font(NativeFont.text(14)).foregroundStyle(UIInk.ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                icons
            }
            Text("\(c.ids.count)").font(NativeFont.num(12)).foregroundStyle(UIInk.faint).frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8).fill(chosen ? UIInk.pick : hover ? UIInk.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { m.zoomInto(c) }
        .help(StreamZoomRules.countLine(c) + (StreamZoomRules.duration(c.secs).isEmpty ? "" : " · " + StreamZoomRules.duration(c.secs) + " spoken"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Zoom in")
    }
    /// Where it happened: up to three app icons, no names.
    var icons: some View {
        HStack(spacing: 4) {
            ForEach(c.apps.prefix(3), id: \.self) { a in
                if let i = AppIcons.icon(a) { Image(nsImage: i).resizable().frame(width: 14, height: 14).help(a) }
            }
        }
    }
}

/// A week's seven days, Monday first, as small bars on one scale for every week.
struct WeekBars: View {
    let perDay: [Int]
    let peak: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(perDay.enumerated()), id: \.offset) { _, n in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(n == 0 ? UIInk.line : UIInk.muted.opacity(0.55))
                    .frame(width: 9, height: n == 0 ? 2 : max(4, 18 * (CGFloat(n) / CGFloat(peak)).squareRoot()))   // root scale: one busy day leaves the rest readable
            }
        }
        .frame(height: 18, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
