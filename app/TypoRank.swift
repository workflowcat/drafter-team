// Ranked typo fix, parts b (candidates), d (context), e (gate) and f (outcome); pure. See app/TypoRules.swift.
import Foundation

enum TypoRank {
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    // MARK: b. A delete index (SymSpell) over the words he writes

    /// Every word and its deletes (one letter out; two for words of 8+ letters) as sorted hashes: about 12 bytes an
    /// entry, so his ~19,000 words take a few MB. A lookup verifies each hit with the real distance.
    struct DeleteIndex {
        let words: [String], counts: [Int]
        private let keys: [UInt64], ids: [Int32]

        init(_ counts: [String: Int]) {
            let list = counts.filter { TypoRules.letters($0.key) && $0.key == $0.key.lowercased() && $0.key.count >= 3 }.sorted { $0.key < $1.key }
            words = list.map { $0.key }; self.counts = list.map { $0.value }
            var pairs: [(UInt64, Int32)] = []
            pairs.reserveCapacity(list.count * 12)
            for (i, w) in words.enumerated() {
                for d in DeleteIndex.deletes(w, depth: w.count >= 8 ? 2 : 1) { pairs.append((hash(d), Int32(i))) }
            }
            pairs.sort { $0.0 < $1.0 }
            keys = pairs.map { $0.0 }; ids = pairs.map { $0.1 }
        }

        static func deletes(_ w: String, depth: Int) -> Set<String> {
            var out: Set<String> = [w], edge: Set<String> = [w]
            for _ in 0..<depth {
                var next: Set<String> = []
                for s in edge where s.count > 2 {
                    let c = Array(s)
                    for i in c.indices { next.insert(String(c[..<i] + c[(i + 1)...])) }
                }
                out.formUnion(next); edge = next
            }
            return out
        }

        private func hits(_ k: UInt64) -> ArraySlice<Int32> {
            var lo = 0, hi = keys.count
            while lo < hi { let m = (lo + hi) / 2; if keys[m] < k { lo = m + 1 } else { hi = m } }
            var end = lo
            while end < keys.count && keys[end] == k { end += 1 }
            return ids[lo..<end]
        }

        /// His words within `maxDistance` (Damerau) of the typo, with his counts.
        func lookup(_ typo: String, maxDistance: Int) -> [(word: String, count: Int)] {
            var seen = Set<Int32>(), out: [(String, Int)] = []
            for d in DeleteIndex.deletes(typo, depth: maxDistance) {
                for i in hits(hash(d)) where seen.insert(i).inserted {
                    let w = words[Int(i)]
                    if w != typo, abs(w.count - typo.count) <= maxDistance, CorrectionRules.distance(typo, w) <= maxDistance { out.append((w, counts[Int(i)])) }
                }
            }
            return out
        }
        var count: Int { keys.count }
    }

    // MARK: d. Context: what he writes after the word before

    /// "prev next" pairs he wrote twice or more, from data/typo-bigrams.tsv (engine/typos.py, nightly).
    struct Bigrams {
        let pairs: [UInt64: Int32], firsts: [UInt64: Int32]
        init(pairs: [UInt64: Int32] = [:], firsts: [UInt64: Int32] = [:]) { self.pairs = pairs; self.firsts = firsts }
        /// One "prev<TAB>next<TAB>count" per line.
        init(tsv: String) {
            var p: [UInt64: Int32] = [:], f: [UInt64: Int32] = [:]
            for line in tsv.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count == 3, let n = Int32(parts[2]) else { continue }
                p[hash(parts[0] + " " + parts[1]), default: 0] += n
                f[hash(String(parts[0])), default: 0] += n
            }
            pairs = p; firsts = f
        }
        func count(_ prev: String, _ next: String) -> Int { Int(pairs[hash(prev + " " + next)] ?? 0) }
        func total(_ prev: String) -> Int { Int(firsts[hash(prev)] ?? 0) }
        var isEmpty: Bool { pairs.isEmpty }

