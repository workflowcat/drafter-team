// The journal's search index (search round, 14 November 2026): an inverted index over SearchDoc fields, built off the
// main thread and grown one document at a time; queries run on its own queue and a newer query cancels an older one
// (SearchService). Matching and weights are app/SearchRules.swift. No AppKit, no files: the app hands it documents.
// Each index word knows its stem, so a query word reaches its exact form, its other forms, a prefix while typing, the
// other keyboard layout, an entity's other name forms and, last, index words one or two edits away.
import Foundation

// MARK: - name forms (entities)

/// Other written forms of a name: "andrii" -> "андрій", "андрія"… Given folded, answered folded.
protocol SearchNameForms {
    func otherForms(of folded: String) -> [String]
}

/// Name forms from the entity store's surface map (EntityStore.surfaces: form -> [(record, how)]), word by word: a word
/// at place i of one surface of a record gets the words at place i of that record's other surfaces of the same length.
/// A surface that points at more than one record needs context to resolve, so it is skipped (as is anything listed in
/// `needsContext`). Wire it in the app with
/// `NameFormTable(store.surfaces.mapValues { $0.map { ($0.index, $0.how) } })`.
struct NameFormTable: SearchNameForms {
    private var forms: [String: [String]] = [:]

    init(_ surfaces: [String: [(record: Int, how: String)]], needsContext: Set<String> = []) {
        // record -> surfaces (folded word lists) of that record
        var byRecord: [Int: [[String]]] = [:]
        for (s, hits) in surfaces {
            let recs = Set(hits.map(\.record))
            guard recs.count == 1, !needsContext.contains(s) else { continue }
            let w = SearchRules.terms(s)
            guard !w.isEmpty else { continue }
            byRecord[recs.first!, default: []].append(w)
        }
        var out: [String: Set<String>] = [:]
        for (_, list) in byRecord {
            for a in list {
                for b in list where b.count == a.count && b != a {
                    for i in a.indices where a[i] != b[i] { out[a[i], default: []].insert(b[i]) }
                }
            }
        }
        forms = out.mapValues { Array($0).sorted() }
    }
    func otherForms(of folded: String) -> [String] { forms[folded] ?? [] }
}

/// An optional second stage over the top hits (meaning search, later). Nothing implements it today.
protocol SearchReranker {
    func rerank(_ query: SearchQuery, _ hits: inout [SearchHit], doc: (Int) -> SearchDoc)
}

// MARK: - results

struct SearchSnippet: Equatable {
    let field: SearchField
    let text: String
    let ranges: [NSRange]
}

struct SearchHit {
    let doc: Int                         // index in the index's document list
    let id: String
    var score: Double
    var ranges: [SearchField: [NSRange]] = [:]   // set for the top `detail` hits; others: SearchIndex.detail
    var snippet: SearchSnippet?
}

/// What a UI marks in any text it shows for this query (the row's own line, a reader).
struct SearchMarker {
    var terms: Set<String> = []
    var prefixes: [String] = []
    func ranges(in text: String) -> [NSRange] { SearchRules.ranges(in: text, terms: terms, prefixes: prefixes) }
}

struct SearchResult {
    var query: SearchQuery
    var hits: [SearchHit] = []           // best first (or newest first: SearchOptions.order)
    var kindTotals: [SearchKind: Int] = [:]     // the hits by kind, ignoring a kind: filter
    var chunkTotals: [String: Int] = [:]        // the hits by time chunk, ignoring time filters
    var didYouMean: String?              // the query in the other layout, or with a typo fixed, when that found more
    var didYouMeanWhy = ""               // "layout" | "typo"
    var marker = SearchMarker()
    var ms = 0.0
}

struct SearchOptions {
    enum Order { case rank, time }
    var order = Order.rank
    var limit = Int.max                  // hits returned (totals always count all)
    var detail = SearchWeights.detail    // hits that get ranges and a snippet
    /// The chunk a time belongs to, for chunkTotals (default: today, yesterday, this-week, last-week, this-month,
    /// then yyyy-MM). The window can pass its own TimeChunks id.
    var chunk: ((Double) -> String)? = nil
}

// MARK: - memory straight from the system

/// Growing buffers for the build come from mmap and go back with munmap: on this macOS freed malloc memory stays in
/// the process footprint, so a doubling array would leave its old copies counted against the app.
@inline(__always) func vmAlloc<T>(_ n: Int) -> UnsafeMutablePointer<T> {
    let bytes = max(1, n * MemoryLayout<T>.stride)
    let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
    precondition(p != MAP_FAILED, "search index: out of memory")
    return p!.bindMemory(to: T.self, capacity: n)
}
@inline(__always) func vmFree<T>(_ p: UnsafeMutablePointer<T>, _ n: Int) { munmap(UnsafeMutableRawPointer(p), max(1, n * MemoryLayout<T>.stride)) }
@inline(__always) func vmGrow<T>(_ p: UnsafeMutablePointer<T>, _ used: Int, _ old: Int, _ new: Int) -> UnsafeMutablePointer<T> {
    let q: UnsafeMutablePointer<T> = vmAlloc(new)
    q.update(from: p, count: used)          // plain values only (integers)
    vmFree(p, old)
    return q
}

/// A growing list of plain values on mmap memory (the bulk-add entries, the typo filter's build list).
struct MappedList<T> {
    private(set) var base: UnsafeMutablePointer<T>? = nil
    private(set) var count = 0
    private var cap = 0
    @inline(__always) mutating func append(_ x: T) {
        if count == cap {
            let nc = max(1 << 16, cap * 2)
            base = base.map { vmGrow($0, count, cap, nc) } ?? vmAlloc(nc)
            cap = nc
        }
        base![count] = x; count += 1
    }
    subscript(i: Int) -> T { base![i] }
    var isEmpty: Bool { count == 0 }
    var bytes: Int { cap * MemoryLayout<T>.stride }
    mutating func free() { if let b = base { vmFree(b, cap) }; base = nil; count = 0; cap = 0 }
}

// MARK: - the vocabulary's bytes

/// Index words as UTF-8 bytes in one arena with an open-addressing hash: a word in a text is looked up straight from
/// the scanner's bytes, so building and scanning make no String per word. Raw buffers: no exclusivity check and no
/// copy per lookup.
final class TermTable {
    private var arena: UnsafeMutablePointer<UInt8>, arenaCap = 1 << 16, arenaLen = 0
    private var off: UnsafeMutablePointer<Int32>, len: UnsafeMutablePointer<UInt8>, hash: UnsafeMutablePointer<UInt32>
    private var cap = 1 << 12
    private var slots: UnsafeMutablePointer<Int32>, slotCount = 1 << 13
    private(set) var count = 0

    init() {
        arena = vmAlloc(arenaCap)
        off = vmAlloc(cap); len = vmAlloc(cap); hash = vmAlloc(cap)
        slots = vmAlloc(slotCount); slots.initialize(repeating: -1, count: slotCount)
    }
    deinit { vmFree(arena, arenaCap); vmFree(off, cap); vmFree(len, cap); vmFree(hash, cap); vmFree(slots, slotCount) }

