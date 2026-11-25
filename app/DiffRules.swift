// Word-level before/after diff for the journal reader (edited items and cleaned voice takes).
// Pure Foundation: compiles standalone for tests/diff_rules.swift.
import Foundation

enum DiffKind: Equatable, Hashable {
    case same
    case removed
    case added
}

struct DiffSegment: Equatable, Hashable {
    let kind: DiffKind
    let text: String
}

enum DiffRules {
    /// Safe per-side token limit for the exact O(m*n) LCS table; above this, fall back to O(n) prefix/suffix diff.
    static let maxTokens = 600

    private static func isWordCore(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    private static func isApostrophe(_ ch: Character) -> Bool {
        ch == "'" || ch == "\u{2019}" || ch == "\u{02BC}"
    }

    /// Lossless tokenizer for Ukrainian (Cyrillic) and English text:
    /// - words keep internal apostrophes (e.g. "ім'я", "компʼютер", "don't")
    /// - horizontal whitespace stays grouped, newlines stay separate tokens
    /// - punctuation and symbols stay single tokens so punctuation edits diff cleanly
    static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let chars = Array(text)
        let n = chars.count
        var out: [String] = []
        out.reserveCapacity(max(8, n / 4))
        var i = 0
        while i < n {
            let ch = chars[i]
            if isWordCore(ch) {
                let start = i
                i += 1
                while i < n {
                    if isWordCore(chars[i]) {
                        i += 1
                    } else if isApostrophe(chars[i]), i + 1 < n, isWordCore(chars[i + 1]) {
                        i += 2
                    } else {
                        break
                    }
                }
                out.append(String(chars[start..<i]))
            } else if ch.isNewline {
                out.append(String(ch))
                i += 1
            } else if ch.isWhitespace {
                let start = i
                i += 1
                while i < n, chars[i].isWhitespace, !chars[i].isNewline { i += 1 }
                out.append(String(chars[start..<i]))
            } else {
                out.append(String(ch))
                i += 1
            }
        }
        return out
    }

    /// True if a token contains at least one letter or digit (not pure whitespace or punctuation).
    static func isWord(_ token: String) -> Bool {
        token.contains(where: isWordCore)
    }

    /// Bounded word-level LCS diff with adjacent-segment coalescing and a fast fallback for huge texts.
    static func diff(before: String, after: String, limit: Int = maxTokens) -> [DiffSegment] {
        if before == after {
            return before.isEmpty ? [] : [DiffSegment(kind: .same, text: before)]
        }
        if before.isEmpty { return [DiffSegment(kind: .added, text: after)] }
        if after.isEmpty { return [DiffSegment(kind: .removed, text: before)] }

        let a = tokenize(before)
        let b = tokenize(after)

        var prefix = 0
        let minCount = min(a.count, b.count)
        while prefix < minCount, a[prefix] == b[prefix] { prefix += 1 }

        var suffix = 0
        let remA = a.count - prefix
        let remB = b.count - prefix
        let maxSuffix = min(remA, remB)
        while suffix < maxSuffix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var out: [DiffSegment] = []
        func push(_ kind: DiffKind, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.kind == kind {
                out[out.count - 1] = DiffSegment(kind: kind, text: last.text + text)
            } else {
                out.append(DiffSegment(kind: kind, text: text))
            }
        }

        if prefix > 0 { push(.same, a[0..<prefix].joined()) }

        let safeLimit = max(1, limit)
        if midA.isEmpty {
            push(.added, midB.joined())
        } else if midB.isEmpty {
            push(.removed, midA.joined())
        } else if midA.count > safeLimit || midB.count > safeLimit {
            // Fast O(n) fallback so huge pastes never hang the UI.
            push(.removed, midA.joined())
            push(.added, midB.joined())
        } else {
            let m = midA.count
            let n = midB.count
            let cols = n + 1
            var dp = [Int32](repeating: 0, count: (m + 1) * cols)
            for i in stride(from: m - 1, through: 0, by: -1) {
                let row = i * cols
                let nextRow = (i + 1) * cols
                let tokenA = midA[i]
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if tokenA == midB[j] {
                        dp[row + j] = dp[nextRow + j + 1] + 1
                    } else {
                        let down = dp[nextRow + j]
                        let right = dp[row + j + 1]
                        dp[row + j] = down >= right ? down : right
                    }
                }
            }
            var i = 0, j = 0
            while i < m && j < n {
                if midA[i] == midB[j] {
                    push(.same, midA[i])
                    i += 1; j += 1
                } else if dp[(i + 1) * cols + j] >= dp[i * cols + j + 1] {
                    push(.removed, midA[i])
                    i += 1
                } else {
                    push(.added, midB[j])
                    j += 1
                }
            }
            while i < m { push(.removed, midA[i]); i += 1 }
            while j < n { push(.added, midB[j]); j += 1 }
        }

        if suffix > 0 { push(.same, a[(a.count - suffix)...].joined()) }
        return out
    }

    /// Counts changed words (excluding pure whitespace and punctuation) across diff segments.
    static func stats(_ parts: [DiffSegment]) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for part in parts {
            switch part.kind {
            case .same:
                break
            case .added:
                added += tokenize(part.text).filter(isWord).count
            case .removed:
                removed += tokenize(part.text).filter(isWord).count
            }
        }
        return (added, removed)
    }
}
