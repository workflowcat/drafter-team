import Foundation

// swiftc -parse-as-library app/DraftCaptureRules.swift tests/draft_capture_rules.swift -o app/build/draft-capture-test && app/build/draft-capture-test
// Made-up text only (English and Ukrainian). The draft rules and the hidden-rows sidecar (a temp folder).
@main
struct DraftCaptureChecks {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { failed += 1; print("FAIL \(line): \(what)") }
    }

    static func main() {
        typealias R = DraftCaptureRules
        let page = "HomeAboutPricingBlogContact Welcome to the Example Store Privacy Terms of use Cookie settings\nAsk anything\n"
        let now = 1_000_000.0

        // A: a web box read whole: only what he typed after his first key is the draft
        let typed = "can you check the order for friday please"
        check(R.typedPart(start: page, end: page + typed).text == typed, "page text before his first key is not his draft")
        check(R.record(start: page, end: page + typed, keys: typed.count, inserted: 0, recent: [], app: "Dia", now: now) == .add(typed, est: false),
              "the typed part is kept")
        // the same page with no read at the first key: 41 keys explain only the tail; it is kept as an estimate, never dropped
        if case .add(let t, let est) = R.record(start: nil, end: page + typed, keys: typed.count, inserted: 0, recent: [], app: "Dia", now: now) {
            check(est && t.hasSuffix(typed) && t.count < typed.count + 30 && !t.contains("Privacy"), "an unexplained row: the key-budget tail, marked est")
        } else { check(false, "an unexplained row is never dropped") }
        // a pasted paragraph is his: the paste explains it
        let pasted = String(repeating: "lorem ipsum dolor sit amet ", count: 20)
        check(R.record(start: "", end: pasted, keys: 4, inserted: pasted.count, recent: [], app: "Claude", now: now) == .add(pasted.trimmingCharacters(in: .whitespaces), est: false),
              "a paste is allowed")
        // dictation: the voice text came in through a paste (Focus counts it)
        let said = "давай зустрінемось у четвер о десятій біля офісу"
        check(R.record(start: "", end: said, keys: 0, inserted: said.count + 1, recent: [], app: "Beeper", now: now) == .add(said, est: false), "dictation is allowed")
        // a page that grew while he typed three letters: not kept
        // a page that grew while he typed (a reply streaming in): kept as the tail his keys explain, marked est
        let streamed = "Ask anything\n" + pasted + "and then we ship it"
        if case .add(let t, let est) = R.record(start: "Ask anything\n", end: streamed, keys: 19, inserted: 0, recent: [], app: "Claude", now: now) {
            check(est && t.hasSuffix("we ship it") && t.count < 60, "text that came in by itself: the estimate")
        } else { check(false, "a streamed page never drops his draft") }

        // B: never starts mid-word
        let field = "привіт, як справи? я сьогодні"
        check(R.typedPart(start: "привіт, як справи? я сьо", end: field).text == "сьогодні", "a cut inside a word moves to the word start (uk)")
        check(R.typedPart(start: "hello there, I was think", end: "hello there, I was thinking of you").text == "thinking of you",
              "a cut inside a word moves to the word start (en)")
        check(R.typedPart(start: "hello there ", end: "hello there friend").text == "friend", "a cut between words stays")
        let long = String(repeating: "abcdefghi ", count: 300)   // 3000 characters
        let t = R.tail(long, max: 2000)
        check(t.count <= 2000 && t.hasPrefix("abcdefghi"), "the tail window drops the broken word")
        check(R.tail("short line", max: 600) == "short line", "a short text is whole")
        let uk = String(repeating: "слово ", count: 200)
        check(R.tail(uk, max: 600).hasPrefix("слово"), "the tail window drops the broken word (uk)")

        // C and D: a continued draft updates its row, the same text adds nothing
        let first = "I think we should move the call"
        let kept = [R.Kept(text: first, t: now - 60, app: "Beeper")]
        check(R.record(start: "", end: first, keys: 40, inserted: 0, recent: kept, app: "Beeper", now: now) == .skip, "the same draft again adds no row")
        check(R.record(start: "", end: "  i think we  should move the CALL ", keys: 40, inserted: 0, recent: kept, app: "Beeper", now: now) == .skip,
              "spaces and case aside, the same")
        let more = first + " to monday afternoon"
        check(R.record(start: "", end: more, keys: 60, inserted: 0, recent: kept, app: "Beeper", now: now) == .replace(more, now - 60, est: false),
              "a continued draft replaces its row")
        check(R.record(start: "", end: more, keys: 60, inserted: 0, recent: kept, app: "Slack", now: now) == .add(more, est: false), "another app: a new row")
        check(R.record(start: "", end: more, keys: 60, inserted: 0, recent: kept, app: "Beeper", now: now + 3600) == .add(more, est: false), "an hour later: a new row")
        // he clicked away and came back: the field holds his first draft, the new keys continue it
        let back = R.typedPart(start: page + first + " ", end: page + more, recent: kept, app: "Beeper", now: now)
        check(back.text == more && back.carried == first.count, "a draft he comes back to is carried")
        check(R.record(start: page + first + " ", end: page + more, keys: 20, inserted: 0, recent: kept, app: "Beeper", now: now) == .replace(more, now - 60, est: false),
              "the carried draft grows the same row")
        // A, then B in another field, then A again: A adds nothing
        let two = kept + [R.Kept(text: "другий лист про рахунок", t: now - 30, app: "Beeper")]
        check(R.record(start: "", end: first, keys: 40, inserted: 0, recent: two, app: "Beeper", now: now) == .skip, "an earlier draft of the app again adds nothing")
        // fewer than three words: not a draft
        check(R.record(start: "", end: "ok so", keys: 5, inserted: 0, recent: [], app: "Beeper", now: now) == .skip, "a stub is not kept")

        // times: "t0" his first key, "t" his last key; a continued row keeps its first start and moves the end
        let s1 = R.stamps(firstKey: now - 90, lastKey: now - 20, now: now)
        check(s1.t0 == now - 90 && s1.t == now - 20, "a new draft: first key and last key")
        check(R.stamps(firstKey: nil, lastKey: nil, now: now) == (nil, now), "no keys counted: no start, the end is now")
        let row = R.Kept(text: first, t: now - 60, app: "Beeper", t0: now - 300)
        let s2 = R.stamps(firstKey: now - 30, lastKey: now - 5, now: now, continued: row)
        check(s2.t0 == now - 300 && s2.t == now - 5, "a continued draft keeps the first start, moves the end")
        let old = R.Kept(text: first, t: now - 60, app: "Beeper")   // an old row without a start
        check(R.stamps(firstKey: now - 30, lastKey: now - 5, now: now, continued: old).t0 == now - 30, "an old row: this draft's first key")
        check(R.stamps(firstKey: now + 5, lastKey: now + 9, now: now) == (now, now), "never after now, start never after the end")

        // the sent line: the last line of what he wrote, never page text
        check(R.sentLine(start: page, end: page + typed, keys: typed.count, inserted: 0, recent: [], app: "Dia", now: now) == typed, "sent line is his")
        check(R.sentLine(start: nil, end: page + typed, keys: typed.count, inserted: 0, recent: [], app: "Dia", now: now) == typed, "sent: the last line of the estimate")

        // the anchor: the page above changed (a time stamp), so the shared start breaks early; the last 40 characters
        // before the caret at his first key are still there, and what follows them is the draft, not an estimate
        let convo = "Updated 2 min ago\nMila: can you send the act tonight?\nme: sure, after six\nMila: thanks!\n"
        let reply = "sure, I will send it right after the call"
        let moved = convo.replacingOccurrences(of: "2 min", with: "3 min")
        check(R.record(start: convo, end: moved + reply, keys: reply.count, inserted: 0, recent: [], app: "Beeper", now: now) == .add(reply, est: false),
              "anchored: the text after the old caret (en)")
        let розмова = "Оновлено 2 хв тому\nОля: надішлеш акт сьогодні?\nя: так, після шостої\nОля: дякую!\n"
        let відповідь = "надішлю одразу після дзвінка, добре"
        check(R.record(start: розмова, end: розмова.replacingOccurrences(of: "2 хв", with: "3 хв") + відповідь, keys: відповідь.count, inserted: 0,
                       recent: [], app: "Beeper", now: now) == .add(відповідь, est: false), "anchored: the text after the old caret (uk)")
        check(R.anchored(start: "short", end: "short and more") == nil, "a start under 12 characters is no anchor")
        check(R.anchored(start: convo, end: "a different page entirely") == nil, "the anchor is gone")
        // the estimate starts at a sentence when one is within reach, else at a word
        let est = R.estimate("Перше речення тут. Друге речення про зустріч у четвер о десятій", budget: 30)
        check(est.hasPrefix("Друге"), "the estimate reaches back to a sentence start (uk)")
        let far = String(repeating: "word ", count: 40) + "and the last few words here"
        let w = R.estimate(far, budget: 20)
        check(w.count >= 19 && w.count <= 30 && w.hasSuffix("words here") && (w.hasPrefix("few ") || w.hasPrefix("last ")), "no sentence in reach: a word start")
        check(R.estimate("abc def", budget: 50) == "abc def", "within the budget: as it is")

        // shape B for the journal: shown from the first whole word after "…"
        let cut = "ing" + String(repeating: " слово", count: 400)   // a 2003-character draft cut mid-word
        check(R.shownText(cut, sent: false).hasPrefix("…слово"), "a cut draft from its first whole word")
        let cutSent = "nd" + String(repeating: " word", count: 119) + " ab"   // exactly 600
        check(cutSent.count == 600 && R.shownText(cutSent, sent: true).hasPrefix("…word"), "a cut sent line from its first whole word")
        check(R.shownText("a short draft", sent: false) == "a short draft", "other rows as they are")
        check(R.shownText(" " + String(cut.dropFirst()), sent: false) == " " + String(cut.dropFirst()), "a row starting at a space is whole")
        check(R.sentLine(start: "", end: "line one\nline two here", keys: 30, inserted: 0, recent: [], app: "Claude", now: now) == "line two here", "last line")

        // the sidecar: rows listed there are skipped, others stay; a missing or broken file hides nothing
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drafter-hide-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = dir.appendingPathComponent("drafts-hidden.json")
        check(DraftHide.load(side).isEmpty, "no file: nothing hidden")
        try? "not json".write(to: side, atomically: true, encoding: .utf8)
        check(DraftHide.load(side).isEmpty, "a broken file: nothing hidden")
        let rows: [[String: Any]] = [["t": 1763100000.123456, "text": "made up one", "app": "Beeper"],
                                     ["t": 1763100100.5, "text": "made up two", "app": "Beeper"],
                                     ["t": 1763100200.25, "text": "made up three", "app": "Claude"]]
        let j: [String: Any] = ["hidden": [["kind": "draft", "t": 1763100000.123456, "shape": "D", "by": "hide_bad_drafts"],
                                           ["kind": "sent", "t": 1763100100.5, "shape": "B", "by": "hide_bad_drafts"]]]
        try? JSONSerialization.data(withJSONObject: j).write(to: side)
        let hidden = DraftHide.load(side)
        check(hidden.count == 2, "two hidden")
        let drafts = DraftHide.drop(rows, kind: "draft", hidden: hidden)
        check(drafts.count == 2 && drafts.allSatisfy { ($0["text"] as? String) != "made up one" }, "the hidden draft is skipped")
        check(DraftHide.drop(rows, kind: "sent", hidden: hidden).count == 2, "a sent id hides only the sent row")
        check(DraftHide.drop(rows, kind: "draft", hidden: []).count == 3, "nothing hidden: all rows")
        // the row's t as read back from a JSON line matches the sidecar's t
        let line = #"{"t":1763100000.123456,"text":"made up one","app":"Beeper"}"#
        let read = [(try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]]
        check(DraftHide.drop(read, kind: "draft", hidden: hidden).isEmpty, "t read from the store matches")

        print(failed == 0 ? "draft capture rules: all passed" : "draft capture rules: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
