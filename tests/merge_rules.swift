// swiftc -parse-as-library app/MergeRules.swift tests/merge_rules.swift -o app/build/merge-rules-test && app/build/merge-rules-test
// Combining recordings and voice takes of one talk: grouping, one timeline, the written folder and mixed WAVs.
// Made-up lines only; everything is written to a throwaway temp folder.
import Foundation

@main
struct MergeRuleChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func src(_ id: String, _ kind: MergeSource.Kind = .take, at start: Double, secs: Double, call: Bool = false,
                    app: String = "", rows: [MergeRow] = [], me: URL? = nil, them: URL? = nil) -> MergeSource {
        MergeSource(id: id, kind: kind, start: start, secs: secs, call: call, app: app, rows: rows, me: me, them: them)
    }

    static func main() {
        grouping(); timeline(); takes(); build()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("merge rules: all passed")
    }

    static func grouping() {
        let t0 = 1_800_000_000.0
        let call = src("/r/call", .recording, at: t0, secs: 1800, call: true)
        // (name, sources around the call, ids expected in the group)
        let cases: [(String, [MergeSource], [String])] = [
            ("overlap joins", [src("a", at: t0 + 100, secs: 20)], ["a"]),
            ("9 min after the end joins", [src("a", at: t0 + 1800 + 540, secs: 10)], ["a"]),
            ("9 min before the start joins", [src("a", at: t0 - 540 - 10, secs: 10)], ["a"]),
            ("11 min apart does not", [src("a", at: t0 + 1800 + 660, secs: 10)], []),
            ("a chain 5 min apart joins transitively", [
                src("c", at: t0 + 1800 + 900, secs: 10),
                src("a", at: t0 + 1800 + 300, secs: 10),
                src("b", at: t0 + 1800 + 600, secs: 10),
                src("far", at: t0 + 1800 + 2000, secs: 10)], ["a", "b", "c"]),
            ("target itself is left out", [call, src("a", at: t0 + 5, secs: 5)], ["a"]),
        ]
        for (name, among, want) in cases {
            let got = MergeRules.group(call, among: among).map(\.id)
            check(got == want, "group: \(name): \(got)")
        }
        check(MergeRules.group(src("x", at: 0, secs: 1), among: [src("y", at: 100, secs: 1)], gap: 60).isEmpty, "group: custom gap")
    }

    static func timeline() {
        let t0 = 1_800_000_000.0
        let call = src("/r/call", .recording, at: t0, secs: 120, call: true, app: "Zoom", rows: [
            MergeRow(who: "Вони", start: 5, text: "Agree on the plan"),
            MergeRow(who: "Я", start: 30, text: "We ship the first part on Monday morning"),
            MergeRow(who: "Вони", start: 60, text: "Sounds good"),
        ])
        let take1 = src("t1", at: t0 - 10, secs: 8, rows: [MergeRow(who: "", start: 0, text: "Note before the call starts")])
        let take2 = src("t2", at: t0 + 32, secs: 4, rows: [MergeRow(who: "", start: 0, text: "we ship the first part on Monday.")])
        let take3 = src("t3", at: t0 + 40, secs: 4, rows: [MergeRow(who: "", start: 0, text: "Check the budget numbers")])
        let line = MergeRules.timeline([call, take3, take2, take1])
        check(line.start == t0 - 10, "timeline starts at the first source")
        check(line.secs == 130, "timeline runs to the last end: \(line.secs)")
        let got = line.rows.map { "\($0.start)|\($0.who)|\($0.text)" }
        let want = ["0.0|unknown|Note before the call starts",
                    "15.0|Вони|Agree on the plan",
                    "40.0|Я|We ship the first part on Monday morning",
                    "50.0|unknown|Check the budget numbers",
                    "70.0|Вони|Sounds good"]
        check(got == want, "timeline order, offsets, take in a call -> unknown (never Я), duplicate kept once (longer wins): \(got)")
        check(line.rows.map { MergeRules.track($0) } == ["me", "them", "me", "me", "them"], "tracks: takes are mic, labels give the rest")
        check(line.rows[0].end == 8 && line.rows[3].end == 54 && line.rows[1].end == nil, "a take's row ends with the take")

        // the longer text wins also when it comes later
        let a = src("a", .recording, at: 0, secs: 60, rows: [MergeRow(who: "", start: 10, text: "the plan for Monday")])
        let b = src("b", at: 0, secs: 60, rows: [MergeRow(who: "", start: 25, text: "The plan for Monday, all of it")])
        let ab = MergeRules.timeline([a, b]).rows.map(\.text)
        check(ab == ["The plan for Monday, all of it"], "later longer text wins: \(ab)")
        // more than 20 s apart: both stay
        let c = src("c", at: 0, secs: 60, rows: [MergeRow(who: "", start: 40, text: "the plan for Monday")])
        check(MergeRules.timeline([a, c]).rows.count == 2, "repeats 30 s apart both stay")
        // same source: repeats stay
        let d = src("d", .recording, at: 0, secs: 60, rows: [MergeRow(who: "Я", start: 1, text: "Yes"), MergeRow(who: "Я", start: 2, text: "Yes")])
        check(MergeRules.timeline([d]).rows.count == 2, "repeats inside one source stay")
        // no call: a take keeps who ""
        check(MergeRules.timeline([a, b]).rows.allSatisfy { $0.who == "" }, "no call: take keeps an empty speaker")
        // a short word does not swallow a longer row
        check(!MergeRules.same("Yes", "Yes we agree on the plan"), "one word is not a repeat of a sentence")
        check(MergeRules.same("Agree, on the PLAN!", "agree on the plan"), "case and punctuation ignored")
        check(!MergeRules.same("Agree on the plan today", "Disagree with every budget line"), "different words are not a repeat")
        check(MergeRules.timeline([]).rows.isEmpty, "empty timeline")
    }

    static func takes() {
        let row: [String: Any] = ["id": "abc", "t": 1000.0, "secs": 4.5, "text": " Agree on the plan ", "app": "Notes", "audio": "/tmp/x.wav"]
        let s = MergeRules.take(row)
        check(s?.start == 995.5 && s?.secs == 4.5 && s?.kind == .take, "take: start = t - secs")
        check(s?.rows == [MergeRow(who: "", start: 0, text: "Agree on the plan")], "take: one row at 0")
        check(s?.me?.path == "/tmp/x.wav" && s?.app == "Notes", "take: wav goes to me")
        check(MergeRules.take(["id": "x", "t": 5, "secs": 1, "text": "a", "audio": ""])?.me == nil, "take: no audio, no wav")
        check(MergeRules.take(["t": 5.0]) == nil, "take: no id is nil")
    }

    // MARK: files

    static func wav(_ samples: [Int16], _ url: URL) {
        var d = MergeRules.wavHeader(samples: samples.count)
        samples.forEach { s in withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        try! d.write(to: url)
    }
    static func readWav(_ url: URL) -> [Int16] {
        let d = try! Data(contentsOf: url)
        return stride(from: 44, to: d.count - 1, by: 2).map { Int16(bitPattern: UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8) }
    }
    static func meta(_ dir: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
    }

    static func build() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("merge-rules-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let rec = tmp.appendingPathComponent("calls/2026-01-01T10-00-00Z")
        let audio = tmp.appendingPathComponent("audio")
        try! fm.createDirectory(at: rec, withIntermediateDirectories: true)
        try! fm.createDirectory(at: audio, withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: ["call": true, "app": "Zoom", "started": 1000.0, "event": ["title": "Plan"]])
            .write(to: rec.appendingPathComponent("meta.json"))
        // call: 2 s, me = 1000 everywhere, them = -500 everywhere; take 1 s long starting 1.5 s in (runs 0.5 s past the call)
        let n = 16000
        wav([Int16](repeating: 1000, count: 2 * n), rec.appendingPathComponent("me.wav"))
        wav([Int16](repeating: -500, count: 2 * n), rec.appendingPathComponent("them.wav"))
        wav([Int16](repeating: 32000, count: n), audio.appendingPathComponent("t1.wav"))
        let call = src(rec.path, .recording, at: 1000, secs: 2, call: true, app: "Zoom", rows: [
            MergeRow(who: "Вони", start: 0.2, text: "Agree on the plan"), MergeRow(who: "Я", start: 1.0, text: "Yes")],
            me: rec.appendingPathComponent("me.wav"), them: rec.appendingPathComponent("them.wav"))
        let take = MergeRules.take(["id": "t1", "t": 1002.5, "secs": 1.0, "text": "Check the budget", "app": "Notes",
                                    "audio": audio.appendingPathComponent("t1.wav").path])!
        let out = tmp.appendingPathComponent("calls")
        let dir: URL
        do { dir = try MergeRules.build([take, call], root: out, extraMeta: ["event": ["title": "Plan"]]) }
        catch { check(false, "build threw \(error)"); return }

        check(dir.lastPathComponent == "1970-01-01T00-16-40Z-merged", "folder name: \(dir.lastPathComponent)")
        for f in ["meta.json", "lines.json", "transcript.txt", "me.wav", "them.wav"] {
            check(fm.fileExists(atPath: dir.appendingPathComponent(f).path), "build writes \(f)")
        }
        let m = meta(dir)
        check(m["call"] as? Bool == true && m["app"] as? String == "Zoom" && m["started"] as? Double == 1000, "meta call, app, started")
        check(m["merged"] as? [String] == [rec.path, "t1"] && m["kinds"] as? [String] == ["recording", "take"], "meta merged and kinds")
        check((m["event"] as? [String: Any])?["title"] as? String == "Plan", "extra meta kept")
        let lines = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("lines.json")))) as? [[String: Any]] ?? []
        check(lines.map { $0["who"] as? String ?? "?" } == ["Вони", "Я", "unknown"], "lines.json speakers")
        check(lines.map { $0["track"] as? String ?? "?" } == ["them", "me", "me"], "lines.json tracks")
        check(lines[2]["end"] as? Double == 2.5 && lines[0]["end"] == nil, "lines.json: the take's end")
        let back = MergeRules.rows(lines: (try? Data(contentsOf: dir.appendingPathComponent("lines.json"))) ?? Data())
        check(back?.map(\.track) == ["them", "me", "me"] && back?[2].end == 2.5, "lines.json read back with track and end")
        check(lines.map { $0["start"] as? Double ?? -1 } == [0.2, 1.0, 1.5], "lines.json starts")
        let text = (try? String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? ""
        check(text == "Вони: Agree on the plan\nЯ: Yes\nunknown: Check the budget\n", "transcript for a call: \(text)")

        let me = readWav(dir.appendingPathComponent("me.wav"))
        check(me.count == Int(2.5 * Double(n)), "me.wav length equals the timeline: \(me.count)")
        check(me[0] == 1000 && me[24000 - 1] == 1000, "before the take: the call alone")
        check(me[24000] == 32767 && me[32000 - 1] == 32767, "call + take mixed and clipped at the take's offset")
        check(me[32000] == 32000 && me[40000 - 1] == 32000, "after the call ends: the take alone")
        let them = readWav(dir.appendingPathComponent("them.wav"))
        check(them.count == me.count && them[0] == -500 && them[32000] == 0, "them.wav: the call's side, silence after")

        // mixing in small chunks lands every sample in the same place
        let small = tmp.appendingPathComponent("small.wav")
        wav([1, 2, 3, 4, 5], tmp.appendingPathComponent("a.wav"))
        wav([10, 20, 30], tmp.appendingPathComponent("b.wav"))
        try! MergeRules.mix([(tmp.appendingPathComponent("a.wav"), 1), (tmp.appendingPathComponent("b.wav"), 4)], samples: 8, to: small, chunk: 3)
        check(readWav(small) == [0, 1, 2, 3, 14, 25, 30, 0], "chunked mix offsets: \(readWav(small))")
        let neg = tmp.appendingPathComponent("neg.wav")
        wav([-30000, -30000], tmp.appendingPathComponent("c.wav"))
        try! MergeRules.mix([(tmp.appendingPathComponent("c.wav"), 0), (tmp.appendingPathComponent("c.wav"), 0)], samples: 2, to: neg)
        check(readWav(neg) == [-32768, -32768], "negative clip")

        // mergedInto marks only recordings and keeps their other keys
        let rm = meta(rec)
        check(MergeRules.mergedInto(rec) == dir.path, "recording marked mergedInto")
        check(rm["app"] as? String == "Zoom" && rm["call"] as? Bool == true && (rm["event"] as? [String: Any])?["title"] as? String == "Plan",
              "recording meta keeps its other keys")
        check(MergeRules.mergedInto(dir) == nil, "the new folder is not marked")
        check(fm.fileExists(atPath: audio.appendingPathComponent("t1.wav").path)
              && (try? fm.contentsOfDirectory(atPath: audio.path)) == ["t1.wav"], "take audio untouched, nothing added")

        // a note without them: no them.wav, one running text; same name gets -2
        let noteA = src("na", at: 1000, secs: 1, rows: [MergeRow(who: "", start: 0, text: "First thought.")],
                        me: audio.appendingPathComponent("t1.wav"))
        let noteB = src("nb", at: 1001, secs: 1, rows: [MergeRow(who: "", start: 0, text: "Second thought.")])
        let d2 = try! MergeRules.build([noteA, noteB], root: out)
        check(d2.lastPathComponent == "1970-01-01T00-16-40Z-merged-2", "existing name gets -2: \(d2.lastPathComponent)")
        check(!fm.fileExists(atPath: d2.appendingPathComponent("them.wav").path), "no them.wav when no source has one")
        check((try? String(contentsOf: d2.appendingPathComponent("transcript.txt"), encoding: .utf8)) == "First thought. Second thought.\n",
              "note transcript is one running text")
        check(meta(d2)["call"] as? Bool == false, "note meta call false")
    }
}
