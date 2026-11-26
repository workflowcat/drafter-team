// The journal's timeline in chunks that grow coarser with age (14 November 2026, the user: "whether something has been
// done today or last week, did like lunch, or very old"). Today and Yesterday by part of the day; the rest of this
// week and last week by day; the rest of this month by week; each earlier month of this year by week; each earlier
// year by month. Sessions (TapeRules.sessions) sit under the finest level; totals add up from them. Pure: `now` and
// the calendar come in (Monday starts the user's week); tested in tests/time_chunk_rules.swift.
import Foundation

enum TimeChunks {
    enum Level: Int { case chunk, year, month, week, day, part, session }

    /// One step of a path: its level, a stable id, its title and when it starts.
    struct Key: Hashable { let level: Level; let id: String; let title: String; let start: Double }

    /// The parts of a day: Night 00-06, Morning 06-12, Midday 12-14, Afternoon 14-18, Evening 18-24.
    static let parts: [(from: Int, name: String)] = [(0, "Night"), (6, "Morning"), (12, "Midday"), (14, "Afternoon"), (18, "Evening")]
    static func part(hour h: Int) -> (index: Int, name: String) {
        let i = parts.lastIndex { $0.from <= h } ?? 0
        return (i, parts[i].name)
    }

    /// Which chunk a top key is: today, yesterday, week, lastweek, month (this month), m (an earlier month), y.
    static func chunkKind(_ id: String) -> String {
        let p = id.split(separator: ":")
        return p.count >= 2 ? String(p[1]) : id
    }

    private static var formatters: [String: DateFormatter] = [:]
    private static let fmtLock = NSLock()
    static func fmt(_ f: String, _ cal: Calendar) -> DateFormatter {
        let key = f + "|" + cal.timeZone.identifier
        fmtLock.lock(); defer { fmtLock.unlock() }
        if let d = formatters[key] { return d }
        let d = DateFormatter(); d.calendar = cal; d.timeZone = cal.timeZone; d.locale = Locale(identifier: "en_GB"); d.dateFormat = f
        formatters[key] = d
        return d
    }

