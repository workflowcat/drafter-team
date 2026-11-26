// swiftc -O -parse-as-library app/SearchRules.swift app/SearchIndex.swift app/SearchAdapters.swift app/JournalEngine.swift app/QuickSearch.swift app/Entry.swift app/PictureLookRules.swift app/ClipRules.swift app/QuickRules.swift app/Recording.swift app/Transcript.swift app/CaptureRules.swift bench/search_bench.swift -o app/build/search-bench
// app/build/search-bench speed [docs]   generated made-up text in both languages: build time, memory, query times
// app/build/search-bench real           the user's stores under data/, read only: known-item test against today's search
// Prints numbers only. Writes only data/bench/search/*.json (numbers only). Loads no model.
import Foundation

@main
struct SearchBench {
    static func main() {
        let args = CommandLine.arguments
        switch args.count > 1 ? args[1] : "speed" {
        case "real": real()
        default: speed(args.count > 2 ? Int(args[2]) ?? 50_000 : 50_000)
        }
    }

    // MARK: helpers

    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
    /// The checkout this file sits in (bench/..): its data/ folder is read, data/bench/search/ written.
    static let root = ProcessInfo.processInfo.environment["DRAFTER_HOME"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()   // a worktree: DRAFTER_HOME=<main checkout>
    static func ms(_ f: () -> Void) -> Double { let t = DispatchTime.now().uptimeNanoseconds; f(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
    static func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
    static func f1(_ x: Double) -> String { String(format: "%.1f", x) }
    static func f2(_ x: Double) -> String { String(format: "%.2f", x) }

    struct RNG { var s: UInt64; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 } }

    static func write(_ name: String, _ obj: [String: Any]) {
        let dir = root.appendingPathComponent("data/bench/search")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent(name))
        }
    }

    // MARK: generated text

    struct Gen {
        var rng = RNG(s: 0x5EED_2026_1114)
        var uk: [String] = [], en: [String] = [], names: [String] = []
        var cum: [Double] = []
        static let ukC = Array("бвгджзклмнпрстфхцчшщ"), ukV = Array("аеиіоуяюєї")
        static let enC = Array("bcdfghjklmnprstvwz"), enV = Array("aeiou")
        static let ukEnd = ["", "", "а", "у", "ом", "і", "ами", "ів", "ою", "ий", "ого", "ти", "ла"]
        static let enEnd = ["", "", "", "s", "ing", "ed", "er"]

