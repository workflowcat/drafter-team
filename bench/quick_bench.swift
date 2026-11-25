// swiftc -O -parse-as-library app/QuickRead.swift app/DraftCaptureRules.swift app/SearchRules.swift app/SearchIndex.swift app/SearchAdapters.swift app/JournalEngine.swift app/QuickSearch.swift app/Entry.swift app/PictureLookRules.swift app/ClipRules.swift app/QuickRules.swift app/Recording.swift app/Transcript.swift app/CaptureRules.swift bench/quick_bench.swift -o app/build/quick-bench && app/build/quick-bench
// The speed round (15 November 2026): what opening the Quick panel or the window and typing costs, on made-up history
// files of his sizes (typed 3.1 MB, takes 1.7 MB, clipboard 0.7 MB, drafts 0.26 MB) in a temporary folder. Never reads
// data/. Prints numbers only. Compares the whole-file reads (before) with the followed reads (after).
import Foundation

@main
struct QuickBench {
    static func ms(_ f: () -> Void) -> Double { let t = DispatchTime.now().uptimeNanoseconds; f(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
    static func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
    static func f1(_ x: Double) -> String { String(format: "%.1f", x) }

    struct RNG { var s: UInt64; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) } }
    static var rng = RNG(s: 0x5EED_2026_1115)
    static let ukC = Array("бвгджзклмнпрстфхцчшщ"), ukV = Array("аеиіоуяюєї"), enC = Array("bcdfghjklmnprstvwz"), enV = Array("aeiou")
    static var uk: [String] = (0..<6000).map { _ in word(ukC, ukV) }, en: [String] = (0..<6000).map { _ in word(enC, enV) }
    static func word(_ c: [Character], _ v: [Character]) -> String {
        var s = ""; for _ in 0..<(1 + rng.int(3)) { s.append(c[rng.int(c.count)]); s.append(v[rng.int(v.count)]) }; return s
    }
    /// About `bytes` bytes of made-up words, Ukrainian-like or English-like.
    static func text(bytes: Int) -> String {
        let ukr = rng.int(100) < 60
        var s = ""
        while s.utf8.count < bytes { s += (s.isEmpty ? "" : " ") + (ukr ? uk[rng.int(uk.count) * rng.int(uk.count) / uk.count] : en[rng.int(en.count) * rng.int(en.count) / en.count]) }
        return s
    }
    static let apps = ["com.tinyspeck.slackmacgap", "com.apple.Safari", "com.google.Chrome", "ru.keepcoder.Telegram", "com.apple.Notes", "com.automattic.beeper.desktop"]
    static func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n" }