    @inline(__always) static func fnv(_ b: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var h: UInt32 = 0x811C9DC5
        for x in b { h = (h ^ UInt32(x)) &* 0x01000193 }
        return h
    }
    func find(_ b: UnsafeBufferPointer<UInt8>) -> Int32 { find(b, Self.fnv(b)) }
    @inline(__always) func find(_ b: UnsafeBufferPointer<UInt8>, _ h: UInt32) -> Int32 {
        let mask = slotCount - 1
        var i = Int(h) & mask
        while true {
            let t = slots[i]
            if t < 0 { return -1 }
            let ti = Int(t)
            if hash[ti] == h, Int(len[ti]) == b.count, memcmp(arena + Int(off[ti]), b.baseAddress!, b.count) == 0 { return t }
            i = (i + 1) & mask
        }
    }
    func find(_ s: String) -> Int32 {
        var s = s
        return s.withUTF8 { $0.isEmpty ? -1 : find($0) }
    }
    func find(bytes: [UInt8]) -> Int32 { bytes.withUnsafeBufferPointer { $0.isEmpty ? -1 : find($0) } }
    /// Adds a word known to be absent; returns its id.
    func insert(_ b: UnsafeBufferPointer<UInt8>, _ h: UInt32) -> Int32 {
        if count == cap {
            let nc = cap * 2
            off = vmGrow(off, count, cap, nc); len = vmGrow(len, count, cap, nc); hash = vmGrow(hash, count, cap, nc)
            cap = nc
        }
        if arenaLen + b.count > arenaCap {
            var nc = arenaCap * 2
            while arenaLen + b.count > nc { nc *= 2 }
            arena = vmGrow(arena, arenaLen, arenaCap, nc)
            arenaCap = nc
        }
        let t = Int32(count)
        off[count] = Int32(arenaLen); len[count] = UInt8(b.count); hash[count] = h
        (arena + arenaLen).initialize(from: b.baseAddress!, count: b.count)
        arenaLen += b.count
        count += 1
        if count * 2 > slotCount { rehash() } else { place(t, h) }
        return t
    }
    func insert(bytes: [UInt8]) -> Int32 {
        bytes.withUnsafeBufferPointer { b in let h = Self.fnv(b); let f = find(b, h); return f >= 0 ? f : insert(b, h) }
    }
    func insert(_ s: String) -> Int32 { insert(bytes: Array(s.utf8)) }
    private func place(_ t: Int32, _ h: UInt32) {
        let mask = slotCount - 1
        var i = Int(h) & mask
        while slots[i] >= 0 { i = (i + 1) & mask }
        slots[i] = t
    }
    private func rehash() {
        vmFree(slots, slotCount)
        slotCount *= 2
        slots = vmAlloc(slotCount); slots.initialize(repeating: -1, count: slotCount)
        for t in 0..<count { place(Int32(t), hash[t]) }
    }
    func bytes(_ t: Int32) -> UnsafeBufferPointer<UInt8> { UnsafeBufferPointer(start: arena + Int(off[Int(t)]), count: Int(len[Int(t)])) }
    func string(_ t: Int32) -> String { String(decoding: bytes(t), as: UTF8.self) }
    /// The word's scalars (decoded from its UTF-8).
    func scalars(_ t: Int32) -> [UInt32] {
        let b = bytes(t)
        var out: [UInt32] = []; out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c < 0x80 { out.append(UInt32(c)); i += 1 }
            else if c < 0xE0 { out.append(UInt32(c & 0x1F) << 6 | UInt32(b[i + 1] & 0x3F)); i += 2 }
            else if c < 0xF0 { out.append(UInt32(c & 0x0F) << 12 | UInt32(b[i + 1] & 0x3F) << 6 | UInt32(b[i + 2] & 0x3F)); i += 3 }
            else { out.append(UInt32(c & 0x07) << 18 | UInt32(b[i + 1] & 0x3F) << 12 | UInt32(b[i + 2] & 0x3F) << 6 | UInt32(b[i + 3] & 0x3F)); i += 4 }
        }
        return out
    }
    /// Byte order (the same as Unicode scalar order): for the sorted list and prefixes.
    func less(_ x: Int32, _ y: Int32) -> Bool {
        let lx = Int(len[Int(x)]), ly = Int(len[Int(y)])
        let c = memcmp(arena + Int(off[Int(x)]), arena + Int(off[Int(y)]), min(lx, ly))
        return c != 0 ? c < 0 : lx < ly
    }
    /// -1, 0, 1: the word against a prefix (0 = the word starts with it).
    func compare(_ t: Int32, prefix p: [UInt8]) -> Int {
        let l = Int(len[Int(t)])
        let c = p.withUnsafeBufferPointer { memcmp(arena + Int(off[Int(t)]), $0.baseAddress!, min(l, p.count)) }
        if c != 0 { return c < 0 ? -1 : 1 }
        return l < p.count ? -1 : 0
    }
    func length(_ t: Int32) -> Int { Int(len[Int(t)]) }
    var bytes: Int { arenaCap + cap * 9 + slotCount * 4 }
}

/// A long field's words in order, small: the field's own word list and a 16-bit place in it per word.
struct WordRun {
    let vocab: [Int32]
    let codes: [UInt16]
    init(_ ids: [Int32]) {
        var local: [Int32: UInt16] = [:], v: [Int32] = [], c: [UInt16] = []
        c.reserveCapacity(ids.count)
        for t in ids {
            if let k = local[t] { c.append(k) }
            else if v.count < 65535 { let k = UInt16(v.count); local[t] = k; v.append(t); c.append(k) }
            else { c.append(65535) }
        }
        vocab = v; codes = c
    }
    /// Do these words stand together, in this order? Words missing from the field's own list answer at once.
    func contains(_ p: [Int32]) -> Bool {
        guard !p.isEmpty else { return false }
        var loc = [UInt16](); loc.reserveCapacity(p.count)
        for t in p { guard let k = vocab.firstIndex(of: t) else { return false }; loc.append(UInt16(k)) }
        let n = loc.count, first = loc[0]
        return codes.withUnsafeBufferPointer { c in
            guard c.count >= n else { return false }
            var i = 0
            let end = c.count - n
            while i <= end {
                if c[i] == first {
                    var j = 1
                    while j < n, c[i + j] == loc[j] { j += 1 }
                    if j == n { return true }
                }
                i += 1
            }
            return false
        }
    }
    @inline(__always) func forEach(_ f: (Int32) -> Bool) { for k in codes { if !f(k == 65535 ? -1 : vocab[Int(k)]) { return } } }
    var bytes: Int { vocab.capacity * 4 + codes.capacity * 2 + 64 }
}

// MARK: - the index

