import AppKit
import Carbon

enum Snippets {
    private static let nestedRX = try? NSRegularExpression(pattern: #"\{(;[^{}\s]{1,30})\}"#)
    private static let dateRX = try? NSRegularExpression(pattern: #"\{date(?:([+-]\d{1,3})d?)?\}"#)
    private static let fieldRX = try? NSRegularExpression(pattern: #"\{(cursor|[\p{L}][\p{L}\p{N}_ ]{0,19}(?:=[^{}\n]{0,60}|:[^{}\n]{1,120})?|[^{}|\n]{1,40}(?:\|[^{}|\n]{1,40})+)\}"#)
    static func read(_ name: String) -> [String: String] {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: Home.data.appendingPathComponent(name)))) as? [String: String] ?? [:])
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }
    private static let cachedSnippets = LocalSnapshot<[String: String]>([Home.data.appendingPathComponent("snippets.json")]) { files in
        guard let data = files[0] else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data).filter { $0.key.hasPrefix(";") && !$0.value.isEmpty }
    }
    private static let cachedReplacements = LocalSnapshot<[String: String]>([Home.data.appendingPathComponent("replacements.json")]) { files in
        guard let data = files[0] else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data).filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }
    static var all: [String: String] { cachedSnippets.read() ?? [:] }
    static var replacements: [String: String] { cachedReplacements.read() ?? [:] }
    static var ready: Bool { cachedSnippets.read() != nil }
    static let cues: [SnippetCue] = (try? JSONDecoder().decode([SnippetCue].self, from: Data(contentsOf: Home.root.appendingPathComponent("dictionary/snippet-cues.json")))) ?? []
    static var endings = UkrainianEndings()
    private static var refreshed = Date.distantPast
    static func refreshEndings() {
        guard Drafter.shared.settings.learn, Date().timeIntervalSince(refreshed) > 60 else { return }
        refreshed = Date()
        DispatchQueue.global(qos: .utility).async {
            var index = UkrainianEndings()
            // Bounded local history, no clipboard, notes or external services.
            if let file = FileHandle(forReadingAtPath: Home.data.appendingPathComponent("typed.jsonl").path) {
                let size = (try? file.seekToEnd()) ?? 0
                try? file.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
                let data = file.readDataToEndOfFile(); try? file.close()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(3000) {
                    if let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let text = row["text"] as? String { index.add(text) }
                }
            }
            DispatchQueue.main.async { endings = index }
        }
    }
    /// A snippet ready to type: the text, where the caret goes at the end (characters back from the end), and the
    /// places to fill in (Fields), each as a character offset and length in `text`.
    struct Filled { var text: String; var back: Int; var stops: [Fields.Stop] = []; var final: Int? = nil }

    /// Places to fill in a snippet (1 November 2026; TextExpander, Espanso, Raycast): {date} 01.11.2026, {date+2d},
    /// {date-1d}, {time} 14:05, {clipboard}, {cursor} where the caret stays, {;key} another snippet's text, and fields
    /// that Tab walks through: {name} (the word "name" selected, typing replaces it), {name=default}, {name:a|b|c} and
    /// {a|b|c} (a choice: ↑ ↓ change it). A second {name} takes what the user typed in the first.
    static func fill(_ raw: String, now: Date = Date(), clipboard: String? = nil, snippets: [String: String]? = nil, depth: Int = 0) -> Filled {
        guard raw.contains("{") else { return Filled(text: raw, back: 0) }
        var t = raw
        // {;key}: another snippet, three levels at most
        if depth < 3, t.contains("{;"), let re = nestedRX {
            let all = snippets ?? Snippets.all
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let r = Range(m.range(at: 1), in: t), let key = all.keys.first(where: { $0.lowercased() == t[r].lowercased() }),
                      let v = all[key] else { continue }
                let inner = depth < 2 ? v : v.replacingOccurrences(of: #"\{;[^{}\s]{1,30}\}"#, with: "", options: .regularExpression)
                t = (t as NSString).replacingCharacters(in: m.range, with: inner)
            }
            if t.contains("{;") { return fill(t, now: now, clipboard: clipboard, snippets: all, depth: depth + 1) }
        }
        let day = DateFormatter(); day.dateFormat = "dd.MM.yyyy"
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        if let re = dateRX {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                let shift = Range(m.range(at: 1), in: t).flatMap { Int(t[$0]) } ?? 0
                let d = Calendar.current.date(byAdding: .day, value: shift, to: now) ?? now
                t = (t as NSString).replacingCharacters(in: m.range, with: day.string(from: d))
            }
        }
        t = t.replacingOccurrences(of: "{time}", with: hm.string(from: now))
        if t.contains("{clipboard}") || t.contains("{clip}") {
            let c = clipboard ?? NSPasteboard.general.string(forType: .string) ?? ""
            t = t.replacingOccurrences(of: "{clipboard}", with: c).replacingOccurrences(of: "{clip}", with: c)
        }
        // {cursor} and fields, left to right, so each place knows where it lands
        guard let re = fieldRX else { return Filled(text: t, back: 0) }
        var out = "", count = 0, stops: [Fields.Stop] = [], final: Int?, first: [String: String] = [:]
        var last = t.startIndex
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range, in: t), let b = Range(m.range(at: 1), in: t) else { continue }
            let lit = String(t[last..<r.lowerBound]); out += lit; count += lit.count; last = r.upperBound
            let body = String(t[b])
            if body == "cursor" { if final == nil { final = count }; continue }
            var name = "", place = "", options: [String] = []
            if let eq = body.firstIndex(of: "="), !body[..<eq].contains("|") {
                name = String(body[..<eq]); place = String(body[body.index(after: eq)...])
            } else if let c = body.firstIndex(of: ":"), !body[..<c].contains("|") {
                name = String(body[..<c]); options = body[body.index(after: c)...].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                place = options.first ?? ""
            } else if body.contains("|") {
                options = body.split(separator: "|", omittingEmptySubsequences: false).map(String.init); place = options.first ?? ""
            } else { name = body; place = body }
            name = name.trimmingCharacters(in: .whitespaces)
            let copy = !name.isEmpty && first[name] != nil
            if copy { place = first[name]!; options = [] } else if !name.isEmpty { first[name] = place }
            stops.append(Fields.Stop(name: name, at: count, len: place.count, text: place, options: options, copy: copy))
            out += place; count += place.count
        }
        out += t[last...]
        return Filled(text: out, back: final.map { out.count - $0 } ?? 0, stops: stops, final: final)
    }

    /// ";Mail" puts "Alex@..." with a capital first letter (TextExpander's "adapt to case"); keys with capitals
    /// (";AU") stay as they are.
    static func adapt(_ text: String, typed: String, key: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(";"), key.hasPrefix(";"), let a = t.dropFirst().first, let k = key.dropFirst().first,
              a.isUppercase, k.isLowercase, let i = text.firstIndex(where: { $0.isLetter }), text[i].isLowercase else { return text }
        let up = String(text[i]).uppercased()
        guard up.count == 1 else { return text }
        return text.replacingCharacters(in: i...i, with: up)
    }

    /// `Drafter --snippet-test`: the fill-in places on a fixed day; nothing is typed.
    static func selfTest() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 1; c.hour = 14; c.minute = 5
        let now = Calendar.current.date(from: c)!
        let snips = [";sig": "Best, {name=Alex}", ";loop": "x {;loop}"]
        // raw, text, back, stops as "name@at+len" ("*" = takes the first one's text, "[a|b]" = choices)
        let cases: [(String, String, Int, String)] = [
            ("see you {date+2d}", "see you 03.11.2026", 0, ""), ("{date} {time}", "01.11.2026 14:05", 0, ""),
            ("was {date-1}", "was 31.10.2026", 0, ""), ("Hi {cursor}, thanks", "Hi , thanks", 8, ""),
            ("link: {clipboard}", "link: https://x.y", 0, ""), ("plain", "plain", 0, ""), (#"{"a":1}"#, #"{"a":1}"#, 0, ""),
            ("Hi {name}, see you {day:Mon|Tue}. {name}!", "Hi name, see you Mon. name!", 0, "name@3+4 day@17+3[Mon|Tue] name*@22+4"),
            ("Dear {who=Ira},\n\n{cursor}\n\n{;sig}", "Dear Ira,\n\n\n\nBest, Alex", 12, "who@5+3 name@19+4"),
            ("{yes|no} and {x=}", "yes and ", 0, "@0+3[yes|no] x@8+0"), ("{;loop}", "x x x ", 0, ""),
        ]
        var bad = 0
        for (raw, want, back, stops) in cases {
            let got = fill(raw, now: now, clipboard: "https://x.y", snippets: snips)
            let st = got.stops.map { "\($0.name)\($0.copy ? "*" : "")@\($0.at)+\($0.len)" + ($0.options.isEmpty ? "" : "[" + $0.options.joined(separator: "|") + "]") }.joined(separator: " ")
            let ok = got.text == want && got.back == back && st == stops
            if !ok { bad += 1 }
            print(ok ? "ok  " : "FAIL", raw.debugDescription, "->", got.text.debugDescription, got.back, st, ok ? "" : "(want \(want.debugDescription) \(back) \(stops))")
        }
        for (text, typed, key, want) in [("alex@x.ua ", ";Mail ", ";mail", "Alex@x.ua "), ("alex@x.ua ", ";mail ", ";mail", "alex@x.ua "),
                                         ("au@x.ua", ";AU", ";AU", "au@x.ua"), ("дякую", ";Thx", ";thx", "Дякую")] {
            let got = adapt(text, typed: typed, key: key)
            if got != want { bad += 1 }
            print(got == want ? "ok  " : "FAIL", typed, "->", got)
        }
        print(bad == 0 ? "all cases ok" : "\(bad) cases failed")
    }
    // MARK: TextExpander's "suggested snippets" and "you typed it by hand" (1 November 2026)

    static var recent: [String: Date] = [:]          // texts Drafter put in lately, so they never count as typed by hand
    static var reminded: [String: Date] = [:]
    /// Return: a line that holds a shortcut's text the user typed themselves gets one hint, once a day per shortcut.
    static func remind(_ line: String) {
        guard line.count >= 12 else { return }
        recent = recent.filter { Date().timeIntervalSince($0.value) < 600 }
        let low = line.lowercased()
        for (key, value) in all.sorted(by: { $0.key < $1.key }) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.count >= 12, !v.contains("{"), low.contains(v.lowercased()), !recent.keys.contains(where: { $0.contains(v) }) else { continue }
            if let d = reminded[key], Date().timeIntervalSince(d) < 86_400 { continue }
            guard reminded.values.filter({ Date().timeIntervalSince($0) < 86_400 }).count < 3 else { return }
            reminded[key] = Date()
            Ghost.shared.flash("Next time: \(key) + Space")
            log("snippet hint \(key)")
            return
        }
    }

    struct Idea: Identifiable { let text: String; let count: Int; var id: String { text } }
    static var hiddenIdeas: Set<String> { Set((read("snippet-ideas.json")["hidden"] ?? "").split(separator: "\n").map(String.init)) }
    static func hideIdea(_ text: String) {
        var h = hiddenIdeas; h.insert(text.lowercased())
        try? save("hidden", h.sorted().joined(separator: "\n"), file: "snippet-ideas.json")
    }
    /// Sentences of 20-200 characters the user sent three or more times (local typing history, last 3000 lines), not yet a
    /// shortcut and not hidden: the Shortcuts page offers to make them shortcuts. Lines that look pasted (a chat export,
    /// a clipboard text, too long to be typed) are left out (`IdeaRules`). Slow: call off the main thread.
    static func ideas(limit: Int = 5) -> [Idea] {
        func rows(_ name: String, last n: Int, cap: UInt64) -> [String] {
            guard let file = FileHandle(forReadingAtPath: Home.data.appendingPathComponent(name).path) else { return [] }
            let size = (try? file.seekToEnd()) ?? 0
            try? file.seek(toOffset: size > cap ? size - cap : 0)
            let data = file.readDataToEndOfFile(); try? file.close()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(n).compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["text"] as? String
            }
        }
        let sent = rows("typed.jsonl", last: 3000, cap: 2_000_000)
        guard !sent.isEmpty else { return [] }
        let clips = rows("clipboard.jsonl", last: 2000, cap: 8_000_000)
        let have = Set(all.values.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        return IdeaRules.ideas(sent: sent, clipboard: clips, have: have, hidden: hiddenIdeas, limit: limit).map { Idea(text: $0.text, count: $0.count) }
    }
    /// A short key for a phrase: ";" and the first letters of its first three words.
    static func keyFor(_ text: String) -> String {
        var k = ";" + text.lowercased().split(whereSeparator: { !$0.isLetter }).prefix(3).compactMap { $0.first.map(String.init) }.joined()
        if k.count < 3 { k = ";" + String(text.lowercased().filter { $0.isLetter }.prefix(4)) }
        var n = 2, base = k
        while all[k] != nil { k = base + String(n); n += 1 }
        return k
    }

    static func arrowLeft(_ n: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<n {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 123, keyDown: down)
                e?.flags = []; e?.setIntegerValueField(.eventSourceUserData, value: Focus.mark); e?.post(tap: .cghidEventTap)
            }
        }
    }
    static func offer(_ before: String) -> [String: Any]? {
        guard let match = SnippetRules.offer(before, snippets: all, cues: cues) else { return nil }
        return ["id": "snippet", "chip": "⇥ " + String(adapt(fill(match.new).text, typed: match.old, key: match.key).prefix(60)),
                "run": ["kind": "expand", "old": match.old, "new": match.new, "key": match.key]]
    }
    static func save(_ key: String, _ value: String, file: String) throws {
        var rows = read(file)
        rows[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Home.data.appendingPathComponent(file), options: .atomic)
        if file == "snippets.json" { cachedSnippets.publish(rows.filter { $0.key.hasPrefix(";") && !$0.value.isEmpty }) }
        if file == "replacements.json" { cachedReplacements.publish(rows.filter { !$0.key.isEmpty && !$0.value.isEmpty }) }
    }
    static func expand(old: String, new: String, key: String, expected: Spot? = nil, smart: [String: String]? = nil) {
        guard let s = Focus.spot(skip: Drafter.shared.settings.skip).0, s.before.replacingOccurrences(of: "\u{A0}", with: " ").hasSuffix(old),
              let expected, CFEqual(expected.el, s.el), expected.app.processIdentifier == s.app.processIdentifier,
              expected.before == s.before else { Ghost.shared.flash("Text has changed"); return }
        let plain = ["clip", "fact", "lookup", "person"].contains(key)
        // smart fields ({first name}, {company}, {my free slots}…): looked up first, shown as a preview, Tab puts it in
        if smart == nil, !plain, !SmartFields.wanted(new).isEmpty { previewSmart(old: old, new: new, key: key, at: s); return }
        pendingSmart = nil
        Keys.shared.cancel()
        Focus.backspace(old.count)
        // texts from the clipboard or the user's calendar go in as they are
        var f = plain ? Filled(text: new, back: 0) : fill(smart.map { SmartFields.apply(new, values: $0) } ?? new)
        let up = adapt(f.text, typed: old, key: key)
        if up.count == f.text.count { f.text = up }
        Focus.typeText(f.text)
        if !f.stops.isEmpty { Fields.start(f, pid: s.app.processIdentifier, el: s.el) } else if f.back > 0 { arrowLeft(f.back) }
        if key == "clip" { Clip.used() }
        if key == "fact" { log("facts taken") }   // Settings counts fact chips taken (LogStats)
        recent[f.text.trimmingCharacters(in: .whitespacesAndNewlines)] = Date()
        Fields.used(key, typed: old.count, put: f.text.count)
        log("snippet inserted, \(new.count) chars" + (f.stops.isEmpty ? "" : ", \(f.stops.count) places to fill"))
    }
    /// A snippet with smart fields waiting on its preview card: Tab (Keys) puts it in with these values; any other key
    /// drops it. `preview` is the card's text, so another card in its place never takes this path.
    struct PendingSmart { let old: String; let new: String; let key: String; let values: [String: String]; let el: AXUIElement; let preview: String }
    static var pendingSmart: PendingSmart?
    private static var smartSeq = 0

    /// Look the smart fields up (the chat on screen through engine /fields, free slots from the user's calendars, the date
    /// here), then show the filled snippet as a card over the caret. Gaps stay as their field names.
    static func previewSmart(old: String, new: String, key: String, at s: Spot) {
        let wanted = SmartFields.wanted(new)
        smartSeq += 1; let mine = smartSeq
        var values: [String: String] = [:]
        if wanted.contains("date next week") { values["date next week"] = SmartFields.dateNextWeek(now: Date()) }
        let group = DispatchGroup()
        if SmartFields.needsChat(wanted) {
            group.enter()
            let ctx = Keys.shared.contextFor(s)
            Engine.shared.post("/fields", ["app": s.app.localizedName ?? "", "context": String(ctx.suffix(2500))], timeout: 4) { j in
                for k in SmartFields.fromChat { if let v = j?[k] as? String, !v.isEmpty { values[k] = v } }
                group.leave()
            }
        }
        if SmartFields.needsCalendar(wanted) {
            group.enter()
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            let to = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
            Actions.freeSlots(["from": f.string(from: Date()), "to": f.string(from: to), "minutes": 30, "count": 3]) { slots, _ in
                let t = SmartFields.slotsText((slots ?? []).map(\.chip)); if !t.isEmpty { values["my free slots"] = t }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard mine == smartSeq, let now = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(now.el, s.el), now.before == s.before,
                  let r = now.rect ?? Focus.fieldStart(now.el) else { return }
            let preview = fill(SmartFields.apply(new, values: values)).text
            pendingSmart = PendingSmart(old: old, new: new, key: key, values: values, el: now.el, preview: preview)
            Keys.shared.spot = now
            Ghost.shared.showDraft([["text": preview, "label": SmartFields.head(key: key, wanted: wanted, values: values)]], field: Focus.frame(now.el), caret: r)
            log("smart fields: \(wanted.count) asked, \(wanted.filter { !(values[$0] ?? "").isEmpty }.count) filled")
        }
    }

    /// Tab on the preview card: the snippet goes in with the looked-up values; gaps become places to fill.
    static func takeSmart() -> Bool {
        guard let p = pendingSmart, Ghost.shared.isDraft, Ghost.shared.text == p.preview,
              let s = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(s.el, p.el) else { pendingSmart = nil; return false }
        Ghost.shared.hide()
        expand(old: p.old, new: p.new, key: p.key, expected: s, smart: p.values)
        return true
    }

    static func afterSpace(revision: Int, expected: AXUIElement?) {
        guard Talk.shared.keysFree, let expected else { return }
        let t0 = Date()
        func look() {
            guard Keys.shared.inputRevision == revision, Drafter.shared.active, Talk.shared.keysFree else { return }
            let (spot, why) = Focus.spot(skip: Drafter.shared.settings.skip)
            guard let s = spot, CFEqual(expected, s.el) else {
                if debugLog { log("after space: \(spot == nil ? why : "another element")") }
                return
            }
            // keys the user typed while the field was read wait in the event tap (this runs on its thread), so backspaces
            // posted now would land after them ("tommorow and" became "ttomorrow nd", 2026-11-01): let them through
            // first and act only if there were none
            func settled(_ go: @escaping () -> Void) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                    guard Keys.shared.inputRevision == revision, !IsSecureEventInputEnabled() else {
                        if debugLog { log("after space: the user typed on") }; return
                    }
                    go()
                }
            }
            if let match = SnippetRules.exact(s.before, snippets: all, replacements: replacements) {
                settled { expand(old: match.old, new: match.new, key: match.key, expected: s) }
                return
            }
            if let w = Typography.decide(s, key: " ") {   // " - " -> " — ", N грн -> N ₴, і в у з а о + no-break space
                settled { Typography.write(w, key: " ", at: s, t0: t0) }
                return
            }
            let st = Drafter.shared.settings
            if st.autocorrect || st.layoutFix, !IsSecureEventInputEnabled(),
               let fix = Autocorrect.check(s.before, layout: st.layoutFix, typos: st.autocorrect, typosUk: st.autocorrectUk, ranked: st.typoEngine == "ranked",
                                           app: s.app.bundleIdentifier ?? "", appKind: AppKind.of(s.app.bundleIdentifier ?? "", title: s.title, ai: Keys.aiApps, chats: Keys.chatApps, browsers: Keys.browsers, aiTitle: Keys.aiTitle)) {
                settled { Autocorrect.apply(fix, at: s) }
                return
            }
            if !s.before.hasSuffix(" "), !s.before.hasSuffix("\u{A0}"), Date().timeIntervalSince(t0) < 0.2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { look() }
            } else if debugLog, !s.before.hasSuffix(" "), !s.before.hasSuffix("\u{A0}") {
                log("after space: no space before the caret after 0.2 s (last \(s.before.unicodeScalars.last.map { String($0.value, radix: 16) } ?? "-"))")
            }
        }
        look()
    }
}
