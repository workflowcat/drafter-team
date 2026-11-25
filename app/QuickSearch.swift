// The Quick panel's search on the search core (search round two, 14 November 2026). Foundation only: Quick.swift
// calls it, bench/search_bench.swift measures it. The panel opens by a chord and is typed into at once, so nothing
// waits on the index: it is built off the main thread whenever the rows change and queried on the main thread once it
// is in (well under a millisecond at a few thousand rows). Until then, and for an empty query, QuickRules.filter answers
// alone, as before. With the index: the core's order (both languages, stems, the other layout, typos; the learned puts
// from data/quick-stats.json as the small boost of SearchWeights.use), then what only the plain match found (a piece
// inside a word, a number), pins first as always.
import Foundation

final class QuickSearch {
    /// Main thread only, once handed over. Documents carry the item's own id (QuickItem.id), so an index built for
    /// older rows still answers for newer ones (speed round, 15 November 2026: the index was dropped on every new
    /// row, and for its 0.3 s rebuild the order fell back to the plain match and jumped under his keys).
    private var index: SearchIndex?
    /// Main thread: item id -> its row in the items last handed to `rebuild`.
    private var rowOf: [String: Int] = [:]
    private var heldFor = -1
    private var gen = 0
    private let queue = DispatchQueue(label: "drafter.quick-search", qos: .userInitiated)
    /// How long each filter with a query took (main thread), since the last `takeKeyStats`.
    private var keyMs: [Double] = []
    /// The keys typed since the last call: count, median and worst, in ms (nil: none). Numbers only, for the log.
    func takeKeyStats() -> (n: Int, p50: Double, max: Double)? {
        defer { keyMs = [] }
        guard !keyMs.isEmpty else { return nil }
        let s = keyMs.sorted()
        return (s.count, s[s.count / 2], s[s.count - 1])
    }
    /// Previews and tests: the index is built at once, on the calling thread.
    var inline = false
    /// The last build, in ms (on the queue).
    private(set) var buildMs = 0.0
    var ready: Bool { index != nil && heldFor == gen }
    /// An index answers (maybe one built for the rows before the newest ones).
    var answering: Bool { index != nil }

    /// New rows: the old index keeps answering (rows it does not know come from the plain match) while a new one is
    /// built off the main thread. `done` runs on the main thread when it is in.
    func rebuild(_ items: [QuickItem], uses: QuickUses, now: Double, done: (() -> Void)? = nil) {
        gen += 1
        let g = gen
        var m = [String: Int](minimumCapacity: items.count)
        for (i, it) in items.enumerated() where m[it.id] == nil { m[it.id] = i }
        rowOf = m
        let make = { () -> (SearchIndex, Double) in
            let t0 = DispatchTime.now().uptimeNanoseconds
            let ix = SearchIndex()
            var once = Set<String>()
            ix.add(items.filter { once.insert($0.id).inserted }.map { SearchDoc.quick($0, uses: uses, now: now) })
            ix.prepare()
            return (ix, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        let hand = { (ix: SearchIndex, ms: Double) in
            guard g == self.gen else { return }
            self.index = ix; self.heldFor = g; self.buildMs = ms
            done?()
        }
        if inline { let (ix, ms) = make(); hand(ix, ms); return }
        queue.async { let (ix, ms) = make(); DispatchQueue.main.async { hand(ix, ms) } }
    }

    /// The rows to show for a query and a kind, as indices into `items` (the items last handed to `rebuild`).
    func filter(_ items: [QuickItem], query: String, kind: QuickKind?, uses: QuickUses, now: Double) -> [Int] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { if !query.isEmpty, keyMs.count < 2000 { keyMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) } }
        let plain = QuickRules.filter(items, query: query, kind: kind, uses: uses, now: now)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let ix = index,
              let r = ix.search(q, clock: SearchClock(now: now), options: SearchOptions(order: .rank, limit: 500, detail: 0)) else { return plain }
        var seen = Set<Int>(), core: [Int] = []
        for h in r.hits {
            guard let i = rowOf[h.id], i < items.count, kind == nil || items[i].kind == kind, seen.insert(i).inserted else { continue }
            core.append(i)
        }
        let all = core + plain.filter { !seen.contains($0) }
        return all.filter { items[$0].pinned } + all.filter { !items[$0].pinned }
    }
}