final class SearchIndex {
    private(set) var docs: [SearchDoc] = []
    private var alive: [Bool] = []
    private var byId: [String: Int] = [:]
    private var appFold: [String] = []
    // what filters and ranking read per document, flat (no SearchDoc copy per candidate)
    private var time: [Double] = [], kind: [UInt8] = [], flags: [UInt16] = [], uses: [Float] = []
    private static let fPinned: UInt16 = 1, fChanged: UInt16 = 2, fPicture: UInt16 = 4, fLink: UInt16 = 8, fTitleInBody: UInt16 = 16
    /// Days each document mentions (sparse: only documents that mention one), for `mentions:`.
    private var mentioned: [Int: [Double]] = [:]
    private var fieldLen: [UInt32] = []             // docs × fields
    private var fieldSum = [Double](repeating: 0, count: SearchField.allCases.count)
    /// Long fields (a transcript) also keep their words as ids in order: phrases and the order bonus read these
    /// instead of the text.
    private var seq: [Int: WordRun] = [:]
    static let seqMin = 3000
    /// Short fields: which pairs of words stand side by side, as 256 bits per document (a pair sets one bit). A phrase
    /// whose pairs miss a bit is not in the document's short fields, so their text is not read again.
    private var pairs: [UInt64] = []
    @inline(__always) static func pairBit(_ a: Int32, _ b: Int32) -> (Int, UInt64) {
        let h = (UInt32(bitPattern: a) &* 0x9E37_79B1 ^ UInt32(bitPattern: b) &* 0x85EB_CA77) >> 24
        return (Int(h >> 6), 1 << UInt64(h & 63))
    }
    private(set) var liveCount = 0

    // vocabulary
    private let table = TermTable()
    private let stemTable = TermTable()
    private var stemOf: [Int32] = []                // per word; filled up to `stemUpTo`
    private var stemUpTo = 0
    private var stemBase: [Int32] = [], stemStart: [Int32] = [0]   // stem -> words, flat, for stems < stemStart.count-1
    private var stemTail: [Int32: [Int32]] = [:]   // stems and words added after the last `prepare`
    // postings: doc << 12 | field << 8 | tf (at most 255), in document order
    private var post: [UInt32] = [], postStart: [Int] = [0]        // flat, for words < postStart.count-1
    private var tail: [Int32: [UInt32]] = [:]       // per word: entries added one by one after the last packing
    private var pend = MappedList<UInt64>()                  // word << 32 | entry: a bulk add, packed by the next query or `prepare`
    private var df: [Int32] = []
    private var lastDoc: [Int32] = []
    private var sorted: [Int32] = []
    private var unsorted: [Int32] = []
    private var triId: [UInt64: Int32] = [:]
    private var triStart: [Int32] = [], triList: [Int32] = [], triTail: [Int32] = []
    private var triUpTo = 0
    static let maxDocs = 1 << 20

    var names: SearchNameForms?
    var reranker: SearchReranker?

    // scratch, reused by every query
    private var tfc: [UInt8] = [], tfTouched: [Int32] = [], triCount: [UInt8] = []
    private var acc: [Float] = [], wbest: [Float] = []
    private var qmark: [UInt32] = [], wmark: [UInt32] = [], cnt: [UInt8] = [], wcls: [UInt8] = [], cls: [UInt32] = []
    private var wfield: [UInt16] = [], pmask: [UInt16] = []      // fields a word is in; fields all phrase words are in
    private var qgen: UInt32 = 0, wgen: UInt32 = 0

    static let fields = SearchField.allCases
    static let nf = SearchField.allCases.count

    init(names: SearchNameForms? = nil) { self.names = names }

    func term(_ t: Int32) -> String { table.string(t) }
    func termIndex(_ s: String) -> Int32? { let t = table.find(s); return t < 0 ? nil : t }
    func index(of id: String) -> Int? { byId[id] }
    var vocabularySize: Int { table.count }

    // MARK: building

    /// Adds documents (a document with an id already there replaces it).
    func add(_ list: [SearchDoc]) {
        let total = docs.count + list.count
        if list.count > 1 {
            docs.reserveCapacity(total); alive.reserveCapacity(total); appFold.reserveCapacity(total); time.reserveCapacity(total)
            kind.reserveCapacity(total); uses.reserveCapacity(total); flags.reserveCapacity(total); fieldLen.reserveCapacity(total * Self.nf)
            pairs.reserveCapacity(total * 4)
            byId.reserveCapacity(total)
        }
        let bulk = list.count >= 64 || !pend.isEmpty
        var tf = tfc, touched = tfTouched, dfL = df, lastL = lastDoc, pendL = pend, newWords = unsorted
        tfc = []; tfTouched = []; df = []; lastDoc = []; pend = MappedList(); unsorted = []
        defer { tfc = tf; tfTouched = touched; df = dfL; lastDoc = lastL; pend = pendL; unsorted = newWords }
        let table = self.table
        for d in list {
            if let old = byId[d.id] { remove(old) }
            let n = docs.count
            precondition(n < Self.maxDocs, "search index full: rebuild it")
            docs.append(d); alive.append(true); byId[d.id] = n; liveCount += 1
            appFold.append(SearchRules.fold(d.app))
            time.append(d.time); kind.append(UInt8(SearchKind.allCases.firstIndex(of: d.kind)!)); uses.append(Float(d.uses))
            flags.append((d.pinned ? Self.fPinned : 0) | (d.changed ? Self.fChanged : 0) | (d.picture ? Self.fPicture : 0) | (d.hasLink ? Self.fLink : 0)
                         | (d.titleInBody ? Self.fTitleInBody : 0) | d.found)
            if !d.mentions.isEmpty { mentioned[n] = d.mentions }
            var pb: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
            var prev: Int32 = -1
            for f in Self.fields {
                if !(f == .body && d.titleInBody) { prev = -1 }   // the body goes on from its first line, the title
                let text = d.field(f)
                var len: UInt32 = 0
                if !text.isEmpty {
                    let long = text.utf8.count >= Self.seqMin
                    // a body whose first line is the title: that line is indexed once, as the title
                    var skip = -1
                    if f == .body, d.titleInBody {
                        let u = text.utf16
                        let lead = u.prefix { $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }.count
                        let nl = u.dropFirst(lead).firstIndex(of: 10).map { u.distance(from: u.startIndex, to: $0) } ?? Int.max
                        skip = min(nl, lead + d.title.utf16.count)
                    }
                    var ids: [Int32] = []
                    // hot loop on locals: no closure, no property access (and its exclusivity check) per word
                    var str = text
                    str.withUTF8 { src in
                        var sc = WordScanner(src)
                        defer { sc.release() }
                        while sc.next() {
                            if sc.start < skip { continue }
                            let b = sc.term
                            let h = TermTable.fnv(b)
                            var t = table.find(b, h)
                            if t < 0 { t = table.insert(b, h); tf.append(0); dfL.append(0); lastL.append(-1); newWords.append(t) }
                            let ti = Int(t)
                            if tf[ti] == 0 { touched.append(t) }
                            if tf[ti] < 0xFF { tf[ti] += 1 }
                            if !sc.part {
                                len += 1
                                if long { ids.append(t) }
                                else {
                                    if prev >= 0 {
                                        let (w, bit) = Self.pairBit(prev, t)
                                        switch w { case 0: pb.0 |= bit; case 1: pb.1 |= bit; case 2: pb.2 |= bit; default: pb.3 |= bit }
                                    }
                                    prev = t
                                }
                            }
                        }
                    }
                    if long { seq[n * Self.nf + f.rawValue] = WordRun(ids) }
                    let base = UInt32(n) << 12 | UInt32(f.rawValue) << 8
                    for t in touched {
                        let ti = Int(t)
                        if bulk { pendL.append(UInt64(ti) << 32 | UInt64(base | UInt32(tf[ti]))) } else { tail[t, default: []].append(base | UInt32(tf[ti])) }
                        if lastL[ti] != Int32(n) { lastL[ti] = Int32(n); dfL[ti] += 1 }
                        tf[ti] = 0
                    }
                    touched.removeAll(keepingCapacity: true)
                }
                fieldLen.append(len)
                fieldSum[f.rawValue] += Double(len)
            }
            pairs.append(pb.0); pairs.append(pb.1); pairs.append(pb.2); pairs.append(pb.3)
        }
        grow()
    }

