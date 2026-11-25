// The names reference's pure rules (2026-11-15): his edits on the Names page (spell, merge, hide) and the search.
// The twin of engine/names.py apply_edits; tests/names_cases.json holds the golden cases both sides run
// (tests/name_rules.swift). Entries stay JSON dictionaries so a field this side does not know is kept as it was.
import Foundation

enum NameRules {
    typealias Entry = [String: Any]

    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func str(_ e: Entry, _ k: String) -> String { e[k] as? String ?? "" }
    static func list(_ e: Entry, _ k: String) -> [String] { e[k] as? [String] ?? [] }

    /// Canonical names and short forms (engine/names.py labels).
    static func labels(_ e: Entry) -> [String] { ([str(e, "uk"), str(e, "latin")] + list(e, "short")).filter { !$0.isEmpty } }
    static func display(_ e: Entry) -> String { str(e, "uk").isEmpty ? str(e, "latin") : str(e, "uk") }

    static func addUnique(_ into: [String], _ values: [String], folded: Bool = true) -> [String] {
        var out = into
        var seen = Set(out.map { folded ? fold($0) : $0 })
        for v in values where !v.isEmpty {
            let k = folded ? fold(v) : v
            if !seen.contains(k) { out.append(v); seen.insert(k) }
        }
        return out
    }

