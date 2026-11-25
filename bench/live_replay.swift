import Foundation

// swiftc -parse-as-library app/LiveType.swift bench/live_replay.swift -o app/build/live-replay && app/build/live-replay DRAFTS.json
// Replays recorded drafts (bench/live_drafts.py, made-up takes only) through the live typing rule before 2026-11-14 and
// the new one (app/LiveType.swift), on a pretend field. Prints numbers only: how far the field is behind the strip,
// what lands at the end in one go, what the end fix costs, and whether the field ends up holding the final text.
// Raw drafts (no Tidy clean-up): both rules see the same text.

struct Take: Decodable { let name: String; let secs: Double; let speech: Double?; let drafts: [[Draft]]; let final: String; let end: Double }
enum Draft: Decodable {
    case t(Double), s(String), none
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let x = try? c.decode(Double.self) { self = .t(x) } else if let x = try? c.decode(String.self) { self = .s(x) } else { self = .none }
    }
    var num: Double? { if case .t(let x) = self { return x }; return nil }
    var str: String? { if case .s(let x) = self { return x }; return nil }
}

struct Result {
    var meter = LiveType.Meter()
    var firstField: Double?
    var duringWords = 0, endBurst = 0, endKeys = 0, endTouched = 0, kept = false, fieldOK = false, midFixes = 0
}

func ms(_ x: Double?) -> String { x.map { String(Int(($0 * 1000).rounded())) } ?? "-" }

/// The rule as it was: two drafts agree, minus the last two words; a typed word that changed stops the run until the end.
func old(_ take: Take) -> Result {
    var r = Result(), prev: [Substring] = [], settled = "", inserted = 0, field = "", stripPrev: [Substring] = []
    func common(_ a: String, _ b: String) -> Int { LiveType.common(a, b) }
    for d in take.drafts {
        guard let t = d[0].num, let text = d[1].str else { continue }
        let words = text.split(separator: " ")
        r.meter.saw(words: words.count, at: t)
        let sn = LiveType.steady(stripPrev, words, still: 0); stripPrev = words
        if sn > 0 { r.meter.settled(words: sn, at: t) }
        var n = 0
        while n < min(prev.count, words.count), prev[n] == words[n] { n += 1 }
        prev = words
        n = min(n, words.count - 2)
        guard n > 0 else { continue }
        let s = words[0..<n].joined(separator: " ")
        if s.hasPrefix(settled) || common(settled, s) >= inserted { settled = s }
        if settled.count > inserted {
            field += String(settled.dropFirst(inserted)); inserted = settled.count
            if r.firstField == nil { r.firstField = t }
            r.meter.typed(words: field.split(separator: " ").count, at: t)
        }
    }
    r.duringWords = field.split(separator: " ").count
    let final = take.final, done = field
    if final.hasPrefix(done) {
        let rest = String(final.dropFirst(done.count)); field += rest; r.endBurst = rest.count
    } else {
        let c = common(done, final), back = done.count - c
        if back <= 40, final.count >= done.count * 8 / 10 {
            field = String(field.dropLast(back)) + String(final.dropFirst(c))
            r.endKeys = back + (final.count - c); r.endTouched = back + (final.count - c); r.endBurst = final.count - c
        } else {
            let k = done.split(separator: " ").count
            let rest = final.split(separator: " ").dropFirst(k).joined(separator: " ")
            field += (rest.isEmpty ? "" : " " + rest); r.endBurst = rest.count + 1; r.kept = true
        }
    }
    r.fieldOK = field == final || LiveType.onlyMarks(field, final)
    return r
}

/// The new rule: the strip's steady words, small fixes near the caret, the rest of the fixes at the end.
func new(_ take: Take) -> Result {
    var r = Result(), prev: [Substring] = [], run = "", field = "", still = 0, last = "", landed = 0
    for d in take.drafts {
        guard let t = d[0].num, let text = d[1].str else { continue }
        still = text == last ? still + 1 : 1; last = text
        let words = text.split(separator: " ")
        let n = LiveType.steady(prev, words, still: still); prev = words
        r.meter.saw(words: words.count, at: t)
        if n > 0 { r.meter.settled(words: n, at: t) }
        guard n >= landed, n > 0 else { continue }
        let want = LiveType.head(text, words: n)
        let p = LiveType.plan(have: run, want: want, end: false)
        guard !p.lost, !(p.keys.isEmpty && p.append.isEmpty) else { continue }
        field = LiveType.run(p.keys, on: field).0 + p.append
        run = p.next; landed = n; if p.fixed > 0 { r.midFixes += 1 }
        if r.firstField == nil { r.firstField = t }
        r.meter.typed(words: n, at: t)
        precondition(field == run, "the pretend field follows the run")
    }
    r.duringWords = landed
    let p = LiveType.plan(have: run, want: take.final, end: true)
    if ProcessInfo.processInfo.environment["SHOW"] != nil { print("    run: \(run)\n    final: \(take.final)\n    left: \(p.left)") }
    field = LiveType.run(p.keys, on: field).0 + p.append
    r.endBurst = p.append.count; r.endKeys = p.keys.count; r.endTouched = p.fixed; r.kept = !p.left.isEmpty
    r.fieldOK = field == take.final || (p.marksOnly && LiveType.onlyMarks(field, take.final))
    return r
}

@main
struct Replay {
    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first ?? ""
        let takes = try JSONDecoder().decode([Take].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for take in takes {
            var times: [Double] = [], texts: [String] = [], costs: [Double] = []
            for d in take.drafts {
                guard let t = d[0].num else { continue }
                times.append(t); texts.append(d[1].str ?? "")
                if d.count > 2, let c = d[2].num { costs.append(c) }
            }
            costs.sort()
            let i = texts.firstIndex { !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty }
            let firstWords: Double? = i.map { times[$0] - (take.speech ?? 0) }
            let median = costs.isEmpty ? "-" : String(Int(costs[costs.count / 2]))
            let words = take.final.split(separator: " ").count
            print("\(take.name): \(String(format: "%.1f", take.secs)) s, \(words) words, \(times.count) drafts (read median \(median) ms); "
                  + "speech at \(ms(take.speech)) ms, first words in the strip \(ms(firstWords)) ms after speech")
            for (label, r) in [("before", old(take)), ("after ", new(take))] {
                print("  \(label): first in field \(ms(r.firstField.map { $0 - (take.speech ?? 0) })) ms after speech; "
                      + "\(r.duringWords) words in \(r.meter.steps) steps while talking; \(r.meter.summary); "
                      + "end: \(r.endBurst) chars at once, fix touched \(r.endTouched) chars in \(r.endKeys) key steps"
                      + (r.kept ? ", field kept as typed" : "") + (r.midFixes > 0 ? "; \(r.midFixes) small fixes while talking" : "")
                      + "; field holds the final words: \(r.fieldOK)")
            }
        }
    }
}