    func remove(id: String) { if let i = byId[id] { remove(i) } }
    private func remove(_ i: Int) {
        guard alive[i] else { return }
        alive[i] = false; liveCount -= 1; byId[docs[i].id] = nil; mentioned[i] = nil
        for f in Self.fields { fieldSum[f.rawValue] -= Double(fieldLen[i * Self.nf + f.rawValue]); seq[i * Self.nf + f.rawValue] = nil }
        docs[i] = SearchDoc(id: docs[i].id, kind: docs[i].kind, time: docs[i].time)   // its text goes
    }
    /// Pins and puts change often; they do not touch the words.
    func setPinned(_ id: String, _ on: Bool) {
        guard let i = byId[id] else { return }
        docs[i].pinned = on
        flags[i] = on ? flags[i] | Self.fPinned : flags[i] & ~Self.fPinned
    }

    private func grow() {
        let n = docs.count
        if acc.count < n {
            let extra = n - acc.count
            acc += [Float](repeating: 0, count: extra); wbest += [Float](repeating: 0, count: extra)
            qmark += [UInt32](repeating: 0, count: extra); wmark += [UInt32](repeating: 0, count: extra)
            cnt += [UInt8](repeating: 0, count: extra); wcls += [UInt8](repeating: 0, count: extra); cls += [UInt32](repeating: 0, count: extra)
            wfield += [UInt16](repeating: 0, count: extra); pmask += [UInt16](repeating: 0, count: extra)
        }
    }

    /// Stems for words added since the last call (many new words: the stem lists are rebuilt flat).
    private func ensureStems() {
        guard stemUpTo < table.count else { return }
        let from = stemUpTo
        stemOf.reserveCapacity(table.count)
        for t in from..<table.count {
            let sc = table.scalars(Int32(t))
            let st: Int32
            if let f = sc.first, (0x400...0x4FF).contains(f) { st = stemTable.insert(bytes: SearchRules.utf8(SearchRules.stemCyrillic(sc))) }
            else { st = stemTable.insert(SearchRules.stem(table.string(Int32(t)))) }
            stemOf.append(st)
        }
        stemUpTo = table.count
        if table.count - from > 2000 { packStems() }
        else { for t in from..<table.count { stemTail[stemOf[t], default: []].append(Int32(t)) } }
    }
    private func packStems() {
        let ns = stemTable.count
        var start = [Int32](repeating: 0, count: ns + 1)
        for s in stemOf { start[Int(s) + 1] += 1 }
        for i in 0..<ns { start[i + 1] += start[i] }
        var at = start, base = [Int32](repeating: 0, count: stemOf.count)
        for (t, s) in stemOf.enumerated() { base[Int(at[Int(s)])] = Int32(t); at[Int(s)] += 1 }
        stemBase = base; stemStart = start; stemTail = [:]
    }
    private func members(_ s: Int32) -> [Int32] {
        var out: [Int32] = []
        if Int(s) < stemStart.count - 1 { out += stemBase[Int(stemStart[Int(s)])..<Int(stemStart[Int(s) + 1])] }
        if let x = stemTail[s] { out += x }
        return out
    }

    private func ensureSorted() {
        guard !unsorted.isEmpty else { return }
        let fresh = unsorted.sorted { table.less($0, $1) }
        unsorted.removeAll()
        if sorted.isEmpty { sorted = fresh; return }
        var out: [Int32] = []; out.reserveCapacity(sorted.count + fresh.count)
        var i = 0, j = 0
        while i < sorted.count || j < fresh.count {
            if j == fresh.count || (i < sorted.count && table.less(sorted[i], fresh[j])) { out.append(sorted[i]); i += 1 }
            else { out.append(fresh[j]); j += 1 }
        }
        sorted = out
    }

    /// The typo filter over the vocabulary, brought up to date (lazily: the first query that needs it, or `prepare`).
    /// Flat: letter triple -> words; words added later sit in a short list checked one by one (rebuilt past 5,000).
    func ensureTrigrams() {
        guard triUpTo < table.count else { return }
        if table.count - triUpTo < 5000, !triStart.isEmpty {
            for t in triUpTo..<table.count where typoCandidate(Int32(t)) != nil { triTail.append(Int32(t)) }
            triUpTo = table.count
            return
        }
        // two passes: count each triple, then place the words
        var gramsOf = MappedList<Int32>(), gramStart: [Int32] = [0]
        defer { gramsOf.free() }
        gramStart.reserveCapacity(table.count + 1)
        var count: [Int32] = []
        triId = [:]
        for t in 0..<table.count {
            if let sc = typoCandidate(Int32(t)) {
                var gs = SearchRules.trigrams(scalars: sc); gs.sort()
                var last: UInt64 = .max
                for g in gs where g != last {
                    last = g
                    let id: Int32
                    if let x = triId[g] { id = x } else { id = Int32(triId.count); triId[g] = id; count.append(0) }
                    count[Int(id)] += 1; gramsOf.append(id)
                }
            }
            gramStart.append(Int32(gramsOf.count))
        }
        var start = [Int32](repeating: 0, count: count.count + 1)
        for i in 0..<count.count { start[i + 1] = start[i] + count[i] }
        var at = start, list = [Int32](repeating: 0, count: gramsOf.count)
        for t in 0..<table.count { for k in Int(gramStart[t])..<Int(gramStart[t + 1]) { let g = Int(gramsOf[k]); list[Int(at[g])] = Int32(t); at[g] += 1 } }
        triStart = start; triList = list; triTail = []
        triUpTo = table.count
    }
    /// A word that typos may reach: 3 to 30 letters, no digits.
    private func typoCandidate(_ t: Int32) -> [UInt32]? {
        let n = table.length(t)
        guard n >= 3, n <= 120 else { return nil }
        let sc = table.scalars(t)
        guard sc.count >= SearchWeights.typoOne - 2, sc.count <= 30, !sc.contains(where: { (0x30...0x39).contains($0) }) else { return nil }
        return sc
    }

    /// After a load (off the main thread): postings and stems packed flat, the sorted words and the typo filter built.
    /// Searching works without it; it makes the index smaller and the first query quicker.
    func prepare() {
        ensureStems(); ensureSorted(); ensureTrigrams()
        pack()
        if !stemTail.isEmpty { packStems() }
        malloc_zone_pressure_relief(nil, 0)    // the building's freed buffers go back to the system
    }

