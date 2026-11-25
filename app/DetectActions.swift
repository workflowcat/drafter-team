// What one can do with a thing found in a text (detect round, 15 November 2026). `actions(for:)` is plain data: a
// name (an imperative verb, the app's word list), a suggested key for the reader, whether it is built. `run` does it
// through the system handlers: no calendar or contacts permission, no network. A calendar event is a small .ics file
// in a temp folder opened with the default calendar app. Nothing here logs a found value.
// Rules: app/DetectRules.swift. Tests: tests/detect_rules.swift. Notes: docs/rounds/2026-11-15-detect.md.
import AppKit

struct DetectAction: Equatable {
    let id: String       // stable id for the views and the tests
    let name: String     // imperative: "Open", "Copy link", "Add to Calendar"
    let key: String      // suggested key in the reader while the found thing has focus
    var built = true     // false: listed so the views can show it greyed; `run` does nothing
}

/// What an action needs beyond the found thing: the item's whole text (calendar notes, the sentence around a date),
/// the page title a clip carries, and the item's source link (where an issue reference opens).
struct DetectContext {
    var text = ""
    var title = ""
    var sourceLink: String? = nil
    var exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
}

enum DetectActions {
    // keys in the reader while a found thing has focus (letters are free there: E is Edit only on the item)
    static let open = "↵", copy = "C", copy2 = "⇧C", calendar = "K", remind = "R", reveal = "F"

    static func actions(for f: Found, context: DetectContext = DetectContext()) -> [DetectAction] {
        if f.sensitive { return [DetectAction(id: "copy", name: "Copy", key: copy)] }
        switch f.kind {
        case .link:
            return [DetectAction(id: "open", name: "Open", key: open), DetectAction(id: "copy", name: "Copy link", key: copy),
                    DetectAction(id: "markdown", name: "Copy as Markdown", key: copy2)]
        case .email:
            return [DetectAction(id: "compose", name: "Write", key: open), DetectAction(id: "copy", name: "Copy address", key: copy)]
        case .phone:
            return [DetectAction(id: "call", name: "Call", key: open), DetectAction(id: "copy", name: "Copy number", key: copy)]
        case .date, .dateRange:
            return [DetectAction(id: "calendar", name: "Add to Calendar", key: calendar),
                    DetectAction(id: "iso", name: "Copy ISO date", key: copy),
                    DetectAction(id: "remind", name: "Remind me", key: remind, built: false)]
        case .address:
            return [DetectAction(id: "maps", name: "Show on map", key: open), DetectAction(id: "copy", name: "Copy address", key: copy)]
        case .money:
            return [DetectAction(id: "number", name: "Copy amount", key: copy), DetectAction(id: "copy", name: "Copy with currency", key: copy2)]
        case .path:
            var a: [DetectAction] = []
            if !f.bare && context.exists(f.value) { a.append(DetectAction(id: "reveal", name: "Show in Finder", key: reveal)) }
            a.append(DetectAction(id: "copy", name: "Copy path", key: copy))
            return a
        case .command, .code:
            return [DetectAction(id: "copy", name: "Copy", key: copy)]
        case .issue:
            var a: [DetectAction] = []
            if refURL(f, source: context.sourceLink, text: context.text) != nil { a.append(DetectAction(id: "open", name: "Open", key: open)) }
            a.append(DetectAction(id: "copy", name: "Copy", key: copy))
            return a
        case .iban, .tracking, .ip, .version, .color:
            return [DetectAction(id: "copy", name: "Copy", key: copy)]
        case .oneTimeCode, .card:
            return [DetectAction(id: "copy", name: "Copy", key: copy)]
        }
    }

    /// The text an action puts on the clipboard (nil: the action does not copy).
    static func copyText(_ id: String, _ f: Found, context: DetectContext = DetectContext()) -> String? {
        switch id {
        case "copy":
            switch f.kind {
            case .money: return f.words.trimmingCharacters(in: .whitespaces)
            case .phone: return f.value
            case .path: return f.bare ? f.value : f.words
            default: return f.value
            }
        case "markdown": return ClipRules.markdown(f.value, title: context.title)
        case "iso": return f.value
        case "number": return f.amount.map(Detect.moneyText) ?? f.value
        default: return nil
        }
    }

    /// Where an issue reference opens: the host of the item's source link, or of a link of a known tracker in the
    /// same text. GitHub: owner/repo#N (or #N with a repo link); Jira: PROJ-N; Linear: TEAM-N. Else nil (copy only).
    static func refURL(_ f: Found, source: String?, text: String = "") -> URL? {
        var hosts: [URL] = []
        if let s = source, let u = URL(string: s), u.host != nil { hosts.append(u) }
        if !text.isEmpty {
            for x in Detect.scan(text, written: Date()) where x.kind == .link { if let u = URL(string: x.value) { hosts.append(u) } }
        }
        for u in hosts {
            guard let h = u.host?.lowercased() else { continue }
            let parts = u.path.split(separator: "/").map(String.init)
            if h == "github.com" {
                if f.value.contains("/"), let hashI = f.value.firstIndex(of: "#") {
                    return URL(string: "https://github.com/\(f.value[..<hashI])/issues/\(f.value[f.value.index(after: hashI)...])")
                }
                if f.value.hasPrefix("#"), parts.count >= 2 {
                    return URL(string: "https://github.com/\(parts[0])/\(parts[1])/issues/\(f.value.dropFirst())")
                }
            }
            if h.hasSuffix(".atlassian.net"), !f.value.contains("/"), !f.value.hasPrefix("#") {
                return URL(string: "https://\(h)/browse/\(f.value)")
            }
            if h == "linear.app", parts.count >= 1, !f.value.contains("/"), !f.value.hasPrefix("#") {
                return URL(string: "https://linear.app/\(parts[0])/issue/\(f.value)")
            }
        }
        return nil
    }

