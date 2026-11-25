// What each typing feature earned, read from data/app.log (2026-11-13, window round: Settings shows shown / taken
// for the last 7 days next to each switch; Help used to print today's numbers for suggestions only). Pure: the
// window reads the file off the main thread and hands the lines here. Also the side warnings a recording logged
// while it ran, for Calls & notes when a recording has no words.
import Foundation

enum LogStats {
    struct Count: Equatable { var shown = 0; var taken = 0 }

    /// Feature keys, one per Settings row that has numbers.
    /// (Claude on a pause, proofread, translate and fact chips went on 2026-11-17; their old log lines count nowhere.)
    static let suggest = "suggest", next = "next", typo = "typo", layout = "layout", rework = "rework", fixWord = "fixword"

    /// Lines are "<ISO time> <message>"; only lines at or after `since` (same ISO form, UTC) count.
    /// Also counts voice takes on `today` (a "yyyy-MM-dd" UTC prefix) under the key "takes".
    static func count<S: Sequence>(_ lines: S, since: String, today: String = "") -> [String: Count] where S.Element: StringProtocol {
        var c: [String: Count] = [:], back: [String: Int] = [:]
        func shown(_ k: String) { c[k, default: Count()].shown += 1 }
        func taken(_ k: String) { c[k, default: Count()].taken += 1 }
        for raw in lines {
            guard let sp = raw.firstIndex(of: " ") else { continue }
            let ts = raw[..<sp]
            guard ts >= since else { continue }
            let msg = raw[raw.index(after: sp)...]
            let w = msg.split(separator: " ", maxSplits: 12, omittingEmptySubsequences: true)
            guard let head = w.first else { continue }
            switch head {
            case "shown":
                // shown <app> <ms> fix <kind> | shown <app> <ms> engine <ms> claude… | shown <app> <ms> engine <ms> [src]…
                if w.count > 3, w[3] == "fix" { shown(fixWord) }
                else if w.count > 5, w[5] == "claude" { continue }   // Claude on a pause, before 2026-11-17
                else if w.count > 3, w[3] == "engine" { shown(suggest) }
            case "ghost":
                // ghost <app> <src> len N word W taken T typed Y
                guard w.count > 2, let i = w.firstIndex(of: "taken"), i + 1 < w.count, let t = Int(w[i + 1]), t > 0 else { continue }
                if w[2] != "claude" { taken(suggest) }
            case "fix":
                if w.count > 1, w[1] == "taken" { taken(fixWord) }
                // fix offer space <typo | layout uk | layout en> <taken | typed | expired | changed> <ms>ms: the offer mode
                // (default since 13 November) says how each word-end fix it showed ended (Argon 21)
                else if w.count > 4, w[1] == "offer", w[2] == "space" {
                    let kind = w[3] == "layout" ? layout : typo
                    let how = w[3] == "layout" && w.count > 5 ? w[5] : w[4]
                    shown(kind); if how == "taken" { taken(kind) }
                }
            case "autocorrect":
                guard w.count > 1 else { continue }
                if w[1] == "taken" || w[1] == "undone" {
                    let kind = msg.contains("(layout") ? layout : typo     // "(layout uk) 340ms after tab"
                    back[kind, default: 0] += 1
                } else if w[1] == "typo" || w[1] == "layout" { shown(String(w[1])); taken(String(w[1])) }
            case "next":
                guard msg.hasPrefix("next message") else { continue }
                if msg.hasPrefix("next message taken") { taken(next) }
                else if msg.contains(" shown in ") || msg.contains(" drafted in ") { shown(next) }
            case "rework":
                guard w.count > 1 else { continue }
                if w[1] == "applied" { taken(rework) }
                else if w[1] == "taken" { back[rework, default: 0] += 1 }
                else if !w[1].hasSuffix(":"), msg.contains(" by "), msg.contains(" chars") { shown(rework) }
            case "take":
                if !today.isEmpty, ts.hasPrefix(today), msg.contains(" s, peak") { c["takes", default: Count()].shown += 1 }
            default: continue
            }
        }
        for (k, n) in back { c[k, default: Count()].taken = max(0, (c[k]?.taken ?? 0) - n) }
        return c
    }

    /// The integer just before `word` ("… 3 fixes" -> 3).
    static func number<S: StringProtocol>(before word: String, in s: S) -> Int? {
        guard let r = s.range(of: " " + word) else { return nil }
        let left = s[..<r.lowerBound]
        return Int(left.split(separator: " ").last ?? "")
    }

    /// The distinct side warnings a recording logged between `from` and `to` (ISO, UTC), in the order first seen:
    /// "recording: warning: <text> (me … )". A warning that cleared ("both sides heard again") still counts: it says
    /// what went missing for a while.
    static func warnings<S: Sequence>(_ lines: S, from: String, to: String) -> [String] where S.Element: StringProtocol {
        var out: [String] = []
        for raw in lines {
            guard let sp = raw.firstIndex(of: " ") else { continue }
            let ts = raw[..<sp]
            guard ts >= from, ts <= to else { continue }
            let msg = raw[raw.index(after: sp)...]
            guard msg.hasPrefix("recording: warning: ") else { continue }
            var w = String(msg.dropFirst("recording: warning: ".count))
            if let p = w.range(of: " (me ") { w = String(w[..<p.lowerBound]) }
            if !w.isEmpty, !out.contains(w) { out.append(w) }
        }
        return out
    }

    static let iso: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f
    }()
    static func stamp(_ d: Date) -> String { iso.string(from: d) }
}