        mutating func word(_ c: [Character], _ v: [Character], _ syl: Int) -> String {
            var s = ""; for _ in 0..<syl { s.append(c[rng.int(c.count)]); s.append(v[rng.int(v.count)]) }
            s.append(c[rng.int(c.count)]); return s
        }
        init() {
            for _ in 0..<22_000 { uk.append(word(Self.ukC, Self.ukV, 1 + rng.int(3))) }
            for _ in 0..<16_000 { en.append(word(Self.enC, Self.enV, 1 + rng.int(3))) }
            for _ in 0..<300 { names.append(word(Self.enC, Self.enV, 2).capitalized) }
            // Zipf over ranks
            var acc = 0.0; cum = (1...22_000).map { acc += 1 / pow(Double($0), 1.05); return acc }
        }
        mutating func rank(_ n: Int) -> Int {
            let x = rng.unit() * cum[n - 1]
            var lo = 0, hi = n - 1
            while lo < hi { let m = (lo + hi) / 2; if cum[m] < x { lo = m + 1 } else { hi = m } }
            return lo
        }
        mutating func token(_ lang: Int) -> String {
            let l = lang == 2 ? rng.int(2) : lang
            if l == 0 { return uk[rank(uk.count)] + Self.ukEnd[rng.int(Self.ukEnd.count)] }
            return en[rank(en.count)] + Self.enEnd[rng.int(Self.enEnd.count)]
        }
        mutating func text(_ words: Int) -> String {
            let lang = rng.int(100) < 55 ? 0 : rng.int(100) < 67 ? 1 : 2
            var out: [String] = []; out.reserveCapacity(words)
            for i in 0..<words {
                var w = token(lang)
                if i == 0 || rng.int(12) == 0 { w = w.capitalized }
                out.append(w)
                if rng.int(11) == 0 { out[out.count - 1] += rng.int(3) == 0 ? ",\n" : "." }
            }
            return out.joined(separator: " ")
        }
        mutating func docs(_ n: Int, now: Double) -> [SearchDoc] {
            var out: [SearchDoc] = []; out.reserveCapacity(n)
            let apps = ["Telegram", "Google Chrome", "Notes", "Mail", "Slack", "Claude", "Safari", "Xcode", "Beeper", "Finder"]
            for i in 0..<n {
                let t = now - Double(rng.int(400 * 86400))
                let app = apps[rng.int(apps.count)]
                let r = rng.int(1000)
                var d: SearchDoc
                if r < 10 {   // 1 %: a call or long note
                    d = SearchDoc(id: "g\(i)", kind: .recording, time: t, app: app)
                    d.recTitle = text(3 + rng.int(4)); d.summary = text(50 + rng.int(100))
                    d.transcript = text(2000 + rng.int(7000)); d.tags = (0..<(1 + rng.int(3))).map { _ in names[rng.int(names.count)] + " " + names[rng.int(names.count)] }
                } else if r < 460 {   // copies
                    let s = rng.int(100)
                    if s < 10 {
                        let u = "https://www.\(token(1)).com/\(token(1))/\(token(1))-\(token(1))?utm_source=x"
                        d = SearchDoc.text(id: "g\(i)", kind: .clip, time: t, app: app, text: u); d.link = token(1) + ".com " + text(4)
                    } else if s < 15 {
                        d = SearchDoc(id: "g\(i)", kind: .clip, time: t, app: app); d.picture = true; d.ocr = text(20 + rng.int(130))
                    } else { d = SearchDoc.text(id: "g\(i)", kind: .clip, time: t, app: app, text: text(3 + rng.int(40))) }
                } else if r < 760 { d = SearchDoc.text(id: "g\(i)", kind: .draft, time: t, app: app, text: text(5 + rng.int(115)))
                } else { d = SearchDoc.text(id: "g\(i)", kind: .voice, time: t, app: app, text: text(10 + rng.int(190))) }
                if rng.int(200) == 0 { d.pinned = true }
                if rng.int(20) == 0 { d.uses = Double(rng.int(6)) }
                out.append(d)
            }
            return out
        }
    }

    static func typo(_ w: String, _ rng: inout RNG) -> String {
        var c = Array(w)
        guard c.count >= 5 else { return w }
        let i = 1 + rng.int(c.count - 3)
        switch rng.int(3) {
        case 0: c.swapAt(i, i + 1)
        case 1: c.remove(at: i)
        default: c[i] = c[i] == "a" ? "e" : c[i] == "а" ? "о" : (c[i].unicodeScalars.first!.value > 0x400 ? "а" : "a")
        }
        return String(c)
    }
    static func wrongLayout(_ q: String) -> String {
        String(q.lowercased().map { ch in SearchRules.toEn[ch] ?? SearchRules.toUk[ch] ?? ch })
    }

    // MARK: speed

