// Typography as you type (15 November 2026, spec: docs/research/2026-11-15-build-deep-dive.md section 7). Pure: no
// AppKit, no files. Given the text before the caret (without the key just typed), the key and whether the text is
// Ukrainian, `swap` says how many characters before the caret to take out and what goes in instead of them and the
// key. app/Typography.swift reads the field after the key landed and writes the swap; Backspace right after puts
// `plain` back. Tested by tests/typography_rules.swift.
//
// Firing rules (each combo fires on the key that completes it, so nothing waits on a timer):
//   --        lazy: on the key AFTER the two hyphens, so a CLI flag stays. A letter or digit right after `--` keeps
//             `--` when the hyphens start a token (line start, after a space or an opening bracket: `--verbose`);
//             after a word (`word--word`) it is a dash. Space or punctuation after `--` makes it `—`. A third hyphen
//             (`---`) and `-->` never swap. So `--` at the very end of a message stays `--` (no key came after it).
//   ` - `     on the space after the hyphen, when a letter or closing punctuation is before ` -` (not a digit: `5 - 3`
//             is a minus, `2020 - 2021` a range).
//   ...       on the third dot, not after a digit (`1...5`), not a fourth dot.
//   "         on the key: open after line start, a space or an opening bracket/dash, else close. Ukrainian «», a quote
//             opened inside «» is „“; English “”. After a digit it stays (5'10" is inches).
//   '         on the next letter: between two Ukrainian letters it becomes ʼ (or ’, a setting).
//   -> <-     on `>` / `-`; `<-` then `>` is ↔. `-->` and `<!--` stay.
//   +-  NxN   ± on `-`; × on the digit after `x` or `х` that follows a digit (`0x1F` stays: hex).
//   (c) (r) (tm)  on `)` when `(` starts a token; Cyrillic `(с)` too.
//   N грн     ₴ on the space or punctuation after `грн` that follows a number (off by default).
//   і в у з а о   + space: a no-break space after the one-letter word (off by default).
// Never: inside inline code or a ``` block, and never when the token the combo belongs to looks like code, a URL, an
// email or a path (`://`, `www.`, `@`, `/`, `\`, `_`, `=`, brackets, `<`, `>`, `|`, `$`, `~`, `` ` ``, a dot before 2+
// letters as in `file.md`). Code apps, terminals, password fields and secure input are the caller's guards.
import Foundation

struct TypoSwap: Equatable {
    let kind: String     // dash, spaced dash, ellipsis, quote, apostrophe, arrow, plus-minus, times, symbol, hryvnia, nbsp
    let remove: Int      // characters of `before` to take out (the key itself is not in `before`)
    let insert: String   // what goes in for those characters and the key
    let plain: String    // what he typed: the removed characters and the key; Backspace right after puts these back
}

struct TypoOptions: Equatable {
    var dash = true, spacedDash = true, ellipsis = true, quotes = true, apostrophe = true
    var apostropheMark: Character = "ʼ"   // U+02BC; the setting may pick ’ (U+2019)
    var arrows = true, math = true, symbols = true
    var hryvnia = false, nbsp = false
}

enum TypoGraphRules {
    static let cyrillic: Set<Character> = Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюяАБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯ")
    static let opening: Set<Character> = ["(", "[", "«", "„", "‘", "—", "–"]
    static let closing: Set<Character> = [")", "»", "”", "“", "\"", "’", "'", "…", "!", "?"]
    static let oneLetter: Set<Character> = Set("івузаоІВУЗАО")