    /// His edits in order, on entries in store order. spell {op, id, uk?, latin?}: the old spelling becomes a
    /// mishearing; merge {op, id, into}: names, handles, context and links go to `into`, links to `id` move there;
    /// hide {op, id, on}. An edit whose entry is gone does nothing. -> the number applied.
    @discardableResult
    static func apply(_ entries: inout [Entry], _ edits: [Entry]) -> Int {
        var n = 0
        for ed in edits {
            guard let op = ed["op"] as? String, let id = ed["id"] as? String, let i = entries.firstIndex(where: { str($0, "id") == id }) else { continue }
            var e = entries[i]
            switch op {
            case "spell":
                for field in ["uk", "latin"] where ed[field] != nil {
                    let new = (ed[field] as? String ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    let old = str(e, field)
                    guard !new.isEmpty, new != old else { continue }
                    var heard = list(e, "heard")
                    if !old.isEmpty { heard = addUnique(heard, [old]) }
                    e[field] = new
                    e["heard"] = heard.filter { fold($0) != fold(new) }
                    e["auto"] = list(e, "auto").filter { $0 != field }
                }
                e["edited"] = true; e.removeValue(forKey: "formed")
                entries[i] = e; n += 1
            case "hide":
                e["hidden"] = ed["on"] as? Bool ?? true
                entries[i] = e; n += 1
            case "kind":
                guard let newKind = ed["kind"] as? String, kinds.contains(newKind) else { continue }
                e["kind"] = newKind
                e["edited"] = true; e.removeValue(forKey: "formed")
                entries[i] = e; n += 1
            case "merge":
                guard let into = ed["into"] as? String, into != id, let j = entries.firstIndex(where: { str($0, "id") == into }) else { continue }
                var t = entries[j]
                var short = list(t, "short")
                for x in labels(e) { short = addUnique(short, [x]) }
                let own = Set([fold(str(t, "uk")), fold(str(t, "latin"))])
                t["short"] = short.filter { !own.contains(fold($0)) }
                for f in ["forms", "heard", "phones", "emails", "sources", "links"] { t[f] = addUnique(list(t, f), list(e, f), folded: false) }
                var c = t["context"] as? [String: Any] ?? [:]
                let o = e["context"] as? [String: Any] ?? [:]
                c["lines"] = (c["lines"] as? Int ?? 0) + (o["lines"] as? Int ?? 0)
                let ids = addUnique(c["chat_ids"] as? [String] ?? [], o["chat_ids"] as? [String] ?? [], folded: false)
                c["chat_ids"] = ids
                c["chats"] = max(c["chats"] as? Int ?? 0, o["chats"] as? Int ?? 0, ids.count)
                var apps = c["apps"] as? [String: Int] ?? [:]
                for (a, k) in o["apps"] as? [String: Int] ?? [:] { apps[a, default: 0] += k }
                c["apps"] = apps
                c["last_seen"] = max(c["last_seen"] as? String ?? "", o["last_seen"] as? String ?? "")
                t["context"] = c
                t["links"] = list(t, "links").filter { $0 != into && $0 != id }
                entries[j] = t
                entries.remove(at: i)
                for k in entries.indices {
                    let me = str(entries[k], "id")
                    var seen = Set<String>(), out: [String] = []
                    for l in list(entries[k], "links") {
                        let to = l == id ? into : l
                        if to != me, seen.insert(to).inserted { out.append(to) }
                    }
                    entries[k]["links"] = out
                }
                n += 1
            default: continue
            }
        }
        return n
    }

    /// Kinds in the order the page shows them, with their glyphs.
    static let kinds = ["person", "project", "company", "place", "term"]
    static func glyph(_ kind: String) -> String {
        ["person": "user", "project": "file", "company": "app-window", "place": "map", "term": "hash"][kind] ?? "hash"
    }
    static func kindTitle(_ kind: String) -> String {
        ["person": "Person", "project": "Project", "company": "Company", "place": "Place", "term": "Term"][kind] ?? kind.capitalized
    }

    /// Sort order for the Names list.
    enum SortMode: String, CaseIterable {
        case weight, recent, alpha
        var title: String {
            switch self {
            case .weight: return "Most used"
            case .recent: return "Recently seen"
            case .alpha: return "A–Z"
            }
        }
    }

    static func entryWeight(_ e: Entry) -> Double {
        if let d = e["weight"] as? Double { return d }
        if let i = e["weight"] as? Int { return Double(i) }
        return 0
    }

    static func entryLastSeen(_ e: Entry) -> String {
        (e["context"] as? [String: Any])?["last_seen"] as? String ?? ""
    }

    static func entryLines(_ e: Entry) -> Int {
        (e["context"] as? [String: Any])?["lines"] as? Int ?? 0
    }

    static func entryChats(_ e: Entry) -> Int {
        (e["context"] as? [String: Any])?["chats"] as? Int ?? 0
    }

    /// Sort filtered entry indices deterministically by weight, recency, or A–Z.
    static func sort(_ indices: [Int], in entries: [Entry], by mode: SortMode) -> [Int] {
        switch mode {
        case .weight:
            return indices.sorted { a, b in
                let wa = entryWeight(entries[a]), wb = entryWeight(entries[b])
                if wa != wb { return wa > wb }
                let da = fold(display(entries[a])), db = fold(display(entries[b]))
                return da != db ? da < db : a < b
            }
        case .recent:
            return indices.sorted { a, b in
                let sa = entryLastSeen(entries[a]), sb = entryLastSeen(entries[b])
                if sa != sb { return sa > sb }
                let wa = entryWeight(entries[a]), wb = entryWeight(entries[b])
                if wa != wb { return wa > wb }
                let da = fold(display(entries[a])), db = fold(display(entries[b]))
                return da != db ? da < db : a < b
            }
        case .alpha:
            return indices.sorted { a, b in
                let da = fold(display(entries[a])), db = fold(display(entries[b]))
                if da != db { return da < db }
                let wa = entryWeight(entries[a]), wb = entryWeight(entries[b])
                return wa != wb ? wa > wb : a < b
            }
        }
    }

    /// Deterministic Ukrainian Cyrillic -> Latin transliteration (KMU 2010 style), lowercased and space-normalized,
    /// so Cyrillic and Latin spellings (e.g. "Олена Коваль" and "Olena Koval") match cleanly.
    static func translitToLatin(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var atWordStart = true
        var lastWasSpace = true
        for ch in s.lowercased() {
            if ch.isWhitespace {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
                atWordStart = true
                continue
            }
            switch ch {
            case "'", "\u{2019}", "\u{02BC}", "`", "ь", "ъ":
                continue
            case "-":
                out.append("-")
                atWordStart = true
                lastWasSpace = false
            case "а": out.append("a"); atWordStart = false; lastWasSpace = false
            case "б": out.append("b"); atWordStart = false; lastWasSpace = false
            case "в": out.append("v"); atWordStart = false; lastWasSpace = false
            case "г": out.append("h"); atWordStart = false; lastWasSpace = false
            case "ґ": out.append("g"); atWordStart = false; lastWasSpace = false
            case "д": out.append("d"); atWordStart = false; lastWasSpace = false
            case "е": out.append("e"); atWordStart = false; lastWasSpace = false
            case "є": out.append(atWordStart ? "ye" : "ie"); atWordStart = false; lastWasSpace = false
            case "ж": out.append("zh"); atWordStart = false; lastWasSpace = false
            case "з": out.append("z"); atWordStart = false; lastWasSpace = false
            case "и": out.append("y"); atWordStart = false; lastWasSpace = false
            case "і": out.append("i"); atWordStart = false; lastWasSpace = false
            case "ї": out.append(atWordStart ? "yi" : "i"); atWordStart = false; lastWasSpace = false
            case "й": out.append(atWordStart ? "y" : "i"); atWordStart = false; lastWasSpace = false
            case "к": out.append("k"); atWordStart = false; lastWasSpace = false
            case "л": out.append("l"); atWordStart = false; lastWasSpace = false
            case "м": out.append("m"); atWordStart = false; lastWasSpace = false
            case "н": out.append("n"); atWordStart = false; lastWasSpace = false
            case "о": out.append("o"); atWordStart = false; lastWasSpace = false
            case "п": out.append("p"); atWordStart = false; lastWasSpace = false
            case "р": out.append("r"); atWordStart = false; lastWasSpace = false
            case "с": out.append("s"); atWordStart = false; lastWasSpace = false
            case "т": out.append("t"); atWordStart = false; lastWasSpace = false
            case "у": out.append("u"); atWordStart = false; lastWasSpace = false
            case "ф": out.append("f"); atWordStart = false; lastWasSpace = false
            case "х": out.append("kh"); atWordStart = false; lastWasSpace = false
            case "ц": out.append("ts"); atWordStart = false; lastWasSpace = false
            case "ч": out.append("ch"); atWordStart = false; lastWasSpace = false
            case "ш": out.append("sh"); atWordStart = false; lastWasSpace = false
            case "щ": out.append("shch"); atWordStart = false; lastWasSpace = false
            case "ю": out.append(atWordStart ? "yu" : "iu"); atWordStart = false; lastWasSpace = false
            case "я": out.append(atWordStart ? "ya" : "ia"); atWordStart = false; lastWasSpace = false
            case "ё": out.append("yo"); atWordStart = false; lastWasSpace = false
            case "ы": out.append("y"); atWordStart = false; lastWasSpace = false
            case "э": out.append("e"); atWordStart = false; lastWasSpace = false
            default:
                out.append(ch)
                atWordStart = false
                lastWasSpace = false
            }
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    private static func hasCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
    }

    private static func phoneKey(_ p: String) -> String? {
        let digits = p.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(9))
    }

    private struct Richness: Comparable {
        let weight: Double
        let lines: Int
        let handles: Int
        let bilingual: Int
        let notCard: Int
        let extras: Int
        let id: String

        static func < (lhs: Richness, rhs: Richness) -> Bool {
            if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
            if lhs.lines != rhs.lines { return lhs.lines < rhs.lines }
            if lhs.handles != rhs.handles { return lhs.handles < rhs.handles }
            if lhs.bilingual != rhs.bilingual { return lhs.bilingual < rhs.bilingual }
            if lhs.notCard != rhs.notCard { return lhs.notCard < rhs.notCard }
            if lhs.extras != rhs.extras { return lhs.extras < rhs.extras }
            return lhs.id > rhs.id
        }
    }

    private static func richness(_ e: Entry) -> Richness {
        let bilingual = (!str(e, "uk").isEmpty && !str(e, "latin").isEmpty) ? 1 : 0
        let notCard = (e["card"] as? Bool ?? false) ? 0 : 1
        let handles = list(e, "phones").count + list(e, "emails").count
        let extras = list(e, "forms").count + list(e, "short").count
        return Richness(weight: entryWeight(e), lines: entryLines(e), handles: handles,
                        bilingual: bilingual, notCard: notCard, extras: extras, id: str(e, "id"))
    }

    struct DuplicateSuggestion: Identifiable, Equatable {
        let id: String
        let sourceId: String
        let targetId: String
        let reason: String
        let score: Int
    }

    /// Detect high-confidence duplicate pairs among non-hidden entries in O(N) using inverted indexes.
    /// Each pair is ordered so `targetId` is the richer entry and `sourceId` appears at most once.
    static func findDuplicates(_ entries: [Entry]) -> [DuplicateSuggestion] {
        var ids: [String] = []
        ids.reserveCapacity(entries.count)
        var rich: [Richness] = []
        rich.reserveCapacity(entries.count)
        var active: [Int] = []
        active.reserveCapacity(entries.count)

        var byEmail: [String: [Int]] = [:]
        var byPhone: [String: [Int]] = [:]
        var byFolded: [String: [Int]] = [:]
        var byTranslit: [String: [(idx: Int, hasCyr: Bool)]] = [:]

        for i in entries.indices {
            let e = entries[i]
            let id = str(e, "id")
            ids.append(id)
            rich.append(richness(e))
            guard !id.isEmpty, !(e["hidden"] as? Bool ?? false) else { continue }
            active.append(i)

            var seenEmail = Set<String>()
            for mail in list(e, "emails") {
                let k = mail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !k.isEmpty, seenEmail.insert(k).inserted { byEmail[k, default: []].append(i) }
            }
            var seenPhone = Set<String>()
            for phone in list(e, "phones") {
                if let k = phoneKey(phone), seenPhone.insert(k).inserted { byPhone[k, default: []].append(i) }
            }
            var seenFold = Set<String>()
            var seenTrans = Set<String>()
            for lab in labels(e) {
                let f = fold(lab)
                if f.count >= 2, seenFold.insert(f).inserted { byFolded[f, default: []].append(i) }
                let t = translitToLatin(lab)
                if t.count >= 4 {
                    let cyr = hasCyrillic(lab)
                    let key = (cyr ? "1:" : "0:") + t
                    if seenTrans.insert(key).inserted { byTranslit[t, default: []].append((i, cyr)) }
                }
            }
        }

        struct Candidate {
            let source: Int
            let target: Int
            let reason: String
            let score: Int
        }
        var bestByPair: [UInt64: Candidate] = [:]
        func pairKey(_ a: Int, _ b: Int) -> UInt64 {
            let lo = UInt64(min(a, b)), hi = UInt64(max(a, b))
            return (lo << 32) | hi
        }
        func record(_ a: Int, _ b: Int, reason: String, score: Int) {
            guard a != b else { return }
            let target = rich[a] >= rich[b] ? a : b
            let source = target == a ? b : a
            let key = pairKey(source, target)
            if let old = bestByPair[key], old.score >= score { return }
            bestByPair[key] = Candidate(source: source, target: target, reason: reason, score: score)
        }

        func harvestBucket(_ bucket: [Int], reason: String, score: Int, cap: Int) {
            guard bucket.count >= 2, bucket.count <= cap else { return }
            guard let best = bucket.max(by: { rich[$0] < rich[$1] }) else { return }
            for i in bucket where i != best { record(i, best, reason: reason, score: score) }
        }

        for bucket in byEmail.values { harvestBucket(bucket, reason: "Same email", score: 100, cap: 50) }
        for bucket in byPhone.values { harvestBucket(bucket, reason: "Same phone", score: 95, cap: 50) }
        for bucket in byFolded.values { harvestBucket(bucket, reason: "Shared name or alias", score: 90, cap: 20) }
        for bucket in byTranslit.values {
            guard bucket.count >= 2, bucket.count <= 20 else { continue }
            var cyrIds = Set<Int>(), latIds = Set<Int>()
            for item in bucket { if item.hasCyr { cyrIds.insert(item.idx) } else { latIds.insert(item.idx) } }
            guard !cyrIds.isEmpty, !latIds.isEmpty else { continue }
            let all = Array(cyrIds.union(latIds))
            guard let best = all.max(by: { rich[$0] < rich[$1] }) else { continue }
            let bestHasCyr = cyrIds.contains(best), bestHasLat = latIds.contains(best)
            for i in all where i != best {
                let cross = (bestHasCyr && latIds.contains(i)) || (bestHasLat && cyrIds.contains(i))
                if cross { record(i, best, reason: "Ukrainian / Latin match", score: 85) }
            }
        }

        let sorted = bestByPair.values.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if rich[a.target] != rich[b.target] { return rich[a.target] > rich[b.target] }
            let sa = ids[a.source], sb = ids[b.source]
            if sa != sb { return sa < sb }
            return ids[a.target] < ids[b.target]
        }

        var mergedInto: [String: String] = [:]
        var targetsUsed = Set<String>()
        var out: [DuplicateSuggestion] = []
        for c in sorted {
            let src = ids[c.source]
            var dst = ids[c.target]
            if mergedInto[src] != nil || targetsUsed.contains(src) { continue }
            while let next = mergedInto[dst] { dst = next }
            guard src != dst else { continue }
            mergedInto[src] = dst
            targetsUsed.insert(dst)
            out.append(DuplicateSuggestion(id: "\(src)->\(dst)", sourceId: src, targetId: dst, reason: c.reason, score: c.score))
        }
        return out
    }

