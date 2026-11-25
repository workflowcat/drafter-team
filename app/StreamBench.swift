// The stream's numbers on his own rows (review 25 November 2026, Gemini Carbon: a real-data check before release would
// have caught the 1,365-row topic). `--stream-bench`: loads the journal as the window does, then prints counts, sizes and
// times only, never a word of his. `--stream-bench --sample` runs on the preview's made-up rows instead (for tests and
// agents, who never read data/). Draws the stream in a window off every screen to time each zoom step as he sees it.
// Never writes data/, never starts an engine or a hook; run it from any built copy.
import AppKit
import SwiftUI

enum StreamBench {
    static func run(sample: Bool) {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let model = WindowModel()
        let t0 = Date()
        if sample {
            model.preview = true
            let now = TapeBuild.cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!.timeIntervalSince1970
            model.now = now
            UIShots.sampleTape(model, now: now, days: 420, perDay: 12)
            model.rebuildTape()
        } else {
            model.reload()
        }
        // wait for the build and its tags (both off the main thread)
        let limit = Date().addingTimeInterval(90)
        while Date() < limit && (model.rows.isEmpty || model.lines.isEmpty || !model.journal.missing.isEmpty) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        out("load", ms(t0), "rows \(model.rows.count) lines \(model.lines.count)")
        guard !model.rows.isEmpty else { print("stream-bench: no rows"); exit(1) }

        // cards per level, cold (no cache)
        for lv in [StreamZoomRules.Level.sessions, .days, .weeks] {
            model.stream.cardCache = nil
            let saved = model.stream.zoom; model.stream.zoom = lv
            let t = Date(); let c = model.zoomCards
            out("cards " + lv.name.lowercased(), ms(t), "\(c.count) cards, biggest \(c.map(\.ids.count).max() ?? 0) rows")
            model.stream.zoom = saved
        }
        do {
            var t = Date()
            var items: [StreamZoomRules.Item] = []
            for l in model.lines where l.item >= 0 && l.item < model.rows.count {
                let it = model.rows[l.item]
                items.append(.init(id: it.id, at: it.at, kind: it.kindId, app: it.app, line: it.doc?.title ?? (it.shown.isEmpty ? it.current : it.shown)))
            }
            out("cards: rows to items", ms(t), "")
            items.sort { $0.at > $1.at }
            t = Date(); _ = StreamZoomRules.cards(items, level: .weeks); out("cards: rules weeks", ms(t), "")
            t = Date(); for it in items { _ = StreamZoomRules.summary(it.line) }; out("cards: summary all", ms(t), "")
        }
        // topics and the day lines (worked out off the main thread in the window; timed here as one pass each)
        let inputs = model.lines.compactMap { l in l.item >= 0 && l.item < model.rows.count ? model.streamTopicInput(model.rows[l.item]) : nil }
        var t = Date(); let tp = StreamGroupRules.topics(inputs)
        let sizes = tp.topics.map(\.itemIds.count).sorted(by: >)
        let loose = Double(tp.loose.count) / Double(max(1, inputs.count)) * 100
        let tagged = tp.topics.filter { $0.primaryTag != nil }.count
        out("topics", ms(t), "\(tp.topics.count) topics (\(tagged) by a tag), biggest \(sizes.prefix(5).map(String.init).joined(separator: " ")), loose \(Int(loose))%")
        if let big = tp.topics.max(by: { $0.itemIds.count < $1.itemIds.count }) {
            // what holds the biggest together, as numbers: its kinds, whether a tag names it and how many rows carry that tag
            let tagRows = big.primaryTag.map { tg in inputs.filter { $0.tags.contains(tg) }.count } ?? 0
            let ids = Set(big.itemIds)
            let withTags = inputs.filter { ids.contains($0.id) && !$0.tags.isEmpty }.count
            out("biggest topic", 0, "\(big.subtitle); by a tag: \(big.primaryTag != nil), tag on \(tagRows) rows; \(withTags) of its rows have any tag")
            var tagCount: [String: Int] = [:]
            for i in inputs { for k in Set(i.tags.map { $0.kind + ":" + $0.name.lowercased() }) { tagCount[k, default: 0] += 1 } }
            out("tags by rows", 0, tagCount.values.sorted(by: >).prefix(8).map(String.init).joined(separator: " "))
        }
        t = Date()
        var byDay: [String: [TopicInput]] = [:]
        for i in inputs { byDay[StreamZoomRules.dayKey(i.at, cal: .current), default: []].append(i) }
        var named = 0
        for (_, items) in byDay where !StreamGroupRules.dayTopics(items).isEmpty { named += 1 }
        out("day lines", ms(t), "\(byDay.count) days, \(named) with a topic")

        // drawn: each step as he takes it, rows -> weeks -> rows, then the topics view
        let host = NSHostingView(rootView: WindowView(titlebar: true).environmentObject(model))
        let w = PreviewKeyWindow(contentRect: NSRect(x: -9000, y: -9000, width: 1100, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 1100, height: 900); model.width = 1100
        w.orderFrontRegardless()
        func draw(_ what: String, _ change: () -> Void) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let t = Date()
            change()
            settle(host)
            out("draw " + what, ms(t), "")
        }
        model.stream.byTopic = false
        model.stream.zoom = .normal
        draw("rows (first)") {}
        model.stream.cardCache = nil
        for (a, b) in [(StreamZoomRules.Level.normal, StreamZoomRules.Level.sessions), (.sessions, .days), (.days, .weeks), (.weeks, .days), (.days, .sessions), (.sessions, .normal),
                       (.normal, .compact), (.compact, .detailed), (.detailed, .normal)] {
            draw("\(a.name.lowercased()) -> \(b.name.lowercased())") { model.zoom(by: b.rawValue - a.rawValue) }
        }
        draw("topics on") { model.stream.byTopic = true }
        draw("topics off") { model.stream.byTopic = false }
        w.orderOut(nil)
        exit(0)
    }

    /// Runs SwiftUI's pending updates and draws once.
    static func settle(_ host: NSView) {
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
    }
    static func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
    static func out(_ what: String, _ ms: Int, _ note: String) {
        print(what.padding(toLength: 26, withPad: " ", startingAt: 0) + String(format: "%6d ms", ms) + (note.isEmpty ? "" : "  " + note))
        fflush(stdout)
    }
}