    /// The swap for `key` typed after `before`, or nil (the key stays as it is).
    static func swap(before raw: String, key: String, ukrainian: Bool, options o: TypoOptions = TypoOptions()) -> TypoSwap? {
        guard key.count == 1, let k = key.first else { return nil }
        let before = raw.replacingOccurrences(of: "\u{A0}", with: " ")
        if inCode(before) { return nil }
        let line = String(before.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        let token = String(line.reversed().prefix { !$0.isWhitespace }.reversed())
        let chars = Array(line)
        func at(_ back: Int) -> Character? { chars.count >= back ? chars[chars.count - back] : nil }   // 1 = last
        func clean(_ drop: Int) -> Bool { !codeLike(String(token.dropLast(drop))) }
        func make(_ kind: String, _ remove: Int, _ insert: String) -> TypoSwap {
            TypoSwap(kind: kind, remove: remove, insert: insert, plain: String(chars.suffix(remove)) + key)
        }

        // `--` decided on the next key (see the header)
        if o.dash, line.hasSuffix("--"), at(3) != "-" {
            if k == "-" || k == ">" { return nil }
            let p = at(3)
            let startsToken = p == nil || p!.isWhitespace || opening.contains(p!) || p == "\"" || p == "'"
            if k.isLetter || k.isNumber {
                return startsToken || !clean(2) ? nil : make("dash", 2, "—" + key)
            }
            return clean(2) ? make("dash", 2, "—" + key) : nil
        }

        switch k {
        case " ":
            if o.spacedDash, line.hasSuffix(" -"), let p = at(3), p.isLetter || closing.contains(p), clean(1),
               !codeLike(lastWord(String(line.dropLast(2)))) {
                return make("spaced dash", 1, "— ")
            }
            if o.hryvnia, let s = hryvnia(line) { return make("hryvnia", 3, "₴" + key + s) }
            if o.nbsp, let w = at(1), oneLetter.contains(w), at(2).map({ $0.isWhitespace || opening.contains($0) || "\"«„“(".contains($0) }) ?? true {
                return make("nbsp", 0, "\u{A0}")
            }
        case ".", ",", ";", ":", "!", "?", ")":
            if o.hryvnia, let s = hryvnia(line) { return make("hryvnia", 3, "₴" + key + s) }
            if k == ".", o.ellipsis, line.hasSuffix(".."), at(3) != ".", !(at(3)?.isNumber ?? false), clean(2) {
                return make("ellipsis", 2, "…")
            }
            if k == ")", o.symbols {
                let low = token.lowercased()
                let table: [(String, String)] = [("(tm", "™"), ("(c", "©"), ("(с", "©"), ("(r", "®")]
                for (t, sym) in table where low == t {
                    return make("symbol", t.count, sym)
                }
            }
        case "-":
            if o.math, at(1) == "+", at(2) != "+", clean(1) { return make("plus-minus", 1, "±") }
            if o.arrows, at(1) == "<", at(2) != "<", at(2) != "!", clean(1) { return make("arrow", 1, "←") }
        case ">":
            if o.arrows, at(1) == "-", at(2) != "-", at(2) != "=", clean(1) { return make("arrow", 1, "→") }
            if o.arrows, at(1) == "←" { return make("arrow", 1, "↔") }
        case "\"":
            guard o.quotes, !(at(1)?.isNumber ?? false), clean(0) else { return nil }
            let open = at(1).map { $0.isWhitespace || opening.contains($0) } ?? true
            if !ukrainian { return make("quote", 0, open ? "“" : "”") }
            var stack: [Character] = []
            for c in line {
                switch c {
                case "«", "„": stack.append(c)
                case "»": if stack.last == "«" { stack.removeLast() }
                case "“": if stack.last == "„" { stack.removeLast() }
                default: break
                }
            }
            if open { return make("quote", 0, stack.last == "«" ? "„" : "«") }
            return make("quote", 0, stack.last == "„" ? "“" : "»")
        default:
            if o.apostrophe, cyrillic.contains(k), at(1) == "'", let p = at(2), cyrillic.contains(p) {
                return make("apostrophe", 1, String(o.apostropheMark) + key)
            }
            if o.math, k.isNumber, k.isASCII, let x = at(1), x == "x" || x == "х" {
                let digits = String(line.dropLast().reversed().prefix { $0.isNumber && $0.isASCII }.reversed())
                let lead = line.dropLast(1 + digits.count).last
                if !digits.isEmpty, digits != "0", !(lead?.isLetter ?? false), lead != "_" { return make("times", 1, "×" + key) }
            }
        }
        return nil
    }

    /// `N грн` (a number, a space, грн) at the line end: "" when it fits (the suffix to add after the key), else nil.
    static func hryvnia(_ line: String) -> String? {
        guard line.hasSuffix("грн") else { return nil }
        let head = Array(line.dropLast(3))
        guard head.count >= 2, head[head.count - 1] == " ", head[head.count - 2].isNumber else { return nil }
        return ""
    }

    /// The last whitespace-separated word of `s`.
    static func lastWord(_ s: String) -> String { String(s.reversed().prefix { !$0.isWhitespace }.reversed()) }

    /// A token that is code, a URL, an email or a path: never touched.
    static func codeLike(_ token: String) -> Bool {
        if token.isEmpty { return false }
        if token.contains("://") || token.lowercased().hasPrefix("www.") { return true }
        if token.contains(where: { "@/\\_={}[]<>|$~`".contains($0) }) { return true }
        // a dot followed by 2+ letters or digits: file.md, example.com (not e.g. or т.д.)
        let c = Array(token)
        for i in c.indices where c[i] == "." && i > 0 && i + 2 < c.count {
            if c[i + 1].isLetter || c[i + 1].isNumber, c[i + 2].isLetter || c[i + 2].isNumber, c[i - 1].isLetter || c[i - 1].isNumber { return true }
        }
        return false
    }

    /// The caret is inside code: an open ``` block above it, or an odd number of backticks on its line.
    static func inCode(_ before: String) -> Bool {
        if before.components(separatedBy: "```").count % 2 == 0 { return true }
        let line = before.components(separatedBy: "\n").last ?? ""
        return line.filter { $0 == "`" }.count % 2 == 1
    }

    /// The text is Ukrainian: more Cyrillic than Latin letters in its last 200 characters; nil = no letters (the caller
    /// then asks the keyboard layout).
    static func ukrainian(_ before: String) -> Bool? {
        var cyr = 0, lat = 0
        for ch in before.suffix(200) where ch.isLetter {
            if cyrillic.contains(ch) { cyr += 1 } else if ch.isASCII { lat += 1 }
        }
        if cyr == 0 && lat == 0 { return nil }
        return cyr >= lat
    }

    /// Worth reading the field for this key, from the last few keys typed (no field read on most keys).
    static func mayFire(recent: String, key: String) -> Bool {
        guard let k = key.first, key.count == 1 else { return false }
        if "\"->.)".contains(k) || k == " " { return true }
        if recent.hasSuffix("--") { return true }
        if k.isNumber { return recent.last == "x" || recent.last == "х" }
        if k.isLetter { return recent.last == "'" }
        if ",;:!?".contains(k) { return recent.hasSuffix("грн") }
        return false
    }

    // MARK: take-back

    /// Backspace is the very next key after the swap (`rev` = the edit revision at the swap), soon enough.
    static func takeBack(rev: Int, swapRev: Int, now: Double, at: Double) -> Bool {
        rev == swapRev + 1 && now >= at && now - at < 8
    }

    /// The field still ends with what the swap put in (a no-break space reads as a space).
    static func stillEnds(before: String, insert: String) -> Bool {
        let b = before.replacingOccurrences(of: "\u{A0}", with: " "), i = insert.replacingOccurrences(of: "\u{A0}", with: " ")
        return !i.isEmpty && b.hasSuffix(i)
    }
}