    /// The edges of the chunks for one `now`, worked out once, and each day's path kept (a year of rows asks the
    /// calendar once per day, not once per row).
    final class Frame {
        let cal: Calendar, now: Double
        let today: Date, yesterday: Date, weekStart: Date, lastWeekStart: Date, monthStart: Date, yearStart: Date
        private var days: [Double: [Key]] = [:]
        init(now: Double, cal: Calendar) {
            self.cal = cal; self.now = now
            let n = Date(timeIntervalSince1970: now)
            today = cal.startOfDay(for: n)
            yesterday = cal.date(byAdding: .day, value: -1, to: today)!
            weekStart = cal.dateInterval(of: .weekOfYear, for: n)!.start
            lastWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart)!
            monthStart = cal.dateInterval(of: .month, for: n)!.start
            yearStart = cal.dateInterval(of: .year, for: n)!.start
        }
        func path(_ t0: Double) -> [Key] {
            let t = min(t0, now), at = Date(timeIntervalSince1970: t)
            let day = cal.startOfDay(for: at)
            if day >= today || day == yesterday {   // today and yesterday: the part of the day
                let p = part(hour: cal.component(.hour, from: at))
                let isToday = day >= today
                let from = cal.date(bySettingHour: parts[p.index].from, minute: 0, second: 0, of: day) ?? day
                return [Key(level: .chunk, id: isToday ? "c:today" : "c:yesterday", title: isToday ? "Today" : "Yesterday", start: (isToday ? today : yesterday).timeIntervalSince1970),
                        Key(level: .part, id: "p:\(fmt("yyyy-MM-dd", cal).string(from: day)):\(p.index)", title: p.name, start: from.timeIntervalSince1970)]
            }
            let k = day.timeIntervalSince1970
            if let d = days[k] { return d }
            let d = dayPath(day)
            days[k] = d
            return d
        }
        private func dayPath(_ day: Date) -> [Key] {
            let ymd = fmt("yyyy-MM-dd", cal), ym = fmt("yyyy-MM", cal)
            func dayKey() -> Key { Key(level: .day, id: "d:" + ymd.string(from: day), title: fmt("EEEE d MMMM", cal).string(from: day), start: day.timeIntervalSince1970) }
            func weekKey() -> Key {
                let w = cal.dateInterval(of: .weekOfYear, for: day)!, m = cal.dateInterval(of: .month, for: day)!
                let a = max(w.start, m.start), b = cal.date(byAdding: .day, value: -1, to: min(w.end, m.end))!
                let da = cal.component(.day, from: a), db = cal.component(.day, from: b)
                let month = fmt("MMMM", cal).string(from: a)
                return Key(level: .week, id: "w:" + ymd.string(from: a), title: da == db ? "\(da) \(month)" : "\(da)–\(db) \(month)", start: a.timeIntervalSince1970)
            }
            func chunk(_ id: String, _ title: String, _ start: Date) -> Key { Key(level: .chunk, id: "c:" + id, title: title, start: start.timeIntervalSince1970) }
            if day >= weekStart { return [chunk("week", "This week", weekStart), dayKey()] }
            if day >= lastWeekStart { return [chunk("lastweek", "Last week", lastWeekStart), dayKey()] }
            if day >= monthStart { return [chunk("month", "This month", monthStart), weekKey(), dayKey()] }
            let mStart = cal.dateInterval(of: .month, for: day)!.start
            if day >= yearStart { return [chunk("m:" + ym.string(from: mStart), fmt("MMMM", cal).string(from: mStart), mStart), weekKey(), dayKey()] }
            let yStart = cal.dateInterval(of: .year, for: day)!.start
            let month = Key(level: .month, id: "m:" + ym.string(from: mStart), title: fmt("MMMM yyyy", cal).string(from: mStart), start: mStart.timeIntervalSince1970)
            return [chunk("y:" + fmt("yyyy", cal).string(from: yStart), fmt("yyyy", cal).string(from: yStart), yStart), month, weekKey(), dayKey()]
        }
    }

    /// The path of a moment, top first: [chunk, part] for today and yesterday; [chunk, day] in the two week chunks;
    /// [chunk, week, day] in this month and in an earlier month of this year; [chunk (year), month, week, day] before.
    /// A moment after `now` counts as now. (Many moments: make one Frame and ask it.)
    static func path(_ t: Double, now: Double, cal: Calendar) -> [Key] { Frame(now: now, cal: cal).path(t) }

    /// A row's time in the gutter, by its chunk: the clock today and yesterday; weekday and clock in the week chunks;
    /// day and month in month chunks; day, month and year before this year.
    static func rowTime(_ t: Double, chunk: String, cal: Calendar) -> String {
        let d = Date(timeIntervalSince1970: t)
        switch chunkKind(chunk) {
        case "today", "yesterday": return fmt("HH:mm", cal).string(from: d)
        case "week", "lastweek": return fmt("EEE HH:mm", cal).string(from: d)
        case "y": return fmt("d MMM yy", cal).string(from: d)
        default: return fmt("d MMM", cal).string(from: d)
        }
    }

    /// "just now", "5 min ago", "2 hours ago", "yesterday at 18:40", "on Tuesday", "last Tuesday", "3 weeks ago",
    /// "in October", "in October 2025".
    static func relative(_ t: Double, now: Double, cal: Calendar) -> String {
        let d = now - t
        if d < 60 { return "just now" }
        if d < 3600 { return "\(Int(d / 60)) min ago" }
        let p = path(t, now: now, cal: cal), c = chunkKind(p[0].id)
        let at = Date(timeIntervalSince1970: t)
        switch c {
        case "today": let h = Int(d / 3600); return h == 1 ? "an hour ago" : "\(h) hours ago"
        case "yesterday": return "yesterday at " + fmt("HH:mm", cal).string(from: at)
        case "week": return "on " + fmt("EEEE", cal).string(from: at)
        case "lastweek": return "last " + fmt("EEEE", cal).string(from: at)
        default:
            let w = Int(d / (7 * 86400))
            if w <= 4, c == "month" { return w <= 1 ? "two weeks ago" : "\(w) weeks ago" }
            return c == "y" ? "in " + fmt("MMMM yyyy", cal).string(from: at) : "in " + fmt("MMMM", cal).string(from: at)
        }
    }

    // MARK: the tree

    /// What a node adds up: active time (seconds), recordings, items.
    struct Totals: Equatable { var active: Double = 0, recordings = 0, items = 0 }
    /// One session handed to the tree: its id, path, active time, recordings and items.
    struct SessionIn { let id: String; let path: [Key]; let active: Double; let recordings: Int; let items: Int }
    struct Node: Equatable {
        let key: Key
        var totals = Totals()
        var children: [Node] = []
        var session = -1            // a session leaf: its index in the input
    }

    /// The tree of chunks, sessions in the order given (newest first). An empty chunk never appears: nodes come only
    /// from sessions.
    static func tree(_ sessions: [SessionIn]) -> [Node] {
        var roots: [Node] = []
        func add(_ nodes: inout [Node], _ path: ArraySlice<Key>, _ i: Int, _ s: SessionIn) {
            guard let k = path.first else {
                var leaf = Node(key: Key(level: .session, id: s.id, title: "", start: 0)); leaf.session = i
                leaf.totals = Totals(active: s.active, recordings: s.recordings, items: s.items)
                nodes.append(leaf); return
            }
            let j: Int
            if let f = nodes.lastIndex(where: { $0.key.id == k.id }) { j = f } else { nodes.append(Node(key: k)); j = nodes.count - 1 }
            nodes[j].totals.active += s.active; nodes[j].totals.recordings += s.recordings; nodes[j].totals.items += s.items
            add(&nodes[j].children, path.dropFirst(), i, s)
        }
        for (i, s) in sessions.enumerated() { add(&roots, s.path[...], i, s) }
        return roots
    }

    /// Is a node open by default? Chunks through this month are open, earlier months and years folded; parts are
    /// always open; days, weeks and months inside a chunk start folded; sessions by `fold` ("older": today's open,
    /// the rest folded; "none": all open; "all": all folded).
    static func openByDefault(_ k: Key, chunk: String, fold: String, sparse: Bool = false) -> Bool {
        if sparse, k.level != .session { return true } // small result sets expose every date, including earlier years
        switch k.level {
        case .chunk: return !["m", "y"].contains(chunkKind(k.id))
        case .part: return true
        case .session: return fold == "none" || (fold != "all" && chunkKind(chunk) == "today")
        default: return false
        }
    }

    /// Totals in words: "2 h 10 min active · 1 recording · 23 items".
    static func words(_ t: Totals) -> String {
        var out: [String] = []
        if t.active >= 60 { out.append(duration(t.active) + " active") }
        if t.recordings > 0 { out.append("\(t.recordings) recording" + (t.recordings == 1 ? "" : "s")) }
        out.append("\(t.items) item" + (t.items == 1 ? "" : "s"))
        return out.joined(separator: " · ")
    }
    /// "40 s", "12 min", "2 h 10 min".
    static func duration(_ s: Double) -> String {
        let n = Int(s.rounded())
        if n < 60 { return "\(n) s" }
        if n < 3600 { return "\(n / 60) min" }
        return n % 3600 / 60 == 0 ? "\(n / 3600) h" : "\(n / 3600) h \(n % 3600 / 60) min"
    }
}