    struct ClutterSuggestion: Identifiable, Equatable {
        let id: String
        let reason: String
    }

    private static func isNoiseStub(_ d: String) -> Bool {
        if d.isEmpty { return true }
        let low = d.lowercased()
        if low.hasPrefix("http://") || low.hasPrefix("https://") || low.hasPrefix("www.") || low.contains("://") { return true }
        if d.hasPrefix("@") { return true }
        if !d.contains(where: \.isLetter) { return true }
        return false
    }

    /// Flag likely junk/mess entries (skips hidden and user-edited entries).
    static func findClutter(_ entries: [Entry]) -> [ClutterSuggestion] {
        var noise: [ClutterSuggestion] = []
        var unused: [ClutterSuggestion] = []
        for e in entries {
            let id = str(e, "id")
            guard !id.isEmpty else { continue }
            if e["hidden"] as? Bool == true || e["edited"] as? Bool == true { continue }
            let d = display(e).trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = entryLines(e), chats = entryChats(e)
            let card = e["card"] as? Bool ?? false
            if (isNoiseStub(d) && lines <= 1) || (d.count <= 2 && !card && lines <= 1) {
                noise.append(ClutterSuggestion(id: id, reason: "Noise / fragment"))
            } else if lines == 0 && chats == 0 && list(e, "phones").isEmpty && list(e, "emails").isEmpty && list(e, "links").isEmpty && !card {
                unused.append(ClutterSuggestion(id: id, reason: "Unused (0 mentions)"))
            }
        }
        return noise + unused
    }