    static func speed(_ n: Int) {
        let now = Date().timeIntervalSince1970
        let clock = SearchClock(now: now)
        let m0 = footprint()
        var gen = Gen()
        let docs = gen.docs(n, now: now)
        let chars = docs.reduce(0) { $0 + $1.title.utf16.count + $1.body.utf16.count + $1.ocr.utf16.count + $1.link.utf16.count + $1.transcript.utf16.count + $1.summary.utf16.count + $1.recTitle.utf16.count }
        let m1 = footprint()
        var nTok = 0
        let scanOnly = ms { for d in docs { for f in SearchField.allCases { let t = d.field(f); if !t.isEmpty { SearchRules.scanBytes(t) { _, _, _, _ in nTok += 1; return true } } } } }
        print("scan only: \(f1(scanOnly)) ms, \(nTok) words")
        let ix = SearchIndex()
        let build = ms { ix.add(docs) }
        malloc_zone_pressure_relief(nil, 0)
        let m2 = footprint()
        let prep = ms { ix.prepare() }
        let m3 = footprint()
        print("docs \(n) · text \(chars / 1_000_000) M UTF-16 units · vocabulary \(ix.vocabularySize) words")
        print("build \(f1(build)) ms (+ typo filter and sorted words \(f1(prep)) ms) · total \(f1(build + prep)) ms")
        print("index parts (MB): " + ix.sizeReport().map { "\($0.0) \(f1(Double($0.1) / 1_048_576))" }.joined(separator: " · "))
        print("memory: documents \(f1(m1 - m0)) MB · index \(f1(m3 - m1)) MB footprint (\(f1(m2 - m1)) after add, estimate \(f1(Double(ix.indexBytes()) / 1_048_576)) MB)")

        var rng = RNG(s: 42)
        func pickWords(_ k: Int) -> [String] {
            while true {
                let d = docs[rng.int(docs.count)]
                let text = [d.title, d.body, d.ocr, d.summary, String(d.transcript.prefix(3000))].joined(separator: " ")
                let ws = text.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }.filter { $0.count >= 4 }
                if ws.count >= k { let s = rng.int(ws.count - k + 1); return Array(ws[s..<(s + k)]) }
            }
        }
        var sets: [(String, [String])] = []
        sets.append(("1 word", (0..<300).map { _ in pickWords(1)[0] + " " }))
        sets.append(("2 words", (0..<300).map { _ in pickWords(2).joined(separator: " ") + " " }))
        var typing: [String] = []
        for _ in 0..<60 { let q = pickWords(2).joined(separator: " "); for i in 1...q.count { typing.append(String(q.prefix(i))) } }
        sets.append(("typing, every key", typing))
        sets.append(("wrong layout", (0..<300).map { _ in wrongLayout(pickWords(2).joined(separator: " ")) }))
        sets.append(("one typo", (0..<300).map { _ in let w = pickWords(2); return w[0] + " " + typo(w[1], &rng) }))
        sets.append(("\"phrase\"", (0..<200).map { _ in "\"" + pickWords(2).joined(separator: " ") + "\"" }))
        if CommandLine.arguments.contains("probe") {
            // the slowest phrases: the phrase query against the same words without quotes (made-up text, numbers only)
            var rows: [(Double, Double, Int, Int)] = []
            for q in sets.last!.1 {
                var a = 0, b = 0
                let tp = ms { a = ix.search(q, clock: clock, options: SearchOptions(limit: 200))!.hits.count }
                let tw = ms { b = ix.search(q.replacingOccurrences(of: "\"", with: "") + " ", clock: clock, options: SearchOptions(limit: 100_000, detail: 0))!.hits.count }
                rows.append((tp, tw, a, b))
            }
            for r in rows.sorted(by: { $0.0 > $1.0 }).prefix(12) { print("phrase \(f1(r.0)) ms · same words \(f1(r.1)) ms · phrase hits \(r.2) · word hits \(r.3)") }
            return
        }
        let common = (0..<30).map { gen.uk[$0] }
        sets.append(("common word", common.map { $0 + " " }))
        sets.append(("common prefix (2 letters)", common.map { String($0.prefix(2)) }))
        sets.append(("filters only", ["kind:voice in:last-week", "has:picture", "kind:recording", "in:this-month app:chrome", "is:pinned"]))
        var all: [Double] = []
        var lines: [[String: Any]] = []
        print("\n| queries | n | p50 ms | p95 ms | max ms | hits p50 |")
        print("|---|---|---|---|---|---|")
        for (name, qs) in sets {
            var t: [Double] = [], h: [Double] = []
            for q in qs {
                var r: SearchResult?
                t.append(ms { r = ix.search(q, clock: clock, options: SearchOptions(limit: 200)) })
                h.append(Double(r?.hits.count ?? 0))
            }
            all += t
            print("| \(name) | \(t.count) | \(f2(pct(t, 0.5))) | \(f2(pct(t, 0.95))) | \(f2(t.max() ?? 0)) | \(Int(pct(h, 0.5))) |")
            lines.append(["set": name, "n": t.count, "p50": pct(t, 0.5), "p95": pct(t, 0.95), "max": t.max() ?? 0])
        }
        print("| all | \(all.count) | \(f2(pct(all, 0.5))) | \(f2(pct(all, 0.95))) | \(f2(all.max() ?? 0)) | |")
        // incremental: 1,000 more, one at a time
        let more = gen.docs(1000, now: now)
        var adds: [Double] = []
        for d in more { adds.append(ms { ix.add([d]) }) }
        var after: [Double] = []
        for q in sets[1].1.prefix(100) { after.append(ms { _ = ix.search(q, clock: clock) }) }
        print("\nadd one document: p50 \(f2(pct(adds, 0.5))) ms, p95 \(f2(pct(adds, 0.95))) ms · 2-word queries after 1,000 adds: p95 \(f2(pct(after, 0.95))) ms")
        write("speed.json", ["docs": n, "build_ms": build, "prepare_ms": prep, "index_mb": m3 - m1, "estimate_mb": Double(ix.indexBytes()) / 1_048_576,
                             "vocabulary": ix.vocabularySize, "p95_all": pct(all, 0.95), "sets": lines, "add_p95": pct(adds, 0.95)])
    }

    // MARK: real data, known-item test

    struct Item { let doc: SearchDoc; let sig: Int; let quick: QuickItem; let hay: String; let words: [String] }

    static func real() {
        let data = root.appendingPathComponent("data")
        func rows(_ f: String) -> [[String: Any]] {
            guard let s = try? String(contentsOf: data.appendingPathComponent(f), encoding: .utf8) else { return [] }
            return s.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var docs: [SearchDoc] = [], quick: [QuickItem] = []
        // copies (newest of each text, as the window shows them)
        var seen = Set<String>()
        for (i, r) in rows("clipboard.jsonl").enumerated().reversed() {
            let text = r["text"] as? String ?? ""
            let clipName = r["clip"] as? String ?? ""
            guard !text.isEmpty, seen.insert(text + "\u{1}" + clipName).inserted else { continue }
            var e = Entry(id: "c\(i)", when: Date(timeIntervalSince1970: r["t"] as? Double ?? 0), app: r["app"] as? String ?? "", text: text, audio: "")
            e.clip = ClipKind(rawValue: r["kind"] as? String ?? "text") ?? .text
            e.clipTitle = r["title"] as? String ?? ""
            if !clipName.isEmpty { e.ocr = (try? String(contentsOf: data.appendingPathComponent("clips/" + clipName + ".txt"), encoding: .utf8)) ?? "" }
            docs.append(JournalEngine.doc(id: e.id, kind: .clip, at: e.when.timeIntervalSince1970, app: e.app, line: text, entry: e, call: nil, change: nil, pinned: false))
            quick.append(QuickItem(kind: .copied, text: text, app: e.app, at: e.when.timeIntervalSince1970, clip: e.clip, title: e.clipTitle, ocr: e.ocr))
        }
        for r in rows("takes.jsonl") {
            guard let e = Entry.voice(r, audioExists: { _ in false }), !e.audioOnly else { continue }
            docs.append(JournalEngine.doc(id: "v:" + e.id, kind: .voice, at: e.when.timeIntervalSince1970, app: e.app, line: e.text, entry: e, call: nil, change: nil, pinned: false))
            quick.append(QuickItem(kind: .voice, text: e.text.isEmpty ? e.raw : e.text, app: e.app, at: e.when.timeIntervalSince1970))
        }
        for e in TypedList.build(sent: rows("typed.jsonl"), drafts: rows("drafts.jsonl")) {
            docs.append(JournalEngine.doc(id: "t:" + e.id, kind: .draft, at: (e.touched ?? e.when).timeIntervalSince1970, app: e.app, line: e.text, entry: e, call: nil, change: nil, pinned: false))
            quick.append(QuickItem(kind: .typed, text: e.text, app: e.app, at: (e.touched ?? e.when).timeIntervalSince1970))
        }
        let notes = CallDoc.notesIndex(data.appendingPathComponent("notes"))
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: data.appendingPathComponent("calls"), includingPropertiesForKeys: nil)) ?? []).filter(\.hasDirectoryPath)
        for c in dirs.map({ CallDoc.load($0, notes: notes) }) where !c.turns.isEmpty {
            let d = JournalEngine.doc(id: "d:" + c.id, kind: .recording, at: c.started.timeIntervalSince1970, app: c.app, line: c.title, entry: nil, call: c, change: nil, pinned: false)
            docs.append(d)
            quick.append(QuickItem(kind: .typed, text: [d.recTitle, d.summary, d.transcript].joined(separator: "\n"), app: c.app, at: d.time))
        }
        let readMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let counts = Dictionary(grouping: docs, by: \.kind).mapValues(\.count)
        print("documents \(docs.count) (clip \(counts[.clip] ?? 0), draft \(counts[.draft] ?? 0), voice \(counts[.voice] ?? 0), recording \(counts[.recording] ?? 0)) · read \(f1(readMs)) ms")

        let ix = SearchIndex()
        let build = ms { ix.add(docs); ix.prepare() }
        print("build \(f1(build)) ms · vocabulary \(ix.vocabularySize)")

        // the text each document holds, the window's way (lower case, every field), and its candidate words
        func all(_ d: SearchDoc) -> String { [d.title, d.body, d.link, d.ocr, d.app, d.recTitle, d.tags.joined(separator: " "), d.summary, d.transcript].joined(separator: "\n") }
        var df: [String: Int] = [:]
        var items: [Item] = []
        for (i, d) in docs.enumerated() {
            let text = all(d)
            let body = [d.title, d.body, d.ocr, d.link, d.recTitle, d.summary, String(d.transcript.prefix(6000))].joined(separator: " ")
            let ws = body.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "’") }).map { $0.lowercased() }
                .filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) }
            var uniq: [String] = []; var s = Set<String>()
            for w in ws where s.insert(w).inserted { uniq.append(w) }
            for t in Set(SearchRules.terms(body)) { df[t, default: 0] += 1 }
            items.append(Item(doc: d, sig: text.hashValue, quick: quick[i], hay: text.lowercased(), words: uniq))
        }
        var rng = RNG(s: 0xD0C5)
        let pool = items.indices.filter { items[$0].words.count >= 2 }
        var sample: [Int] = []
        var pickSet = Set<Int>()
        while sample.count < min(300, pool.count) { let k = pool[rng.int(pool.count)]; if pickSet.insert(k).inserted { sample.append(k) } }

        func rare2(_ it: Item) -> [String] {
            let scored = it.words.map { w -> (String, Int) in (w, SearchRules.terms(w).first.map { df[$0] ?? 1 } ?? 1) }
            let two = scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.prefix(2).map(\.0)
            return it.words.filter { two.contains($0) }   // in the document's order
        }
        func form(_ w: String) -> String? {
            let c = Array(w)
            guard let l = c.last else { return nil }
            if SearchRules.isCyrillic(SearchRules.terms(w).first ?? "") {
                if "аяоеиіую".contains(l) { return String(c.dropLast()) + (l == "і" ? "у" : "і") }
                if "йь".contains(l) { return nil }
                return w + "у"
            }
            if w.hasSuffix("s") { return String(c.dropLast()) }
            return w + "s"
        }
        let now = Date().timeIntervalSince1970
        let clock = SearchClock(now: now)
        let nowFull = QuickRules.merge(quick, pins: [])   // not used for order; QuickRules.filter takes the list as given
        _ = nowFull
        let quickSorted = items.indices.sorted { items[$0].quick.at > items[$1].quick.at }
        let quickList = quickSorted.map { items[$0].quick }
        let windowOrder = items.indices.sorted { items[$0].doc.time > items[$1].doc.time }

        func rankNew(_ q: String, _ target: Int) -> Int? {
            guard let r = ix.search(q, clock: clock, options: SearchOptions(limit: 3, detail: 0)) else { return nil }
            return r.hits.firstIndex { items[$0.doc].sig == items[target].sig }
        }
        func rankWindow(_ q: String, _ target: Int) -> Int? {
            let ws = q.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            var k = 0
            for i in windowOrder where ws.allSatisfy({ items[i].hay.contains($0) }) {
                if items[i].sig == items[target].sig { return k }
                k += 1; if k >= 3 { return nil }
            }
            return nil
        }
        func rankQuick(_ q: String, _ target: Int) -> Int? {
            let idx = QuickRules.filter(quickList, query: q, kind: nil, uses: QuickUses(), now: now)
            for (k, j) in idx.prefix(3).enumerated() where items[quickSorted[j]].sig == items[target].sig { return k }
            return nil
        }

        // THE WIRED PATHS: the journal's engine (its own queue, as the window runs it) and the Quick panel's search
        let uses = (try? Data(contentsOf: data.appendingPathComponent("quick-stats.json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.map(QuickUses.init) ?? QuickUses()
        let back = DispatchQueue(label: "bench.callback")
        let eng = JournalEngine()
        eng.callback = back
        let byTime = windowOrder.map { docs[$0] }   // the journal's rows, newest first
        let ready = DispatchSemaphore(value: 0)
        eng.onReady = { ready.signal() }
        let coldT0 = DispatchTime.now().uptimeNanoseconds
        eng.update(version: 1, count: byTime.count, id: { byTime[$0].id }, sig: { _ in 1 }, doc: { byTime[$0] })
        var coldFirst = 0.0
        do {
            let got = DispatchSemaphore(value: 0)
            eng.search("a") { _ in coldFirst = Double(DispatchTime.now().uptimeNanoseconds - coldT0) / 1e6; got.signal() }
            got.wait(); ready.wait()
        }
        print("journal engine: cold build \(f1(eng.buildMs)) ms (documents, words, prepare) · open to first answer \(f1(coldFirst)) ms")
        var journalMs: [Double] = []
        var sigOf: [String: Int] = [:]
        for (i, d) in docs.enumerated() { sigOf[d.id] = items[i].sig }
        func rankJournal(_ q: String, _ target: Int) -> Int? {
            let got = DispatchSemaphore(value: 0)
            var hits: [SearchHit] = []
            let t0 = DispatchTime.now().uptimeNanoseconds
            eng.search(q) { r in hits = r.hits; got.signal() }
            got.wait()
            journalMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            return hits.prefix(3).firstIndex { sigOf[$0.id] == items[target].sig }
        }
        let qs = QuickSearch()
        qs.inline = true
        qs.rebuild(quickList, uses: uses, now: now)
        print("quick search: index for \(quickList.count) rows built in \(f1(qs.buildMs)) ms (off the main thread in the app)")
        var quickOld: [Double] = [], quickNew: [Double] = []
        func rankQuickWired(_ q: String, _ target: Int) -> Int? {
            var idx: [Int] = []
            // every key as the user types it: the plain filter (before) and the wired one (after), same rows, same puts
            for i in 1...q.count {
                let part = String(q.prefix(i))
                quickOld.append(Self.ms { _ = QuickRules.filter(quickList, query: part, kind: nil, uses: uses, now: now) })
                quickNew.append(Self.ms { idx = qs.filter(quickList, query: part, kind: nil, uses: uses, now: now) })
            }
            for (k, j) in idx.prefix(3).enumerated() where items[quickSorted[j]].sig == items[target].sig { return k }
            return nil
        }

        struct Score { var n = 0, top1 = 0, top3 = 0 }
        let variants = ["as typed", "one typo", "wrong layout", "other case form or plural"]
        var res: [String: [String: Score]] = [:]
        var ms: [Double] = []
        var typoMiss: [String: Int] = [:]
        for t in sample {
            let w = rare2(items[t])
            guard w.count == 2 else { continue }
            var qs: [String: String] = ["as typed": w.joined(separator: " ")]
            if let li = w.indices.max(by: { w[$0].count < w[$1].count }), w[li].count >= 5 {
                var v = w; v[li] = typo(w[li], &rng); if v != w { qs["one typo"] = v.joined(separator: " ") }
            }
            let wl = wrongLayout(w.joined(separator: " "))
            if wl != w.joined(separator: " ") { qs["wrong layout"] = wl }
            if let f = form(w[1]) { qs["other case form or plural"] = w[0] + " " + f }
            for (v, q) in qs {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let a = rankNew(q, t)
                if v == "one typo", a == nil {
                    let typoed = q.split(separator: " ").map(String.init).first { !w.contains($0) } ?? ""
                    let n = SearchRules.terms(typoed).first?.unicodeScalars.count ?? 0
                    typoMiss[n < 5 ? "under 5 letters after the typo" : ix.search(q, clock: clock, options: SearchOptions(limit: 1000, detail: 0))!.hits.isEmpty ? "not found at all" : "found below 3rd", default: 0] += 1
                }
                ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                let b = rankWindow(q, t), c = rankQuick(q, t), jw = rankJournal(q, t), qw = rankQuickWired(q, t)
                for (name, r) in [("new", a), ("window", b), ("quick", c), ("journal wired", jw), ("quick wired", qw)] {
                    var s = res[v, default: [:]][name, default: Score()]
                    s.n += 1; if r == 0 { s.top1 += 1 }; if let r, r < 3 { s.top3 += 1 }
                    res[v, default: [:]][name] = s
                }
            }
        }
        func p(_ a: Int, _ n: Int) -> String { n == 0 ? "-" : "\(Int((100 * Double(a) / Double(n)).rounded())) %" }
        print("\nknown-item test: \(sample.count) documents, query = 2 of its rarer words\n")
        print("| query | n | new top 1 | new top 3 | window top 1 | window top 3 | Quick top 1 | Quick top 3 |")
        print("|---|---|---|---|---|---|---|---|")
        var out: [String: Any] = ["documents": docs.count, "sample": sample.count, "build_ms": build, "query_p95_ms": pct(ms, 0.95)]
        for v in variants {
            guard let r = res[v] else { continue }
            let a = r["new"]!, b = r["window"]!, c = r["quick"]!
            print("| \(v) | \(a.n) | \(p(a.top1, a.n)) | \(p(a.top3, a.n)) | \(p(b.top1, b.n)) | \(p(b.top3, b.n)) | \(p(c.top1, c.n)) | \(p(c.top3, c.n)) |")
            out[v] = ["n": a.n, "new1": a.top1, "new3": a.top3, "window1": b.top1, "window3": b.top3, "quick1": c.top1, "quick3": c.top3]
        }
        print("\nthrough the wired paths (same items, same queries)\n")
        print("| query | n | journal top 1 | journal top 3 | Quick top 1 | Quick top 3 | window today top 3 | Quick today top 3 |")
        print("|---|---|---|---|---|---|---|---|")
        for v in variants {
            guard let r = res[v] else { continue }
            let a = r["journal wired"]!, b = r["quick wired"]!, w = r["window"]!, c = r["quick"]!
            print("| \(v) | \(a.n) | \(p(a.top1, a.n)) | \(p(a.top3, a.n)) | \(p(b.top1, b.n)) | \(p(b.top3, b.n)) | \(p(w.top3, w.n)) | \(p(c.top3, c.n)) |")
            out["wired " + v] = ["n": a.n, "journal1": a.top1, "journal3": a.top3, "quick1": b.top1, "quick3": b.top3]
        }
        print("\njournal: query to answer on the main thread's callback p50 \(f2(pct(journalMs, 0.5))) ms, p95 \(f2(pct(journalMs, 0.95))) ms, max \(f2(journalMs.max() ?? 0)) ms")
        print("Quick, per key over \(quickList.count) rows: before p50 \(f2(pct(quickOld, 0.5))) / p95 \(f2(pct(quickOld, 0.95))) / max \(f2(quickOld.max() ?? 0)) ms · after p50 \(f2(pct(quickNew, 0.5))) / p95 \(f2(pct(quickNew, 0.95))) / max \(f2(quickNew.max() ?? 0)) ms")
        out["journal_ms_p95"] = pct(journalMs, 0.95); out["journal_cold_ms"] = eng.buildMs; out["journal_open_first_ms"] = coldFirst
        out["quick_before_p95"] = pct(quickOld, 0.95); out["quick_after_p95"] = pct(quickNew, 0.95); out["quick_build_ms"] = qs.buildMs
        print("\ntypo misses (new search, not in top 3): " + typoMiss.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        out["typo_misses"] = typoMiss
        print("\nnew search on the user's data: query p50 \(f2(pct(ms, 0.5))) ms, p95 \(f2(pct(ms, 0.95))) ms")
        write("real.json", out)
    }
}
