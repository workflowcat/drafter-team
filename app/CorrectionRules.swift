// Pure correction choices and take-back migration. No app or spellchecker starts here.
import Foundation

enum CorrectionRules {
    static func counts(legacy: String, saved: [String: Int]) -> [String: Int] {
        var out = saved.reduce(into: [String: Int]()) { result, pair in
            result[pair.key.lowercased()] = max(result[pair.key.lowercased()] ?? 0, pair.value)
        }
        for word in legacy.split(whereSeparator: { $0.isNewline }) {
            let w = word.trimmingCharacters(in: .whitespaces).lowercased()
            if !w.isEmpty { out[w] = max(out[w] ?? 0, 1) }
        }
        return out
    }
    static func takeBack(_ word: String, counts: inout [String: Int]) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: .punctuationCharacters).lowercased()
        if !w.isEmpty { counts[w, default: 0] += 1 }
    }
    static func kept(_ counts: [String: Int]) -> Set<String> { Set(counts.filter { $0.value >= 2 }.keys) }

    struct Index {
        let buckets: [Character: [Int: [String: Int]]]
        init(_ counts: [String: Int]) {
            var b: [Character: [Int: [String: Int]]] = [:]
            for (word, count) in counts where count >= 5 && word == word.lowercased() && word.allSatisfy({ $0.isLetter || "'’ʼ".contains($0) }) {
                if let first = word.first { b[first, default: [:]][word.count, default: [:]][word] = count }
            }
            buckets = b
        }
    }
    static func eligible(_ typo: String, _ word: String, ukrainian: Bool) -> Bool {
        let limit = ukrainian || typo.count < 7 ? 1 : 2
        guard word != typo, word.first == typo.first, word.count >= typo.count - 1,
              abs(word.count - typo.count) <= limit,
              !word.unicodeScalars.contains(where: { "ыэъёЫЭЪЁ".unicodeScalars.contains($0) }),
              typo.count > 3 || (word.count == 3 && word.sorted() == typo.sorted()) else { return false }
        return (1...limit).contains(distance(typo, word))
    }
    static func candidate(_ typo: String, counts: [String: Int], ukrainian: Bool = false) -> String? {
        candidate(typo, index: Index(counts), ukrainian: ukrainian)
    }
    static func candidate(_ typo: String, index: Index, ukrainian: Bool = false) -> String? {
        guard typo.count >= 3, typo.count <= 24, typo == typo.lowercased(),
              typo.allSatisfy({ $0.isLetter || "'’ʼ".contains($0) }), let first = typo.first else { return nil }
        let limit = ukrainian || typo.count < 7 ? 1 : 2
        let bucket = index.buckets[first] ?? [:]
        var ranked: [(word: String, count: Int, distance: Int, apostrophe: Bool)] = []
        for length in (typo.count - 1)...(typo.count + limit) {
            for (word, count) in bucket[length] ?? [:] where eligible(typo, word, ukrainian: ukrainian) {
                let stripped = String(word.filter { !"'’ʼ".contains($0) })
                ranked.append((word, count, distance(typo, word), stripped == typo))
            }
        }
        // An observed apostrophe form wins; otherwise edit distance wins before frequency.
        let apostrophes = ranked.filter { $0.apostrophe }
        if !apostrophes.isEmpty { ranked = apostrophes }
        guard let nearest = ranked.map({ $0.distance }).min() else { return nil }
        ranked = ranked.filter { $0.distance == nearest }.sorted { $0.count == $1.count ? $0.word < $1.word : $0.count > $1.count }
        guard let best = ranked.first, ranked.count == 1 || best.count >= 3 * ranked[1].count else { return nil }
        return best.word
    }

    /// Only whitespace changes may bypass a protected piece, with a verified joined word.
    static func spacing(_ old: String, _ new: String, word: (String) -> Bool) -> Bool {
        let a = old.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let b = new.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return a.count != b.count && a.count + b.count <= 4 && a.joined() == b.joined() && word(a.joined())
    }
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var d = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count { for j in 1...y.count {
            d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1] + (x[i-1] == y[j-1] ? 0 : 1))
            if i > 1, j > 1, x[i-1] == y[j-2], x[i-2] == y[j-1] { d[i][j] = min(d[i][j], d[i-2][j-2]+1) }
        } }
        return d[x.count][y.count]
    }
}