        /// How much more likely the word is after `prev` than anywhere (log ratio, smoothed, -3...4); 0 without `prev`.
        func lift(_ prev: String, _ word: String, share: Double) -> Double {
            let t = total(prev)
            guard !prev.isEmpty, t > 0 else { return 0 }
            let alpha = 5.0
            let p = (Double(count(prev, word)) + alpha * share) / (Double(t) + alpha)
            return min(4, max(-3, log(p / share)))
        }
    }

    // MARK: Ranking

    struct Candidate: Equatable { var word: String; var count: Int; var macRank: Int? }
    struct Scored { let word: String; let count: Int; let mac: Bool; let cost: Double; let share: Double; let ctx: Double; let score: Double }

    /// His count plus a prior for macOS's guesses (its first guess is worth ~20 of his uses), as a share of a fixed total.
    static let total = 200_000.0
    static func share(_ c: Candidate) -> Double {
        let mac: Double = c.macRank.map { $0 == 0 ? 20 : $0 == 1 ? 8 : 3 } ?? 0
        return (Double(c.count) + mac + 0.5) / total
    }

    /// Noisy channel: -cost (keyboard) + log share (how often the word is written) + context lift.
    static let costWeight = 1.6
    static func rank(_ typo: String, _ cands: [Candidate], prev: String, keyboard: TypoKeyboard, bigrams: Bigrams) -> [Scored] {
        var merged: [String: Candidate] = [:]
        for c in cands {
            var m = merged[c.word] ?? Candidate(word: c.word, count: 0, macRank: nil)
            m.count = max(m.count, c.count)
            if let r = c.macRank { m.macRank = min(m.macRank ?? r, r) }
            merged[c.word] = m
        }
        return merged.values.map { c in
            let cost = keyboard.cost(typo, c.word), s = share(c)
            let ctx = bigrams.lift(prev, c.word, share: s)
            return Scored(word: c.word, count: c.count, mac: c.macRank != nil, cost: cost, share: s, ctx: ctx,
                          score: -costWeight * cost + log(s) + ctx)
        }.sorted { $0.score == $1.score ? $0.word < $1.word : $0.score > $1.score }
    }

    // MARK: e. The gate and f. the outcome

    enum Outcome: String { case quiet, offer, fix }

    /// The numbers the gate sees (logged with each offer, no words): cost, his count, gap to the second, context,
    /// length, Ukrainian, AI app, chat app, a macOS guess.
    static let featureNames = ["cost", "count", "gap", "ctx", "len", "uk", "ai", "chat", "mac"]
    static func features(_ ranked: [Scored], typo: String, uk: Bool, appKind: String) -> [Double] {
        guard let b = ranked.first else { return [] }
        let gap = ranked.count > 1 ? min(6, b.score - ranked[1].score) : 6
        return [b.cost, log1p(Double(b.count)), gap, b.ctx, Double(typo.count), uk ? 1 : 0,
                appKind == "ai" ? 1 : 0, appKind == "chat" ? 1 : 0, b.mac ? 1 : 0]
    }

    struct Gate: Codable, Equatable {
        var bias: Double, weights: [Double], offerAt: Double, fixAt: Double, labels: Int
        func p(_ f: [Double]) -> Double {
            guard f.count == weights.count else { return 0 }
            let z = bias + zip(weights, f).reduce(0) { $0 + $1.0 * $1.1 }
            return 1 / (1 + exp(-z))
        }
        /// Hand-set, used until the nightly fit has 40 labels of his (engine/typos.py); fitted on the synthetic set.
        static let fallback = Gate(bias: 0.6, weights: [-1.5, 0.25, 0.45, 0.25, 0.1, -0.2, 0, 0, 0.5], offerAt: 0.6, fixAt: 0.95, labels: 0)
        init(bias: Double, weights: [Double], offerAt: Double, fixAt: Double, labels: Int) {
            self.bias = bias; self.weights = weights; self.offerAt = offerAt; self.fixAt = fixAt; self.labels = labels
        }
        /// data/typo-gate.json; the fallback when it is missing, broken or the wrong size.
        static func load(_ data: Data?) -> Gate {
            guard let data, let g = try? JSONDecoder().decode(Gate.self, from: data), g.weights.count == featureNames.count, g.labels >= 40 else { return fallback }
            return g
        }
    }

    /// Quiet below `offerAt`; offer from there; fix by itself only past `fixAt` and only where the setting lets it.
    static func outcome(_ p: Double, gate: Gate, mode: String) -> Outcome {
        guard p >= gate.offerAt else { return .quiet }
        if mode == "replace" || (mode == "sure" && p >= gate.fixAt) { return .fix }
        return .offer
    }
}