    /// Postings into one flat array, in word order then document order (a counting sort: the old flat part, the
    /// bulk entries, each word's tail). Runs when a bulk add is waiting and a query comes, and in `prepare`.
    private func pack() {
        guard !pend.isEmpty || !tail.isEmpty || postStart.count - 1 < table.count else { return }
        let nt = table.count
        var count = [Int](repeating: 0, count: nt + 1)
        for t in 0..<min(nt, postStart.count - 1) { count[t + 1] += postStart[t + 1] - postStart[t] }
        for k in 0..<pend.count { count[Int(pend[k] >> 32) + 1] += 1 }
        for (t, l) in tail { count[Int(t) + 1] += l.count }
        for t in 0..<nt { count[t + 1] += count[t] }
        var p = [UInt32](repeating: 0, count: count[nt])
        var at = count
        for t in 0..<min(nt, postStart.count - 1) { for i in postStart[t]..<postStart[t + 1] { p[at[t]] = post[i]; at[t] += 1 } }
        // the tail is older than the bulk entries (a small add goes to the bulk list while one is waiting)
        for (t, l) in tail { for e in l { p[at[Int(t)]] = e; at[Int(t)] += 1 } }
        for k in 0..<pend.count { let e = pend[k], t = Int(e >> 32); p[at[t]] = UInt32(truncatingIfNeeded: e); at[t] += 1 }
        post = p; postStart = count; pend.free(); tail = [:]
    }

    /// A word's entries: the flat part, then its tail.
    @inline(__always) private func postings(_ t: Int32, _ f: (UInt32) -> Bool) {
        let ti = Int(t)
        if ti < postStart.count - 1 {
            for i in postStart[ti]..<postStart[ti + 1] { if !f(post[i]) { return } }
        }
        if let x = tail[t] { for e in x { if !f(e) { return } } }
    }
    private func postingCount(_ t: Int32) -> Int {
        let ti = Int(t)
        return (ti < postStart.count - 1 ? postStart[ti + 1] - postStart[ti] : 0) + (tail[t]?.count ?? 0)
    }

    // MARK: expansions

    struct Exp { let term: Int32; let w: Double; let cls: UInt8 }   // cls 0 typed, 1 other layout, 2 typo

    func prefixTerms(_ p: String) -> [Int32] {
        ensureSorted()
        let pb = Array(p.utf8)
        guard !pb.isEmpty else { return [] }
        var lo = 0, hi = sorted.count
        while lo < hi { let m = (lo + hi) / 2; if table.compare(sorted[m], prefix: pb) < 0 { lo = m + 1 } else { hi = m } }
        var out: [Int32] = []
        var i = lo
        while i < sorted.count, table.compare(sorted[i], prefix: pb) == 0 { out.append(sorted[i]); i += 1 }
        if out.count > SearchWeights.prefixMax { out = Array(out.sorted { df[Int($0)] > df[Int($1)] }.prefix(SearchWeights.prefixMax)) }
        return out
    }

    func typoTerms(_ w: String, budget given: Int? = nil) -> [(Int32, Int)] {
        let budget = given ?? SearchRules.typoBudget(w)
        guard budget > 0 else { return [] }
        ensureTrigrams()
        if triCount.count < table.count { triCount += [UInt8](repeating: 0, count: table.count - triCount.count) }
        let q = w.unicodeScalars.map(\.value)
        let grams = Array(Set(SearchRules.trigrams(scalars: q)))
        let need = max(1, grams.count - 3 * budget)
        var touched: [Int32] = []
        var c = triCount
        triCount = []
        for g in grams {
            guard let id = triId[g], Int(id) < triStart.count - 1 else { continue }
            for k in Int(triStart[Int(id)])..<Int(triStart[Int(id) + 1]) {
                let t = triList[k]
                if c[Int(t)] == 0 { touched.append(t) }
                if c[Int(t)] < 255 { c[Int(t)] += 1 }
            }
        }
        var out: [(Int32, Int)] = []
        let qb = w.utf8.count
        func test(_ t: Int32) {
            guard abs(table.length(t) - qb) <= budget * 4 else { return }
            let s = table.scalars(t)
            guard abs(s.count - q.count) <= budget, s != q else { return }
            let d = SearchRules.distance(q, s, max: budget)
            if d <= budget { out.append((t, d)) }
        }
        for t in touched {
            if Int(c[Int(t)]) >= need { test(t) }
            c[Int(t)] = 0
        }
        triCount = c
        for t in triTail { test(t) }
        return out
    }

    /// Every index word a query word reaches, with its weight. Typed forms first; the other layout and typos below.
    /// Typos are looked for only when the typed forms are rare (under 50 documents): a common word has its answer.
    func expand(_ word: SearchWord, exactOnly: Bool = false, retry: Bool = false) -> [Exp] {
        ensureStems()
        var best: [Int32: Exp] = [:]
        func put(_ t: Int32, _ w: Double, _ c: UInt8) {
            if let o = best[t], o.w >= w { return }
            best[t] = Exp(term: t, w: w, cls: c)
        }
        func forms(_ term: String, _ scale: Double, _ c: UInt8, prefix: Bool) {
            if let t = termIndex(term) { put(t, SearchWeights.exact * scale, c) }
            if exactOnly { return }
            let s = stemTable.find(SearchRules.stem(term))
            if s >= 0 { for t in members(s) { put(t, SearchWeights.stem * scale, c) } }
            if prefix { for t in prefixTerms(term) { put(t, SearchWeights.prefix * scale, c) } }
        }
        forms(word.term, 1, 0, prefix: word.prefix)
        if exactOnly { return Array(best.values) }
        if let n = names { for f in n.otherForms(of: word.term) { forms(f, SearchWeights.name, 0, prefix: false) } }
        if let o = SearchRules.otherLayout(word.raw), let t = SearchRules.terms(o).first {
            forms(t, SearchWeights.layout, 1, prefix: word.prefix)
        }
        // Ukrainian alternations: кінь/коня, Київ/Києві, сон/сну, рука/руці (below a plain stem)
        if SearchRules.isCyrillic(word.term) {
            let st = SearchRules.stem(word.term)
            var shapes = SearchRules.alternations(st)
            if st == word.term { shapes += SearchRules.alternations(word.term, dropEnd: true) }
            for sh in shapes {
                let s1 = stemTable.find(sh)
                if s1 >= 0 { for t in members(s1) { put(t, SearchWeights.alternation, 0) } }
                let st2 = SearchRules.stem(sh)
                if st2 != sh { let s2 = stemTable.find(st2); if s2 >= 0 { for t in members(s2) { put(t, SearchWeights.alternation, 0) } } }
                if let t = termIndex(sh) { put(t, SearchWeights.alternation, 0) }
                if sh.unicodeScalars.count <= 3 { for e in SearchRules.shortEndings { if let t = termIndex(sh + e) { put(t, SearchWeights.alternation, 0) } } }
            }
        }
        let typedDocs = best.values.reduce(0) { $0 + ($1.cls == 0 ? Int(df[Int($1.term)]) : 0) }
        if typedDocs < 50 || retry {
            // a retry (the query found under 3 items) also lets a 4-letter word have one edit, ranked last
            let n = word.term.unicodeScalars.count
            let four = retry && n == 4 && SearchRules.typoBudget(word.term + "x") > 0
            for (t, d) in typoTerms(word.term, budget: four ? 1 : nil) where best[t] == nil {
                put(t, four ? SearchWeights.typo4 : d == 1 ? SearchWeights.typo1 : SearchWeights.typo2, 2)
            }
        }
        return Array(best.values)
    }

