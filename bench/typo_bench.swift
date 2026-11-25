// Typo fix bench (2026-11-15): today's macOS-only fix ("system") against the ranked fix, with the Mac's real
// spellchecker and no model. Prints numbers only; never prints or writes his words.
//   swiftc -O -parse-as-library app/TypoRules.swift app/TypoKeyboard.swift app/TypoRank.swift app/TypoDecide.swift app/CorrectionRules.swift app/Layout.swift bench/typo_bench.swift -o app/build/typo-bench
//   app/build/typo-bench DATA OUT synthetic|replay|latency     (OUT from bench/typo_prep.py; gate files read from OUT)
import AppKit

struct RNG { var s: UInt64; mutating func next() -> Double { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) } }

let args = CommandLine.arguments
let data = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2]), what = args.count > 3 ? args[3] : "synthetic"
func text(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
func json(_ u: URL) -> Any? { (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
let keyboard = TypoKeyboard(toUk: KeyLayout.maps.toUk.isEmpty ? TypoKeyboard.ukOf : KeyLayout.maps.toUk)
let names = Set(text(data.appendingPathComponent("known-words.txt")).split(separator: "\n").map { $0.lowercased() })
let keep = Set(((json(data.appendingPathComponent("autocorrect-keep.json")) as? [String: Int]) ?? [:]).filter { $0.value >= 2 }.keys)
let spell = { (w: String, l: String) in Spell.known(w, l) }
let noMac = ProcessInfo.processInfo.environment["TYPO_MAC"] == "0"
let guesses = { (w: String, l: String) -> [String] in
    noMac ? [] : NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (w as NSString).length), in: w, language: l, inSpellDocumentWithTag: 0) ?? []
}
func gate(_ name: String) -> TypoRank.Gate { TypoRank.Gate.load(try? Data(contentsOf: out.appendingPathComponent(name))) }
func typedRows() -> [(t: Double, text: String)] {
    text(data.appendingPathComponent("typed.jsonl")).split(separator: "\n").compactMap { l in
        guard let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let t = j["t"] as? Double, let s = j["text"] as? String,
              !s.contains("⟦drafter-test⟧") else { return nil }
        return (t, s)
    }
}
struct Ctx { let known: (String) -> Bool; let own: CorrectionRules.Index; let tables: TypoDecide.Tables }
func context(counts: [String: Int], bigrams: String, gate g: TypoRank.Gate) -> Ctx {
    let mine = Set(counts.filter { $0.value >= 3 }.keys)
    return Ctx(known: { mine.contains($0) || names.contains($0) || keep.contains($0) }, own: CorrectionRules.Index(counts),
               tables: .init(index: .init(counts.filter { $0.value >= 3 }), bigrams: .init(tsv: bigrams), keyboard: keyboard, gate: g))
}
func system(_ core: String, _ c: Ctx) -> String? {
    TypoDecide.system(core, uk: TypoRules.isUkrainian(core), known: c.known, spellKnown: spell, correction: { w, l in Spell.correction(w, l) }, ownIndex: c.own)
}
func ranked(_ core: String, prev: String, _ c: Ctx, mode: String = "offer") -> TypoDecide.Decision? {
    TypoDecide.ranked(core, prev: prev, appKind: "ai", mode: mode, known: c.known, spell: spell, guesses: guesses, tables: c.tables, lazy: ProcessInfo.processInfo.environment["TYPO_LAZY"] != "0")
}
/// (core, previous word) for every token of a line.
func tokens(_ s: String) -> [(core: String, prev: String)] {
    var prev = "", outv: [(String, String)] = []
    for line in s.components(separatedBy: "\n") {
        prev = ""
        for tok in line.split(separator: " ").map(String.init) {
            if let c = TypoRules.core(tok) { outv.append((c.core, prev)); prev = c.core } else { prev = tok.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            if tok.last.map({ ".!?".contains($0) }) ?? false { prev = "" }
        }
    }
    return outv
}

// MARK: synthetic slips
let enLetters = Array("abcdefghijklmnopqrstuvwxyz"), ukLetters = Array("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя")
func slip(_ w: String, _ r: inout RNG) -> (String, String) {
    var c = Array(w)
    let letters = TypoRules.isUkrainian(w) ? ukLetters : enLetters
    let i = 1 + Int(r.next() * Double(c.count - 1))           // the first letter is rarely hit
    let roll = r.next()
    if roll < 0.30 {                                             // a neighbour key
        let near = letters.filter { keyboard.near(c[i], $0) }
        guard !near.isEmpty else { return (w, "none") }
        c[i] = near[Int(r.next() * Double(near.count))]; return (String(c), "neighbour")
    } else if roll < 0.50 {                                      // two letters swapped
        let j = min(i, c.count - 2); guard j >= 1, c[j] != c[j + 1] else { return (w, "none") }
        c.swapAt(j, j + 1); return (String(c), "swap")
    } else if roll < 0.68 {                                      // a letter missing (a double one if there is)
        if let d = (1..<c.count).first(where: { c[$0] == c[$0 - 1] }) { c.remove(at: d); return (String(c), "dropped double") }
        c.remove(at: i); return (String(c), "missing")
    } else if roll < 0.80 {                                      // a letter doubled
        c.insert(c[i], at: i); return (String(c), "doubled")
    } else if roll < 0.90 {                                      // an extra neighbour key
        let near = letters.filter { keyboard.near(c[i], $0) }
        guard !near.isEmpty else { return (w, "none") }
        c.insert(near[Int(r.next() * Double(near.count))], at: i); return (String(c), "extra")
    } else {                                                     // apostrophe or і/ї/є/ґ, else a far key
        if let a = c.firstIndex(where: { TypoRules.apostrophes.contains($0) }) { c.remove(at: a); return (String(c), "apostrophe") }
        if let t = c.firstIndex(where: { "їєґ".contains($0) }) { c[t] = ["ї": "і", "є": "е", "ґ": "г"][c[t]]!; return (String(c), "letter twin") }
        let far = letters.filter { !keyboard.near(c[i], $0) && $0 != c[i] }
        c[i] = far[Int(r.next() * Double(far.count))]; return (String(c), "wrong key")
    }
}

final class Tally { var n: [String: [String: Int]] = [:]; func add(_ row: String, _ col: String) { n[row, default: [:]][col, default: 0] += 1 }
    func print(_ title: String) { Swift.print("## \(title)"); for (k, v) in n.sorted(by: { $0.key < $1.key }) { Swift.print("  \(k): " + v.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) } } }

func synthetic() {
    let cutoff = ((json(out.appendingPathComponent("events.json")) as? [String: Any])?["cutoff"] as? Double) ?? 0
    let counts = (json(out.appendingPathComponent("counts-held.json")) as? [String: Int]) ?? [:]
    let c = context(counts: counts, bigrams: text(out.appendingPathComponent("bigrams-held.tsv")), gate: gate("gate-synth.json"))
    var r = RNG(s: 42)
    let t = Tally(), byKind = Tally(), clean = Tally()
    var feats = ""
    var trade: [(p: Double, right: Bool)] = []
    for row in typedRows() where row.t >= cutoff {
        for (core, prev) in tokens(row.text) {
            let lang = TypoRules.isUkrainian(core) ? "uk" : "en"
            // clean words, as he typed them: any change is a word wrongly changed
            clean.add("\(lang) words", "n")
            if system(core, c) != nil { clean.add("\(lang) words", "system changed") }
            if let d = ranked(core, prev: prev, c) {
                feats += d.features.map { String($0) }.joined(separator: ",") + ",0,clean\n"
                if d.outcome != .quiet { clean.add("\(lang) words", "ranked changed") }
                trade.append((d.p, false))
            }
            guard core.count >= 4, TypoRules.isWord(core, known: c.known, spell: spell), r.next() < 0.35 else { continue }
            let (typo, kind) = slip(core, &r)
            guard kind != "none", typo != core else { continue }
            if TypoRules.isWord(typo, known: c.known, spell: spell) { t.add(lang, "slip made a real word"); continue }
            t.add(lang, "slips"); byKind.add(kind, "slips")
            let s = system(typo, c)
            t.add(lang, s == core ? "system right" : s == nil ? "system quiet" : "system wrong")
            byKind.add(kind, s == core ? "system right" : s == nil ? "system quiet" : "system wrong")
            let d = ranked(typo, prev: prev, c)
            let shown = d.map { $0.outcome != .quiet } ?? false
            let res = !shown ? "ranked quiet" : d?.word == core ? "ranked right" : "ranked wrong"
            t.add(lang, res); byKind.add(kind, res)
            if d?.word == core { t.add(lang, "ranked top1 right (before gate)") }
            if let d { feats += d.features.map { String($0) }.joined(separator: ",") + ",\(d.word == core ? 1 : 0),slip\n"; trade.append((d.p, d.word == core)) }
        }
    }
    try? feats.write(to: out.appendingPathComponent("synthetic-features.csv"), atomically: true, encoding: .utf8)
    t.print("synthetic slips by language"); byKind.print("synthetic slips by kind"); clean.print("clean words")
    print("## gate trade (synthetic: slips + clean words that got a candidate)")
    for at in [0.5, 0.6, 0.7, 0.8, 0.9] {
        let shown = trade.filter { $0.p >= at }
        print("  at \(at): shown \(shown.count), right \(shown.filter { $0.right }.count) (\(shown.isEmpty ? 0 : 100 * shown.filter { $0.right }.count / shown.count)%)")
    }
}

/// Edits of a word one slip away (all letters of its script), for finding what he may have typed.
func edits(_ w: String) -> Set<String> {
    let c = Array(w), letters = (TypoRules.isUkrainian(w) ? ukLetters : enLetters) + ["'"]
    var s = Set<String>()
    for i in 0...c.count {
        if i < c.count { s.insert(String(c[..<i] + c[(i + 1)...])) }
        if i + 1 < c.count { var d = c; d.swapAt(i, i + 1); s.insert(String(d)) }
        for l in letters {
            if i < c.count { var d = c; d[i] = l; s.insert(String(d)) }
            var e = c; e.insert(l, at: i); s.insert(String(e))
        }
    }
    s.remove(w); return s
}

func replay() {
    var counts = (json(data.appendingPathComponent("myword-counts.json")) as? [String: Int]) ?? [:]
    for w in text(data.appendingPathComponent("mywords.txt")).split(separator: "\n") where counts[String(w)] == nil { counts[String(w)] = 3 }
    let c = context(counts: counts, bigrams: text(out.appendingPathComponent("bigrams-all.tsv")), gate: gate("gate-history.json"))
    let rows = typedRows().sorted { $0.t < $1.t }
    let autos = ((json(out.appendingPathComponent("events.json")) as? [String: Any])?["autos"] as? [[String: Any]]) ?? []
    let t = Tally()
    var feats = ""
    for e in autos where (e["kind"] as? String) == "typo" {
        guard let at = e["t"] as? Double, let n = e["n"] as? Int, let m = e["m"] as? Int, let outcome = e["out"] as? String else { continue }
        let label = outcome.hasPrefix("taken back") || outcome == "undone later" ? "taken back" : outcome
        t.add(label, "events")
        guard let row = rows.first(where: { $0.t >= at && $0.t <= at + 600 }) else { t.add(label, "no sent line"); continue }
        var stood: [(String, String, String)] = [], fixed: [(String, String, String)] = []   // (typo, word, prev)
        var prev = ""
        for tok in row.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) {
            defer { prev = TypoRules.core(tok)?.core ?? "" }
            guard let p = TypoRules.core(tok) else { continue }
            let extra = p.lead.count + p.tail.count + 1
            if p.core.count + extra == n, let f = system(p.core, c), f.count + extra == m { stood.append((p.core, f, prev)) }
            if p.core.count + extra == m, TypoRules.isWord(p.core, known: c.known, spell: spell) {
                let typos = edits(p.core).filter { $0.count + extra == n && $0.first == p.core.first && system($0, c) == p.core }
                if let best = typos.min(by: { keyboard.cost($0, p.core) < keyboard.cost($1, p.core) }) { fixed.append((best, p.core, prev)) }
            }
        }
        if stood.count == 1 && fixed.isEmpty {
            t.add(label, "his word stood")
            let (typo, _, pv) = stood[0], d = ranked(typo, prev: pv, c)
            t.add(label, d.map { $0.outcome != .quiet } ?? false ? "stood: ranked still offers" : "stood: ranked quiet")
            if let d { feats += d.features.map { String($0) }.joined(separator: ",") + ",0,\(label)\n" }
        } else if fixed.count == 1 && stood.isEmpty {
            t.add(label, "fixed word stood")
            let (typo, word, pv) = fixed[0], d = ranked(typo, prev: pv, c)
            t.add(label, d.map { $0.outcome != .quiet && $0.word == word } ?? false ? "fixed: ranked offers it" : d.map { $0.outcome != .quiet } ?? false ? "fixed: ranked offers another" : "fixed: ranked quiet")
            if let d { feats += d.features.map { String($0) }.joined(separator: ",") + ",\(d.word == word ? 1 : 0),\(label)\n" }
        } else { t.add(label, "unclear") }
    }
    try? feats.write(to: out.appendingPathComponent("replay-features.csv"), atomically: true, encoding: .utf8)
    t.print("replay of his automatic typo fixes (label from the sent line)")
}

func latency() {
    var counts = (json(data.appendingPathComponent("myword-counts.json")) as? [String: Int]) ?? [:]
    for w in text(data.appendingPathComponent("mywords.txt")).split(separator: "\n") where counts[String(w)] == nil { counts[String(w)] = 3 }
    let t0 = Date()
    let c = context(counts: counts, bigrams: text(out.appendingPathComponent("bigrams-all.tsv")), gate: .fallback)
    print("tables built in \(Int(Date().timeIntervalSince(t0) * 1000)) ms; delete index \(c.tables.index.count) entries (~\(c.tables.index.count * 12 / 1_000_000) MB); bigrams \(c.tables.bigrams.pairs.count)")
    var r = RNG(s: 7), word: [Double] = [], typo: [Double] = [], sys: [Double] = [], sysTypo: [Double] = [], mac: [Double] = [], corr: [Double] = [], look: [Double] = []
    for row in typedRows().suffix(400) {
        for (core, prev) in tokens(row.text) {
            var s = Date(); _ = ranked(core, prev: prev, c); word.append(Date().timeIntervalSince(s) * 1000)
            s = Date(); _ = system(core, c); sys.append(Date().timeIntervalSince(s) * 1000)
            if core.count >= 4 {
                let (x, _) = slip(core, &r); s = Date(); _ = ranked(x, prev: prev, c); typo.append(Date().timeIntervalSince(s) * 1000)
                s = Date(); _ = system(x, c); sysTypo.append(Date().timeIntervalSince(s) * 1000)
                s = Date(); _ = guesses(x, TypoRules.isUkrainian(x) ? "uk" : "en"); mac.append(Date().timeIntervalSince(s) * 1000)
                s = Date(); _ = Spell.correction(x, TypoRules.isUkrainian(x) ? "uk" : "en"); corr.append(Date().timeIntervalSince(s) * 1000)
                s = Date(); _ = c.tables.index.lookup(x, maxDistance: x.count >= 8 ? 2 : 1); look.append(Date().timeIntervalSince(s) * 1000)
            }
        }
    }
    func q(_ v: [Double], _ p: Double) -> String { let s = v.sorted(); return s.isEmpty ? "-" : String(format: "%.2f", s[min(s.count - 1, Int(Double(s.count) * p))]) }
    for (name, v) in [("ranked, words as typed", word), ("ranked, slipped words", typo), ("system, words as typed", sys), ("system, slipped words", sysTypo), ("macOS guesses alone", mac), ("macOS correction alone", corr), ("delete index alone", look)] {
        print("\(name): n \(v.count), p50 \(q(v, 0.5)) ms, p95 \(q(v, 0.95)) ms, max \(q(v, 1)) ms")
    }
}

@main struct Bench { static func main() { switch what { case "replay": replay(); case "latency": latency(); default: synthetic() } } }
