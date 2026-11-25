// The journal's search index on its own queue (search round two, 14 November 2026). Foundation only: the window hands
// it rows through closures (JournalSearch.swift turns a TapeItem into a SearchDoc); bench/search_bench.swift drives the
// same engine with the same documents. Built once off the main thread, then only what changed is added or removed;
// a search waits behind the updates on the same queue, and a newer search makes an older one stop.
import Foundation

final class JournalEngine {
    let service: SearchService
    /// Previews and tests: everything on the calling thread, at once.
    let inline: Bool
    /// The first build is in (main thread). Before that the plain search answers.
    private(set) var ready = false
    /// How long the first build took on the queue, in ms (documents made, words added, prepared).
    private(set) var buildMs = 0.0
    private var version = Int.min          // main: the rows last handed over
    private var sigs: [String: Int] = [:]  // queue: what the index holds per row id
    private var started = false
    private var at: (version: Int, map: [String: Int]) = (Int.min, [:])   // main: row id -> row index
    /// Called on the main thread when the first build is in.
    var onReady: (() -> Void)?
    /// Where answers and `onReady` run: the main thread (a bench passes its own queue).
    var callback = DispatchQueue.main { didSet { service.callback = callback } }

    init(names: SearchNameForms? = nil, inline: Bool = false) {
        service = SearchService(names: names)
        self.inline = inline
    }

    /// Hands the rows over. `version` changes whenever the rows do (a new build, a pin, a change); the same version
    /// costs nothing. The ids, signatures and documents are read on the queue (the closures hold a snapshot).
    func update(version v: Int, count: Int, id: @escaping (Int) -> String, sig: @escaping (Int) -> Int, doc: @escaping (Int) -> SearchDoc) {
        guard v != version else { return }
        version = v
        let first = !started
        started = true
        let work = { [self] in
            let t0 = DispatchTime.now().uptimeNanoseconds
            var keep = Set<String>(minimumCapacity: count)
            var add: [SearchDoc] = []
            var pins: [(String, Bool)] = []
            for i in 0..<count {
                let k = id(i), s = sig(i)
                keep.insert(k)
                guard sigs[k] != s else { continue }
                let d = doc(i)
                if sigs[k] != nil, let old = service.index.index(of: k), Self.onlyPin(service.index.docs[old], d) { pins.append((k, d.pinned)) }
                else { add.append(d) }
                sigs[k] = s
            }
            if !first { for k in sigs.keys where !keep.contains(k) { service.index.remove(id: k); sigs[k] = nil } }
            for (k, on) in pins { service.index.setPinned(k, on) }
            if !add.isEmpty { service.index.add(add) }
            if first { service.index.prepare() }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if first {
                let done = { self.buildMs = ms; self.ready = true; if !self.inline { self.onReady?() } }
                if inline { done() } else { callback.async(execute: done) }
            }
        }
        if inline { work() } else { service.queue.async(execute: work) }
    }

    /// Only the pin differs: the words stay, the flag changes.
    private static func onlyPin(_ a: SearchDoc, _ b: SearchDoc) -> Bool {
        a.title == b.title && a.body == b.body && a.ocr == b.ocr && a.link == b.link && a.transcript == b.transcript && a.summary == b.summary
            && a.recTitle == b.recTitle && a.tags == b.tags && a.app == b.app && a.time == b.time
    }

    /// Every hit (best first), ranges and snippets for the top `SearchWeights.detail`. `done` runs on the main thread,
    /// or not at all when a newer search came first. now: a fixed clock (previews, tests).
    func search(_ query: String, now: Double? = nil, done: @escaping (SearchResult) -> Void) {
        let opts = SearchOptions(order: .rank, limit: .max)
        let clock = { now.map { SearchClock(now: $0) } ?? SearchClock() }
        if inline {
            if let r = service.index.search(query, clock: clock(), options: opts) { done(r) }
            return
        }
        service.search(query, clock: clock, options: opts, done: done)
    }

    /// Row id -> its index in the rows of this version (main thread, worked out once per version).
    func rowIndex(version v: Int, count: Int, id: (Int) -> String) -> [String: Int] {
        if at.version == v { return at.map }
        var m = [String: Int](minimumCapacity: count)
        for i in 0..<count where m[id(i)] == nil { m[id(i)] = i }
        at = (v, m)
        return m
    }
}

extension JournalEngine {
    /// One journal row as a document: a recording through `SearchDoc.call`, a copy, message or take through
    /// `SearchDoc.entry`, a journal draft by its text. His change comes first (it is what the row shows); the stored
    /// text stays searchable after it.
    static func doc(id: String, kind: SearchKind, at: Double, app: String, line: String, entry: Entry?, call: CallDoc?,
                    change: String?, pinned: Bool, shot: String = "") -> SearchDoc {
        var d: SearchDoc
        if let c = call { d = .call(c, id: id) }
        else if let e = entry { d = .entry(e, kind: kind, id: id, time: at) }
        else { d = .text(id: id, kind: kind, time: at, app: app, text: line) }
        d.addShot(shot)
        if let c = change, !c.isEmpty {
            let old = d.body
            d.title = String(SearchRules.firstLine(c).0.prefix(400))
            d.body = c + (old.isEmpty ? "" : "\n" + old)
            d.titleInBody = true
            d.changed = true
        }
        d.pinned = pinned
        return d
    }
}