    // MARK: search

    func search(_ text: String, clock: SearchClock = SearchClock(), options: SearchOptions = SearchOptions(),
                cancelled: () -> Bool = { false }) -> SearchResult? {
        search(SearchQueryRules.parse(text, clock: clock), clock: clock, options: options, cancelled: cancelled)
    }

    /// A query that finds under `SearchWeights.retryUnder` items is tried once more with typos on every word
    /// (common words and 4-letter words included); the retry's extra hits rank below the first ones.
    func search(_ q: SearchQuery, clock: SearchClock = SearchClock(), options: SearchOptions = SearchOptions(),
                cancelled: () -> Bool = { false }) -> SearchResult? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard var r = searchOnce(q, clock: clock, options: options, retry: false, cancelled: cancelled) else { return nil }
        if !q.words.isEmpty, r.hits.count < SearchWeights.retryUnder, r.hits.count < options.limit {
            guard let r2 = searchOnce(q, clock: clock, options: options, retry: true, cancelled: cancelled) else { return nil }
            if r2.hits.count > r.hits.count { r = r2 }
        }
        r.ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return r
    }

    private func searchOnce(_ q: SearchQuery, clock: SearchClock, options: SearchOptions, retry: Bool,
                            cancelled: () -> Bool) -> SearchResult? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var res = SearchResult(query: q)
        grow()
        if !pend.isEmpty { pack() }
        let n = docs.count, nf = Self.nf
        let avg = fieldSum.map { liveCount > 0 ? max(1, $0 / Double(liveCount)) : 1 }
        let fw = Self.fields.map { SearchWeights.field[$0] ?? 1 }
        let k1 = SearchWeights.k1, b = SearchWeights.b

        // words: the query's words (with all their forms) and the words of each phrase (exact)
        var words: [(SearchWord, [Exp])] = q.words.map { ($0, expand($0, retry: retry)) }
        for p in q.phrases { for t in p { words.append((SearchWord(raw: t, term: t), expand(SearchWord(raw: t, term: t), exactOnly: true))) } }
        if cancelled() { return nil }
        var marker = SearchMarker()
        var markIds = Set<Int32>()
        for (w, ex) in words {
            for e in ex where e.cls != 2 || ex.count < 40 { marker.terms.insert(term(e.term)); markIds.insert(e.term) }
            if w.prefix { marker.prefixes.append(w.term) }
        }
        res.marker = marker

        qgen &+= 1
        var cands: [Int] = []
        let textQuery = !words.isEmpty
        // the rarest word first: it narrows the most
        let sizes = words.map { $0.1.reduce(0) { $0 + postingCount($1.term) } }
        let order = words.indices.sorted { sizes[$0] < sizes[$1] }
        var steps = 0, stop = false
        for (k, wi) in order.enumerated() {
            wgen &+= 1
            var touched: [Int] = []
            for e in words[wi].1 {
                if postingCount(e.term) == 0 { continue }
                let idf = SearchRules.idf(df: Int(df[Int(e.term)]), docs: max(1, liveCount))
                var cur = -1, tfw = 0.0, fbits: UInt16 = 0
                func close() {
                    let d = cur
                    guard d >= 0, alive[d], k == 0 || (qmark[d] == qgen && Int(cnt[d]) == k) else { return }
                    let s = Float(e.w * idf * tfw * (k1 + 1) / (tfw + k1))
                    if wmark[d] != wgen { wmark[d] = wgen; wbest[d] = s; wcls[d] = e.cls; wfield[d] = fbits; touched.append(d) }
                    else { if s > wbest[d] { wbest[d] = s }; if e.cls < wcls[d] { wcls[d] = e.cls }; wfield[d] |= fbits }
                }
                postings(e.term) { p in
                    let d = Int(p >> 12)
                    if d != cur {
                        close(); cur = d; tfw = 0; fbits = 0
                        steps += 1
                        if steps & 0x3FFF == 0, cancelled() { stop = true; return false }
                    }
                    let f = Int((p >> 8) & 0xF), tf = Double(p & 0xFF)
                    fbits |= 1 << UInt16(f)
                    tfw += fw[f] * tf / (1 - b + b * Double(fieldLen[d * nf + f]) / avg[f])
                    return true
                }
                if stop { return nil }
                close()
            }
            let phraseWord = wi >= q.words.count && q.phrases.count == 1
            let bodyBit = UInt16(1) << UInt16(SearchField.body.rawValue)
            for d in touched {
                // a title that is the body's first line: a word there also stands in the body (a phrase may run on)
                let wf = flags[d] & Self.fTitleInBody != 0 && wfield[d] & 1 != 0 ? wfield[d] | bodyBit : wfield[d]
                if k == 0 { qmark[d] = qgen; cnt[d] = 1; acc[d] = wbest[d]; cls[d] = UInt32(wcls[d]); pmask[d] = phraseWord ? wf : 0xFFFF }
                else {
                    cnt[d] += 1; acc[d] += wbest[d]; cls[d] |= UInt32(wcls[d]) << (2 * UInt32(min(k, 15)))
                    if phraseWord { pmask[d] &= wf }
                }
            }
            cands = touched
            if cands.isEmpty { break }
            if cancelled() { return nil }
        }
        if !textQuery { cands = (0..<n).filter { alive[$0] } }

        // excluded words and phrases
        var out = Set<Int>()
        for w in q.excluded {
            for e in expand(SearchWord(raw: w.raw, term: w.term)) where e.cls == 0 && e.w >= SearchWeights.stem {
                postings(e.term) { out.insert(Int($0 >> 12)); return true }
            }
        }

        // filters, grouped so the side counts can leave their own group out
        var kinds: Set<SearchKind>?
        var times: [(Double, Double)] = [], apps: [String] = []
        var need: UInt16 = 0
        var withDocs: Set<Int>?
        var days: [(Double, Double)] = []
        for f in q.filters {
            switch f {
            case .kind(let k): kinds = (kinds ?? k).intersection(k)
            case .time(let lo, let hi): times.append((lo, hi))
            case .app(let a): apps.append(a)
            case .has(let h):
                need |= h.bit
            case .mentions(let lo, let hi): days.append((lo, hi))
            case .with(let v): let s = withSet(v); withDocs = withDocs.map { $0.intersection(s) } ?? s
            }
        }
        let kindOK: [Bool] = SearchKind.allCases.map { kinds?.contains($0) ?? true }
        let chunkOf = options.chunk ?? Self.chunker(clock)
        let phraseIds = q.phrases.map { $0.map { termIndex($0) ?? -1 } }, notPhraseIds = q.excludedPhrases.map { $0.map { termIndex($0) ?? -1 } }

        struct Cand { let d: Int; var score: Double; let time: Double }
        var hits: [Cand] = []
        var kindCount = [Int](repeating: 0, count: SearchKind.allCases.count)
        var chunkCount: [String: Int] = [:]
        var wordCounts = [[Int]](repeating: [0, 0, 0], count: order.count)
        var checked = 0
        for d in cands {
            if out.contains(d) { continue }
            let okKind = kindOK[Int(kind[d])]
            let t = time[d]
            let okTime = times.allSatisfy { t >= $0.0 && t < $0.1 }
            let okOther = flags[d] & need == need && (withDocs?.contains(d) ?? true) && apps.allSatisfy { appFold[d].contains($0) }
                && (days.isEmpty || days.allSatisfy { r in mentioned[d]?.contains { $0 >= r.0 && $0 < r.1 } ?? false })
            if !(okOther && (okTime || okKind)) { continue }
            if !phraseIds.isEmpty || !notPhraseIds.isEmpty {
                checked += 1
                if checked & 0xFF == 0, cancelled() { return nil }
                if !phraseIds.allSatisfy({ phrase($0, d, fields: textQuery ? pmask[d] : 0xFFFF) }) { continue }
                if notPhraseIds.contains(where: { phrase($0, d) }) { continue }
            }
            if okTime { kindCount[Int(kind[d])] += 1 }
            if okKind { chunkCount[chunkOf(t), default: 0] += 1 }
            guard okKind && okTime else { continue }
            let text = textQuery ? Double(acc[d]) : 1
            hits.append(Cand(d: d, score: SearchRules.final(text: text, time: t, now: clock.now, uses: Double(uses[d]), pinned: flags[d] & Self.fPinned != 0), time: t))
            if textQuery { for k in 0..<order.count { wordCounts[k][Int((cls[d] >> (2 * UInt32(min(k, 15)))) & 3)] += 1 } }
        }
        for (i, k) in SearchKind.allCases.enumerated() where kindCount[i] > 0 { res.kindTotals[k] = kindCount[i] }
        res.chunkTotals = chunkCount
        if cancelled() { return nil }

        // did you mean: a word found more often in the other layout, or one edit away, than as typed
        if textQuery {
            var fixed = q.raw, why = ""
            for (k, wi) in order.enumerated() where wi < q.words.count {
                let c = wordCounts[k], w = q.words[wi]
                if c[1] > c[0], let o = SearchRules.otherLayout(w.raw) { fixed = fixed.replacingOccurrences(of: w.raw, with: o); why = "layout" }
                else if c[2] > c[0], let t = words[wi].1.filter({ $0.cls == 2 }).max(by: { df[Int($0.term)] < df[Int($1.term)] }) {
                    fixed = fixed.replacingOccurrences(of: w.raw, with: term(t.term)); why = why.isEmpty ? "typo" : why
                }
            }
            if fixed != q.raw { res.didYouMean = fixed.trimmingCharacters(in: .whitespaces); res.didYouMeanWhy = why }
        }

        // order: rank (score, then newer, then id) or time
        let byRank: (Cand, Cand) -> Bool = { a, b in
            a.score != b.score ? a.score > b.score : a.time != b.time ? a.time > b.time : a.d > b.d
        }
        let byTime: (Cand, Cand) -> Bool = { a, b in a.time != b.time ? a.time > b.time : a.d > b.d }
        if textQuery && options.order == .rank { hits.sort(by: byRank) } else { hits.sort(by: byTime) }

        // the top: words side by side in order (a phrase-like bonus), then ranges, snippets, an optional re-rank
        let top = min(hits.count, options.detail)
        if textQuery, options.order == .rank, q.words.count >= 2 {
            let seqs: [Set<Int32>] = q.words.map { w in
                var s = Set<Int32>(); for (ww, ex) in words where ww == w { for e in ex where e.cls != 2 { s.insert(e.term) } }; return s
            }
            for i in 0..<top {
                let near = nearness(seqs, hits[i].d)
                hits[i].score *= 1 + (near == 2 ? SearchWeights.phrase : near == 1 ? SearchWeights.order : 0)
            }
            if top > 1 { hits[0..<top].sort(by: byRank) }
        }
        var list: [SearchHit] = []
        list.reserveCapacity(min(hits.count, options.limit))
        for (i, c) in hits.prefix(options.limit).enumerated() {
            var h = SearchHit(doc: c.d, id: docs[c.d].id, score: c.score)
            if i < options.detail, textQuery { (h.ranges, h.snippet) = detail(c.d, ids: markIds, maxUnits: Self.detailUnits) }
            list.append(h)
        }
        if let r = reranker { r.rerank(q, &list, doc: { self.docs[$0] }) }
        res.hits = list
        res.ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return res
    }

    /// In a search, a long field is read this far for ranges and the snippet (a reader opening a hit asks `detail`
    /// for the whole text).
    static let detailUnits = 6000

    /// The index words of a text with their places (parts left out), up to `maxUnits` UTF-16 units. -1: not indexed.
    private func scanIds(_ text: String, maxUnits: Int = .max, _ f: (Int32, Int, Int) -> Bool) {
        let table = self.table
        SearchRules.scanBytes(text) { b, start, len, part in
            if start > maxUnits { return false }
            if part { return true }
            return f(table.find(b), start, len)
        }
    }
    /// A field's words as ids: the kept sequence of a long field, else read from the text.
    private func words(_ d: Int, _ f: SearchField, _ body: (Int32) -> Bool) {
        if let s = seq[d * Self.nf + f.rawValue] { s.forEach(body); return }
        let text = docs[d].field(f)
        if text.isEmpty { return }
        scanIds(text) { t, _, _ in body(t) }
    }

    /// Ranges per field and a snippet of the longest matching field, for one hit (any hit, on demand).
    func detail(_ d: Int, _ m: SearchMarker, maxUnits: Int = .max) -> ([SearchField: [NSRange]], SearchSnippet?) {
        var ids = Set<Int32>()
        for t in m.terms { if let i = termIndex(t) { ids.insert(i) } }
        for p in m.prefixes { for i in prefixTerms(p) { ids.insert(i) } }
        return detail(d, ids: ids, maxUnits: maxUnits)
    }

    func detail(_ d: Int, ids: Set<Int32>, maxUnits: Int = .max) -> ([SearchField: [NSRange]], SearchSnippet?) {
        var r: [SearchField: [NSRange]] = [:]
        var snip: SearchSnippet?
        for f in Self.fields {
            let text = docs[d].field(f)
            guard !text.isEmpty else { continue }
            var rs: [NSRange] = []
            scanIds(text, maxUnits: maxUnits) { t, start, len in
                if ids.contains(t) { rs.append(NSRange(location: start, length: len)) }
                return rs.count < 200
            }
            guard !rs.isEmpty else { continue }
            r[f] = rs
            if (text as NSString).length > 160, snip == nil || f == .body || f == .transcript && snip?.field != .body {
                let s = SearchRules.snippet(text, ranges: rs)
                snip = SearchSnippet(field: f, text: s.text, ranges: s.ranges)
            }
        }
        return (r, snip)
    }

    /// Does a run of folded words stand together in one field?
    private func phrase(_ p: [Int32], _ d: Int, fields: UInt16 = 0xFFFF) -> Bool {
        if p.contains(-1) || fields == 0 { return false }
        var mask = fields
        if flags[d] & Self.fTitleInBody != 0, mask & 1 != 0 { mask = (mask & ~1) | (1 << UInt16(SearchField.body.rawValue)) }
        var shortOK = true
        if p.count > 1 { for i in 0..<(p.count - 1) { let (w, bit) = Self.pairBit(p[i], p[i + 1]); if pairs[d * 4 + w] & bit == 0 { shortOK = false; break } } }
        for f in Self.fields where mask & (1 << UInt16(f.rawValue)) != 0 {
            if let r = seq[d * Self.nf + f.rawValue] { if r.contains(p) { return true }; continue }
            if !shortOK { continue }
            var i = 0, found = false
            words(d, f) { t in
                if t == p[i] { i += 1; if i == p.count { found = true } }
                else { i = t == p[0] ? 1 : 0 }
                return !found
            }
            if found { return true }
        }
        return false
    }

    /// 2: the query words stand side by side in their order somewhere; 1: in order within four words; 0: neither.
    private func nearness(_ seq: [Set<Int32>], _ d: Int) -> Int {
        var best = 0
        for f in Self.fields where f != .app {
            if f == .title, flags[d] & Self.fTitleInBody != 0 { continue }
            var pos = 0, k = 0, lastAt = -10, gapMax = 0
            words(d, f) { t in
                if seq[k].contains(t), k == 0 || pos - lastAt <= 4 {
                    if k > 0 { gapMax = max(gapMax, pos - lastAt) }
                    k += 1; lastAt = pos
                    if k == seq.count { best = max(best, gapMax <= 1 ? 2 : 1); k = 0; gapMax = 0 }
                } else if seq[0].contains(t) { k = 1; lastAt = pos; gapMax = 0 }
                else if pos - lastAt > 4 { k = 0; gapMax = 0 }
                pos += 1
                return best < 2
            }
            if best == 2 { return 2 }
        }
        return best
    }

    /// Documents whose tags hold this name (or its other forms), every word of it.
    private func withSet(_ v: String) -> Set<Int> {
        ensureStems()
        var result: Set<Int>?
        for w in SearchRules.terms(v) {
            var forms = [w]
            if let n = names { forms += n.otherForms(of: w) }
            var s = Set<Int>()
            for f in forms {
                var ts: [Int32] = []
                if let t = termIndex(f) { ts.append(t) }
                let st = stemTable.find(SearchRules.stem(f))
                if st >= 0 { ts += members(st) }
                for t in ts { postings(t) { p in if Int((p >> 8) & 0xF) == SearchField.tags.rawValue { s.insert(Int(p >> 12)) }; return true } }
            }
            result = result.map { $0.intersection(s) } ?? s
        }
        return result ?? []
    }

    /// today, yesterday, this-week, last-week, this-month, then yyyy-MM.
    static func chunker(_ clock: SearchClock) -> (Double) -> String {
        let today = clock.day(clock.date), yest = clock.day(Date(timeIntervalSince1970: today.0 - 3600))
        let week = clock.span(.weekOfYear), last = clock.span(.weekOfYear, back: 1), month = clock.span(.month)
        let cal = clock.calendar
        var cache: [Int: String] = [:]
        return { t in
            if t >= today.0 { return "today" }
            if t >= yest.0 { return "yesterday" }
            if t >= week.0 { return "this-week" }
            if t >= last.0 { return "last-week" }
            if t >= month.0 { return "this-month" }
            let key = Int(t / 86400)
            if let c = cache[key] { return c }
            let c = cal.dateComponents([.year, .month], from: Date(timeIntervalSince1970: t))
            let s = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            cache[key] = s
            return s
        }
    }

    // MARK: size

    /// Where the bytes go, by part (an estimate from counts and capacities).
    func sizeReport() -> [(String, Int)] {
        [("postings", post.capacity * 4 + postStart.capacity * 8 + pend.bytes + tail.reduce(0) { $0 + $1.value.capacity * 4 + 48 }),
         ("long-field sequences", seq.reduce(0) { $0 + $1.value.bytes }),
         ("typo filter", triId.count * 24 + triStart.capacity * 4 + triList.capacity * 4 + triTail.capacity * 4),
         ("words and stems", table.bytes + stemTable.bytes + stemBase.capacity * 4 + stemStart.capacity * 4 + stemOf.capacity * 4
            + df.capacity * 4 + lastDoc.capacity * 4 + sorted.capacity * 4 + tfc.capacity + triCount.capacity),
         ("documents' numbers", fieldLen.capacity * 4 + alive.capacity + appFold.count * 16 + byId.count * 48
            + time.capacity * 8 + kind.capacity + flags.capacity * 2 + mentioned.count * 48 + uses.capacity * 4 + acc.capacity * 22 + pairs.capacity * 8)]
    }

    /// Bytes the index holds beyond the documents' own strings (an estimate from counts and capacities).
    func indexBytes() -> Int { sizeReport().reduce(0) { $0 + $1.1 } }
}