    static func make(_ dir: URL) -> QuickReader.Files {
        let now = Date().timeIntervalSince1970
        func write(_ name: String, _ n: Int, _ make: (Int, Double) -> [String: Any]) -> URL {
            let u = dir.appendingPathComponent(name)
            var s = ""; s.reserveCapacity(n * 900)
            for i in 0..<n { s += line(make(i, now - Double(n - i) * 600)) }
            try! s.write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        // sizes as his files on 15 November (rows, average bytes)
        let typed = write("typed.jsonl", 3450) { _, t in ["t": t, "text": text(bytes: 50 + rng.int(1500)), "app": apps[rng.int(apps.count)]] }
        let drafts = write("drafts.jsonl", 1228) { _, t in ["t": t, "text": text(bytes: 40 + rng.int(250)), "app": apps[rng.int(apps.count)], "t0": t - 30] }
        let takes = write("takes.jsonl", 2972) { _, t in ["t": t, "text": text(bytes: 40 + rng.int(900)), "app": apps[rng.int(apps.count)], "audio": "/nowhere/\(Int(t)).wav"] }
        let clip = write("clipboard.jsonl", 518) { _, t in ["t": t, "text": text(bytes: 20 + rng.int(2600)), "app": apps[rng.int(apps.count)], "kind": "text"] }
        let hidden = dir.appendingPathComponent("drafts-hidden.json")
        try! #"{"hidden":[]}"#.write(to: hidden, atomically: true, encoding: .utf8)
        return QuickReader.Files(clip: clip, typed: typed, drafts: drafts, takes: takes, hidden: hidden)
    }

    static func append(_ u: URL, _ o: [String: Any]) {
        let h = try! FileHandle(forWritingTo: u); h.seekToEndOfFile(); h.write(line(o).data(using: .utf8)!); try! h.close()
    }

    // MARK: before this round, as it was (Quick.readPart and History.read at d78559e), for the "before" numbers

    final class Legacy {
        let files: QuickReader.Files
        var parts: [[QuickItem]] = [[], [], []]
        var folded: [String: [String]] = [:]
        var built: [String: QuickItem] = [:]
        init(_ f: QuickReader.Files) { files = f }
        func historyRead(_ url: URL, last n: Int) -> [[String: Any]] {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let rows = s.split(separator: "\n").suffix(n).reversed().compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            guard url == files.typed || url == files.drafts else { return rows }
            return DraftHide.drop(rows, kind: url == files.drafts ? "draft" : "sent", hidden: DraftHide.load(files.hidden))
        }
        func item(_ kind: QuickKind, _ text: String, _ app: String, _ at: Double) -> QuickItem {
            let k = "\(kind.rawValue)|\(at)|\(app)|\(text)"
            if let it = built[k] { return it }
            let it = QuickItem(kind: kind, text: text, app: app, at: at); built[k] = it; return it
        }
        func clipItem(_ r: [String: Any]) -> QuickItem {
            let text = r["text"] as? String ?? "", app = r["app"] as? String ?? "", at = r["t"] as? Double ?? 0
            let pic = r["clip"] as? String ?? "", ocr = ""
            let k = "c|\(at)|\(app)|\(pic)|\(ocr.count)|\(text)"
            if let it = built[k] { return it }
            let it = QuickItem(kind: .copied, text: text, app: app, at: at, image: r["image"] != nil,
                               clip: (r["kind"] as? String).flatMap(ClipKind.init(rawValue:)), title: r["title"] as? String ?? "",
                               bytes: r["bytes"] as? Int ?? 0, picture: pic, ocr: ocr, rich: r["rich"] as? Bool ?? false)
            built[k] = it; return it
        }
        func read(_ i: Int, max: Int, days: Double, secrets: [NSRegularExpression]) {
            if built.count > 4 * max { built.removeAll() }
            switch i {
            case 0:
                let clipRows = historyRead(files.clip, last: max)
                let pairs: [(t: Double, text: String)] = clipRows.reversed().map {
                    ($0["t"] as? Double ?? 0, ClipRules.dedupeKey(text: $0["text"] as? String ?? "", clip: $0["clip"] as? String))
                }
                let keep = QuickRules.keepClips(pairs, now: Date().timeIntervalSince1970, max: max, days: days) { QuickRules.isSecret($0, secrets) }
                parts[0] = keep.map { k in clipItem(clipRows[clipRows.count - 1 - k]) }
            case 1:
                var f: [String: [String]] = [:]
                parts[1] = TypedList.build(sent: historyRead(files.typed, last: max), drafts: historyRead(files.drafts, last: max / 2))
                    .filter { !$0.text.contains("⟦drafter-test⟧") }
                    .map { e in
                        if !e.drafts.isEmpty { f[e.text] = e.drafts }
                        return item(.typed, e.text, e.app, (e.touched ?? e.when).timeIntervalSince1970)
                    }
                folded = f
            default:
                parts[2] = historyRead(files.takes, last: max).compactMap { r in
                    guard let t = r["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return item(.voice, t, r["app"] as? String ?? "", r["t"] as? Double ?? 0)
                }
            }
        }
    }

    static func main() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quick-bench-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = make(dir)
        for u in [files.typed, files.drafts, files.takes, files.clip] {
            let a = try! FileManager.default.attributesOfItem(atPath: u.path)
            print("file \(u.lastPathComponent): \((a[.size] as! Int) / 1024) KB")
        }
        let secrets = QuickRules.secretRules(QuickRules.defaultSecrets)
        let parts = ["copied", "typed", "voice"]

        for incremental in [false, true] {
            print("\n== \(incremental ? "after: QuickReader (followed reads, digest keys)" : "before: Quick.readPart as at d78559e") ==")
            let r = QuickReader(files, clipText: { _ in "" }), old = Legacy(files)
            let read = { (i: Int) in incremental ? r.read(i, max: 1000, days: 0, secrets: secrets) : old.read(i, max: 1000, days: 0, secrets: secrets) }
            // cold: the first read at start
            for i in 0..<3 { print("cold read \(parts[i]): \(f1(ms { read(i) })) ms") }
            // one sent message / one copy / one take appended, then the refresh after open
            var per: [String: [Double]] = [:]
            for k in 0..<10 {
                let t = Date().timeIntervalSince1970 + Double(k)
                append(files.typed, ["t": t, "text": text(bytes: 300), "app": apps[0]])
                per["typed", default: []].append(ms { read(1) })
                append(files.clip, ["t": t, "text": text(bytes: 200), "app": apps[1], "kind": "text"])
                per["copied", default: []].append(ms { read(0) })
                append(files.takes, ["t": t, "text": text(bytes: 200), "app": apps[2]])
                per["voice", default: []].append(ms { read(2) })
            }
            for p in parts { print("refresh after one new \(p) row: p50 \(f1(pct(per[p]!, 0.5))) ms, max \(f1(per[p]!.max()!)) ms") }
            if incremental { print("typed: last read \(r.typed.last.full ? "whole" : "appended"), \(r.typed.last.bytes) bytes") }
            let same = (incremental ? r.parts : old.parts).map(\.count)
            print("rows per part: \(same)")
        }

        // the main-thread part after a read: merge, then the search index (built off the main thread in the app)
        print("\n== main thread after a read, and keys ==")
        let r = QuickReader(files, clipText: { _ in "" })
        for i in 0..<3 { r.read(i, max: 1000, days: 0, secrets: secrets) }
        let rows = r.parts.flatMap { $0 }
        var items: [QuickItem] = []
        let merge = (0..<5).map { _ in ms { items = QuickRules.merge(rows, pins: []) } }
        print("rows \(items.count); merge p50 \(f1(pct(merge, 0.5))) ms")
        let search = QuickSearch(); search.inline = true
        let build = (0..<3).map { _ in ms { search.rebuild(items, uses: QuickUses(), now: Date().timeIntervalSince1970) } }
        print("index build (off main in the app): p50 \(f1(pct(build, 0.5))) ms")
        // typing a query a letter at a time: every key runs filter on the main thread
        let now = Date().timeIntervalSince1970
        let words = (0..<20).map { _ in rows[rng.int(rows.count)].text.split(separator: " ").first.map(String.init) ?? "a" }
        var keys: [Double] = [], plain: [Double] = []
        for w in words {
            var q = ""
            for ch in w + " " + (words.randomElement() ?? "") {
                q.append(ch)
                keys.append(ms { _ = search.filter(items, query: q, kind: nil, uses: QuickUses(), now: now) })
                plain.append(ms { _ = QuickRules.filter(items, query: q, kind: nil, uses: QuickUses(), now: now) })
            }
        }
        print("key -> filtered list (index + plain), \(keys.count) keys: p50 \(f1(pct(keys, 0.5))) ms, p90 \(f1(pct(keys, 0.9))) ms, max \(f1(keys.max()!)) ms")
        print("  of which the plain match: p50 \(f1(pct(plain, 0.5))) ms, max \(f1(plain.max()!)) ms")
        // a new row arrives while the panel is open: the index for the old rows keeps answering
        let more = QuickRules.merge([QuickItem(kind: .typed, text: text(bytes: 200), app: apps[0], at: now)] + rows, pins: [])
        search.inline = false
        search.rebuild(more, uses: QuickUses(), now: now)
        let during = search.filter(more, query: words[0], kind: nil, uses: QuickUses(), now: now)
        let alone = QuickRules.filter(more, query: words[0], kind: nil, uses: QuickUses(), now: now)
        print("while the new index builds: \(search.ready ? "new index" : search.answering ? "old index answers" : "plain match only") (\(during.count) rows; plain alone \(alone.count))")

        // the window's reload: the three files read whole on the main thread (before) or followed (after)
        print("\n== window reload (main thread before this round) ==")
        for incremental in [false, true] {
            let fs = [JSONLFollow(files.takes, keep: 500), JSONLFollow(files.clip, keep: 300), JSONLFollow(files.typed, keep: 600), JSONLFollow(files.drafts, keep: 600)]
            fs.forEach { $0.incremental = incremental }
            let cold = ms { fs.forEach { $0.refresh() } }
            append(files.typed, ["t": now + 100, "text": text(bytes: 300), "app": apps[0]])
            let again = ms { fs.forEach { $0.refresh() } }
            let build = ms { _ = TypedList.build(sent: fs[2].newest(600), drafts: fs[3].newest(600)) }
            print("\(incremental ? "after " : "before"): read cold \(f1(cold)) ms, next open after one message \(f1(again)) ms, TypedList.build \(f1(build)) ms")
        }
    }
}
