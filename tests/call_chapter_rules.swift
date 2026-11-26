// swiftc -parse-as-library app/CallTimelineRules.swift app/CallChapterRules.swift tests/call_chapter_rules.swift -o app/build/call-chapter-rules-test && app/build/call-chapter-rules-test
// Synthetic fixtures only. No app launch, filesystem reads, or personal call data.
import Foundation

@main
struct CallChapterRulesTest {
    typealias R = CallChapterRules
    static var ran = 0
    static var failed = 0
    static func check(_ ok: Bool, _ label: String) {
        ran += 1
        if !ok { failed += 1; print("FAIL: \(label)") }
    }
    static func turn(_ start: Double?, _ end: Double?, _ text: String = "Orchard budget review", who: String = "Demo Guest") -> CallChapterTurn {
        CallChapterTurn(start: start, end: end, who: who, text: text)
    }
    static func main() {
        chapterChecks()
        hybridChecks()
        playbackChecks()
        briefChecks()
        sourceChecks()
        print("call chapter rules: \(ran) checks, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func chapterChecks() {
        check(R.chapters(turns: [], duration: 600).isEmpty, "empty transcript has no chapters")
        check(R.chapters(turns: [turn(nil, nil)], duration: 600).isEmpty, "untimed transcript does not invent chapter offsets")
        for duration in [0, -2, Double.nan, Double.infinity] {
            check(R.chapters(turns: [turn(0, 20)], duration: duration).isEmpty, "invalid duration")
        }
        for duration in [1.0, 20, 59.9] {
            let c = R.chapters(turns: [turn(0, 1), turn(10, 15), turn(40, 50)], duration: duration)
            check(c.count == 1, "very short recording stays one chapter")
            check(c.first?.start == 0 && c.last?.end == duration, "short recording spans duration")
        }
        let rows = stride(from: 0, to: 1200, by: 20).map { s -> CallChapterTurn in
            let text = s < 400 ? "Kickoff and timeline. Schedule milestones launch." :
                s < 800 ? "Budget review. Forecast spending costs." : "Station staffing. Coverage shifts roster."
            return turn(Double(s), Double(s + 18), text)
        }
        let chapters = R.chapters(turns: rows, duration: 1200)
        check((3...8).contains(chapters.count), "twenty minute call has a compact chapter count")
        check(chapters == R.chapters(turns: rows, duration: 1200), "chapter generation is deterministic")
        check(chapters == R.chapters(turns: rows.reversed(), duration: 1200), "input order does not affect distinct timestamps")
        check(chapters.first?.start == 0 && chapters.last?.end == 1200, "chapters cover the full recording")
        check(chapters.allSatisfy { $0.end - $0.start >= 45 }, "no tiny chapters")
        check(zip(chapters, chapters.dropFirst()).allSatisfy { $0.end == $1.start }, "chapter intervals meet without gaps")
        check(chapters.contains { abs($0.start - 400) <= 20 } && chapters.contains { abs($0.start - 800) <= 20 }, "sliding windows find topic boundaries")
        check(chapters.allSatisfy { (2...5).contains($0.title.split(separator: " ").count) && !$0.title.hasPrefix("Chapter ") }, "readable content titles")
        check(chapters.contains { $0.title.lowercased().contains("budget") }, "title reflects budget topic")
        let gaps = [turn(0, 30, "Kickoff timeline"), turn(60, 90, "Budget review"), turn(150, 180, "Station staffing")]
        let silenceCuts = R.chapters(turns: gaps, duration: 600)
        check(silenceCuts.contains { $0.start == 60 } && silenceCuts.contains { $0.start == 150 }, "silence boundaries use speech ends")
        let threshold = R.chapters(turns: [turn(0, 35), turn(60, 100)], duration: 600)
        check(threshold.contains { $0.start == 60 }, "25 second chapter gap included")
        let malformed = rows + [turn(.nan, 50), turn(-10, 10), turn(.infinity, 20), turn(nil, nil), turn(5000, 5010), turn(100, 101, "  ")]
        check(R.chapters(turns: malformed, duration: 1200) == chapters, "malformed rows cannot poison chapters")
        for duration in [600, 1800, 3600] {
            let long = stride(from: 0, to: duration, by: 15).map { turn(Double($0), Double($0 + 14), "Budget review forecast spending") }
            let c = R.chapters(turns: long, duration: Double(duration))
            check((3...8).contains(c.count), "balanced chapters for uninterrupted discussion")
            check(c.allSatisfy { $0.end - $0.start >= 45 }, "long call minimum duration")
        }
        let single = R.chapters(turns: [turn(0, 3600, "Orchard")], duration: 3600)
        check(single.count == 1 && single[0].title == "Orchard discussion", "sparse long transcript stays honest")
        check(R.formatChaptersForCopy([]).isEmpty, "empty chapter copy")
        let copy = R.formatChaptersForCopy([CallChapter(start: 0, end: 258, title: "Kickoff & timeline"), CallChapter(start: 258, end: 600, title: "Budget review")])
        check(copy == "00:00 — Kickoff & timeline\n04:18 — Budget review", "crisp chapter copy format")
        check(R.formatChaptersForCopy([CallChapter(start: 3601, end: 3700, title: "Station review")]).hasPrefix("1:00:01"), "hour-long timestamps")
    }

    static func hybridChecks() {
        let rows = [turn(12, 20, "Orchard budget review approved"), turn(30, 40, "Station staffing roster shifts"),
                    turn(55, 60, "Orchard budget review forecast"), turn(90, 95, "Orchard budget review approved"),
                    turn(12, 20, "Orchard budget review approved"), turn(nil, nil, "Unscheduled lantern repairs")]
        let mine = "  - Keep the small pilot.  \n\n1. Ask about access.\nKeep *this* wording."
        let blocks = R.hybridNotes(myNotes: mine, summary: ["- Orchard budget review", "Unrelated telescope navigation", "the and we"],
                                   todos: ["- [ ] Station staffing roster", "- [x] Unscheduled lantern repairs"], turns: rows)
        check(blocks.count == 8, "three human lines, three summary points and two actions")
        check(Array(blocks.prefix(3)) == [.human(text: "  - Keep the small pilot.  "), .human(text: "1. Ask about access."), .human(text: "Keep *this* wording.")], "human wording, whitespace and order preserved verbatim")
        check(blocks[3] == .aiPoint(text: "Orchard budget review", citations: [12, 55]), "top two supporting moments, stable ties and unique times")
        check(blocks[4] == .aiPoint(text: "Unrelated telescope navigation", citations: []), "unsupported points have no invented citation")
        check(blocks[5] == .aiPoint(text: "the and we", citations: []), "stop words do not create citations")
        check(blocks[6] == .todo(text: "Station staffing roster", citations: [30]), "action item has local evidence")
        check(blocks[7] == .todo(text: "Unscheduled lantern repairs", citations: []), "untimed matches do not invent a time")
        check(R.hybridNotes(myNotes: "\n \n", summary: [], todos: [], turns: []).isEmpty, "empty notes")
        let plain = R.hybridNotes(myNotes: "- A human line", summary: ["## Takeaways\n- First point\n* Second point"], todos: [], turns: [])
        check(plain == [.human(text: "- A human line"), .aiPoint(text: "First point", citations: []), .aiPoint(text: "Second point", citations: [])], "Markdown bullets normalized only for generated notes")
        let partial = R.hybridNotes(myNotes: "", summary: ["Orchard telescope expedition telescope"], todos: [], turns: rows)
        check(partial == [.aiPoint(text: "Orchard telescope expedition telescope", citations: [])], "one shared content word is insufficient")
        let unicode = R.hybridNotes(myNotes: "", summary: ["Café résumé"], todos: [], turns: [turn(8, 12, "Café résumé review")])
        check(unicode == [.aiPoint(text: "Café résumé", citations: [8])], "Unicode token matching")
        check(blocks == R.hybridNotes(myNotes: mine, summary: ["- Orchard budget review", "Unrelated telescope navigation", "the and we"], todos: ["- [ ] Station staffing roster", "- [x] Unscheduled lantern repairs"], turns: rows), "hybrid output deterministic")
    }

    static func playbackChecks() {
        let rows = [turn(5, 10), turn(20, 30), turn(32, 40), turn(43, 50)]
        check(R.nextPlayableTime(at: 0, turns: rows) == 5, "leading silence")
        check(R.nextPlayableTime(at: 5, turns: rows) == nil, "speech starts are playable")
        check(R.nextPlayableTime(at: 9, turns: rows) == nil, "never jump inside speech")
        check(R.nextPlayableTime(at: 10, turns: rows) == 20, "end is the start of a gap")
        check(R.nextPlayableTime(at: 19.9, turns: rows) == 20, "late in a long gap")
        check(R.nextPlayableTime(at: 31, turns: rows) == nil, "short gap stays")
        check(R.nextPlayableTime(at: 40, turns: rows) == 43, "exact minimum gap")
        check(R.nextPlayableTime(at: 40, turns: rows, minimumGap: 4) == nil, "custom threshold")
        check(R.nextPlayableTime(at: 80, turns: rows) == nil, "no trailing target")
        check(R.nextPlayableTime(at: 11, turns: rows.reversed()) == 20, "unsorted input")
        check(R.nextPlayableTime(at: 25, turns: [turn(0, 100), turn(20, 22), turn(120, 130)]) == nil, "overlapping speaker remains audible")
        check(R.nextPlayableTime(at: 105, turns: [turn(0, 100), turn(20, 22), turn(120, 130)]) == 120, "gap starts after longest overlap")
        check(R.nextPlayableTime(at: 10, turns: [turn(0, nil), turn(40, 50)]) == nil, "unknown end does not infer silence")
        check(R.nextPlayableTime(at: 10, turns: [turn(0, -1), turn(40, 50)]) == nil, "reversed end remains conservative")
        check(R.nextPlayableTime(at: 10, turns: [turn(0, .nan), turn(40, 50)]) == nil, "nonfinite end remains conservative")
        check(R.nextPlayableTime(at: 10, turns: []) == nil, "empty playback")
        for invalid in [Double.nan, Double.infinity, -1] {
            check(R.nextPlayableTime(at: invalid, turns: rows) == nil, "invalid playback clock")
            check(R.nextPlayableTime(at: 15, turns: rows, minimumGap: invalid) == nil, "invalid silence threshold")
        }
        let shots = [0.0, 10, 10, 30, 90, .nan, .infinity, -5]
        check(R.nextChangedShot(at: 0, shots: shots) == 10, "next screen skips current")
        check(R.nextChangedShot(at: 10, shots: shots) == 30, "duplicate screens cannot trap next")
        check(R.nextChangedShot(at: 30, shots: shots, direction: -1) == 10, "previous screen at exact boundary")
        check(R.nextChangedShot(at: 29, shots: shots, direction: -1) == 10, "previous screen between boundaries")
        check(R.nextChangedShot(at: 0, shots: shots, direction: -1) == nil, "no previous screen at start")
        check(R.nextChangedShot(at: 90, shots: shots) == nil, "no wrap at last screen")
        check(R.nextChangedShot(at: -1, shots: shots) == 0, "before first frame")
        check(R.nextChangedShot(at: .nan, shots: shots) == nil, "invalid screen clock")
        check(R.nextChangedShot(at: 0, shots: shots, direction: 0) == nil, "zero direction")
        check(R.nextChangedShot(at: 0, shots: []) == nil, "no screenshots")
        check(R.nextChangedShot(at: 10, shots: shots.reversed()) == 30, "shot order robust")
    }

    static func briefChecks() {
        let chapters = [CallChapter(start: 0, end: 258, title: "Kickoff timeline"), CallChapter(start: 258, end: 600, title: "Budget review")]
        let brief = R.shareBrief(title: "Station Review", dateLabel: "23 November 2026", duration: 600, people: ["Demo Guest"],
                                 myNotes: "- Keep the pilot.\n- Ask about access.", summary: ["- Orchard budget approved"],
                                 todos: ["- [x] Send the forecast"], chapters: chapters,
                                 links: ["See https://example.com/plan.", "https://example.com/plan", "file:///tmp/demo/notes.md"])
        check(brief.hasPrefix("# Station Review\n\n23 November 2026 · 10:00"), "title date and duration")
        check(brief.contains("Participants: Demo Guest"), "participants")
        check(brief.contains("## Your Notes\n- Keep the pilot.\n- Ask about access."), "own notes remain distinct")
        check(brief.contains("## Key Takeaways\n- Orchard budget approved"), "summary normalized")
        check(brief.contains("## Action Items\n- [ ] Send the forecast"), "action checklist normalized")
        check(brief.contains("## Chapters\n- 00:00 — Kickoff timeline\n- 04:18 — Budget review"), "share chapter list")
        check(brief.contains("## Links\n- https://example.com/plan\n"), "web links extracted")
        check(brief.components(separatedBy: "https://example.com/plan").count == 2, "duplicate URLs collapsed")
        check(!brief.contains("file:") && !brief.contains("/tmp/"), "file links never shared")
        let minimal = R.shareBrief(title: "", dateLabel: "", duration: .nan, people: [], myNotes: "", summary: [], todos: [], chapters: Array(chapters.prefix(1)), links: [])
        check(minimal == "# Meeting brief\n\n00:00\n", "empty brief has no empty sections or lone chapter")
        let paths = R.shareBrief(title: "Station /tmp/demo/raw.txt", dateLabel: "23 November 2026\n# injected", duration: 60,
                                 people: ["Demo Guest", "~/Documents/secret.md"], myNotes: "See [plan](file:///tmp/demo/plan.md).",
                                 summary: ["Read data/calls/demo/lines.json", "Review https://example.org/plan"],
                                 todos: ["Open /var/tmp/demo/report.md"], chapters: [], links: [])
        for path in ["/tmp/", "~/", "file:", "data/calls/", "/var/", "\n# injected"] {
            check(!paths.contains(path), "brief removes local paths and structural newlines")
        }
        check(paths.contains("See plan."), "local markdown link retains its readable label")
        check(paths.contains("https://example.org/plan"), "web paths survive sanitation")
        check(R.extractedURLs(from: ["[plan](https://example.org/plan)", "https://example.org/plan", "file:///tmp/demo", "https://demo:secret@example.org/"]) == ["https://example.org/plan"], "link extraction is ordered, unique and excludes credentials")
    }

    static func sourceChecks() {
        let first = Data(#"[{"start":0,"end":20,"who":"Demo Guest","text":"Orchard budget"},{"start":40,"text":"Station review"},{"start":80,"end":90,"text":" "}]"#.utf8)
        let rows = R.transcriptTurns(from: first)
        check(rows == [turn(0, 20, "Orchard budget"), turn(40, nil, "Station review", who: "")], "first transcript preserves ends and unknown ends")
        check(R.nextPlayableTime(at: 25, turns: rows) == 40, "saved end enables real gap skip")
        check(R.nextPlayableTime(at: 50, turns: rows) == nil, "missing final end never guesses speech length")
        let two = Data(#"[{"start":0,"end":60,"who":"Я","text":"Orchard budget"},{"start":20,"end":30,"who":"Вони","text":"Station review"},{"start":90,"end":95,"who":"Вони","text":"Forecast approved"}]"#.utf8)
        let both = R.transcriptTurns(from: two)
        check(both.count == 3, "both sides kept")
        check(R.nextPlayableTime(at: 35, turns: both) == nil, "other track still speaking after short overlapping turn")
        check(R.nextPlayableTime(at: 65, turns: both) == 90, "timing gap across both sides")
        check(R.transcriptTurns(from: Data("broken".utf8)).isEmpty, "invalid JSON fallback")
        check(R.transcriptTurns(from: Data("{}".utf8)).isEmpty, "wrong JSON shape fallback")
        check(R.chapters(turns: [turn(0, 20, "Okay")], duration: 30).first?.title == "Okay discussion", "single filler title stays two words")
    }
}