// MARK: - the service: one queue, newest query wins

/// The index on its own queue. Loads and adds run there; a search started while another runs makes the older one
/// stop at its next check and report nothing (stale). Results come back on `callback` (main by default).
final class SearchService {
    let queue = DispatchQueue(label: "drafter.search", qos: .userInitiated)
    let index: SearchIndex
    private let lock = NSLock()
    private var generation = 0
    var callback = DispatchQueue.main

    init(names: SearchNameForms? = nil) { index = SearchIndex(names: names) }

    func load(_ docs: [SearchDoc], done: (() -> Void)? = nil) {
        queue.async { self.index.add(docs); self.index.prepare(); if let done { self.callback.async(execute: done) } }
    }
    func add(_ docs: [SearchDoc]) { queue.async { self.index.add(docs) } }
    func remove(ids: [String]) { queue.async { for i in ids { self.index.remove(id: i) } } }
    func setPinned(_ id: String, _ on: Bool) { queue.async { self.index.setPinned(id, on) } }

    /// Runs the query; `done` gets the result, or is never called when a newer query came first.
    func search(_ text: String, clock: @escaping () -> SearchClock = { SearchClock() }, options: SearchOptions = SearchOptions(),
                done: @escaping (SearchResult) -> Void) {
        lock.lock(); generation += 1; let mine = generation; lock.unlock()
        queue.async {
            let stale = { self.lock.lock(); defer { self.lock.unlock() }; return self.generation != mine }
            if stale() { return }
            guard let r = self.index.search(text, clock: clock(), options: options, cancelled: stale), !stale() else { return }
            self.callback.async { if !stale() { done(r) } }
        }
    }
}