    // MARK: - calendar event as an .ics file

    /// The sentence around the date without the date's words: the event's title.
    static func eventTitle(text: String, around r: NSRange) -> String {
        let ns = text as NSString
        guard NSMaxRange(r) <= ns.length else { return "Event" }
        let stops = CharacterSet(charactersIn: ".!?\n")
        var a = r.location, b = NSMaxRange(r)
        while a > 0, let u = Unicode.Scalar(ns.character(at: a - 1)), !stops.contains(u) { a -= 1 }
        while b < ns.length, let u = Unicode.Scalar(ns.character(at: b)), !stops.contains(u) { b += 1 }
        let before = ns.substring(with: NSRange(location: a, length: r.location - a))
        let after = ns.substring(with: NSRange(location: NSMaxRange(r), length: b - NSMaxRange(r)))
        var t = (before + " " + after).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        for tail in [" о", " об", " at", " on", " в", " у", " до", " by", " з", " from"] where t.lowercased().hasSuffix(tail) {
            t = String(t.dropLast(tail.count))
        }
        if t.count > 80 { t = String(t.prefix(79)) + "…" }
        return t.isEmpty ? "Event" : t.prefix(1).uppercased() + t.dropFirst()
    }

    static func icsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
    }
    /// Lines over 75 bytes fold with a leading space (RFC 5545 3.1), never inside a character.
    static func icsFold(_ line: String) -> String {
        var out = "", cur = 0
        for ch in line {
            let n = String(ch).utf8.count
            if cur + n > 75 { out += "\r\n "; cur = 1 }
            out.append(ch); cur += n
        }
        return out
    }

    /// One VEVENT. A day without a time is an all-day event (DTEND the day after its last day); a time without an end
    /// lasts one hour. Times are written in UTC.
    static func ics(for f: Found, title: String, notes: String, timeZone: TimeZone = .current, now: Date = Date(), uid: String = UUID().uuidString) -> String? {
        guard let start = f.date else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let utc = DateFormatter(); utc.locale = Locale(identifier: "en_US_POSIX"); utc.timeZone = TimeZone(identifier: "UTC"); utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = timeZone; day.dateFormat = "yyyyMMdd"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Drafter//Detect//EN", "CALSCALE:GREGORIAN", "BEGIN:VEVENT",
                     "UID:\(uid)@drafter.local", "DTSTAMP:\(utc.string(from: now))"]
        if f.allDay {
            let last = f.end ?? start
            let after = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last))!
            lines += ["DTSTART;VALUE=DATE:\(day.string(from: start))", "DTEND;VALUE=DATE:\(day.string(from: after))"]
        } else {
            lines += ["DTSTART:\(utc.string(from: start))", "DTEND:\(utc.string(from: f.end ?? start.addingTimeInterval(3600)))"]
        }
        lines += ["SUMMARY:" + icsEscape(title), "DESCRIPTION:" + icsEscape(String(notes.prefix(4000))), "END:VEVENT", "END:VCALENDAR"]
        return lines.map(icsFold).joined(separator: "\r\n") + "\r\n"
    }

    static var eventsDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("drafter-events", isDirectory: true) }

    // MARK: - running

    /// Runs an action. Returns false when it could not (not built, nothing to open). Never logs the value.
    @discardableResult
    static func run(_ a: DetectAction, on f: Found, context: DetectContext = DetectContext()) -> Bool {
        guard a.built else { return false }
        if let t = copyText(a.id, f, context: context) {
            let pb = NSPasteboard.general
            pb.clearContents()
            if f.sensitive { pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
            return pb.setString(t, forType: .string)
        }
        let ws = NSWorkspace.shared
        switch a.id {
        case "open":
            if f.kind == .issue { guard let u = refURL(f, source: context.sourceLink, text: context.text) else { return false }; return ws.open(u) }
            guard let u = URL(string: f.value) else { return false }
            return ws.open(u)
        case "compose":
            guard let u = URL(string: "mailto:" + (f.value.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? f.value)) else { return false }
            return ws.open(u)
        case "call":
            guard let u = URL(string: "tel:" + f.value.filter { $0 == "+" || $0.isNumber }) else { return false }
            return ws.open(u)
        case "maps":
            var c = URLComponents(string: "maps://")!; c.queryItems = [URLQueryItem(name: "q", value: f.value)]
            guard let u = c.url else { return false }
            return ws.open(u)
        case "reveal":
            guard context.exists(f.value) else { return false }
            ws.activateFileViewerSelecting([URL(fileURLWithPath: f.value)])
            return true
        case "calendar":
            let title = eventTitle(text: context.text.isEmpty ? f.words : context.text, around: context.text.isEmpty ? NSRange(location: 0, length: (f.words as NSString).length) : f.range)
            guard let body = ics(for: f, title: title, notes: context.text) else { return false }
            let dir = eventsDir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(UUID().uuidString + ".ics")
            guard (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
            return ws.open(url)
        default:
            return false
        }
    }
}