    /// Does the entry answer the search? Words of its names, forms, short forms and mishearings start with it, a whole
    /// name holds it, an email holds it, or (3+ digits) a phone holds the digits.
    static func matches(_ e: Entry, _ query: String) -> Bool {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        if q.isEmpty { return true }
        let names = labels(e) + list(e, "forms") + list(e, "heard")
        if names.contains(where: { fold($0).contains(q) }) { return true }
        if list(e, "emails").contains(where: { fold($0).contains(q) }) { return true }
        let digits = q.filter(\.isNumber)
        if digits.count >= 3, digits.count == q.filter({ !$0.isWhitespace && $0 != "+" && $0 != "-" }).count {
            return list(e, "phones").contains { $0.filter(\.isNumber).contains(digits) }
        }
        return false
    }

    /// The rows the page shows: by kind ("" all, "hidden" the hidden ones), then the search; store order kept.
    static func filter(_ entries: [Entry], kind: String, query: String) -> [Int] {
        entries.indices.filter { i in
            let e = entries[i], hidden = e["hidden"] as? Bool ?? false
            if kind == "hidden" { if !hidden { return false } } else if hidden { return false }
            if !kind.isEmpty, kind != "hidden", str(e, "kind") != kind { return false }
            return matches(e, query)
        }
    }
}
