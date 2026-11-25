import Foundation

// swiftc -O -parse-as-library app/PickRules.swift tests/pick_rules.swift -o app/build/pick-rules-test && app/build/pick-rules-test
// Pick parts with made-up texts: splitting at every level in English and Ukrainian (abbreviations, initials,
// decimals, links), exact ranges, the starting level, the quick picks, joins, "the rest", the panel's keys as a
// state machine, the derived record and its row written to a temp folder (never data/).
@main
struct PickRuleChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }
    static func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) { if a != b { print("FAIL: \(what)\n  got:  \(a)\n  want: \(b)"); failures += 1 } }

    static func main() {
        sentencesEnglish(); sentencesUkrainian(); ranges(); paragraphsAndLines(); items(); tables(); things(); start()
        quickPicks(); joins(); rest(); carry(); keys(); keyMap(); mouse(); record(); speed()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("pick rules: all passed")
    }

    static func texts(_ t: String, _ l: PickLevel, things: PickThings? = nil) -> [String] {
        let ns = t as NSString
        return PickRules.split(t, l, things: things).map { ns.substring(with: $0.range) }
    }

    static func sentencesEnglish() {
        let t = "Mr. Lee met Dr. Kowalski at 3 p.m. on Monday. The budget grew by 2.5 percent, e.g. for rent. See https://example.com/a.b?x=1 for the plan. Write to anna@example.org. Was it J. R. Tolkien? Yes! Wait... no, later."
        eq(texts(t, .sentences), [
            "Mr. Lee met Dr. Kowalski at 3 p.m. on Monday.",
            "The budget grew by 2.5 percent, e.g. for rent.",
            "See https://example.com/a.b?x=1 for the plan.",
            "Write to anna@example.org.",
            "Was it J. R. Tolkien?",
            "Yes!",
            "Wait... no, later.",
        ], "English sentences with abbreviations, decimals, a URL, an email, initials")
        eq(texts("We bought apples, pears etc. and went home. Then we ate apples, pears etc. Then we slept.", .sentences), [
            "We bought apples, pears etc. and went home.", "Then we ate apples, pears etc.", "Then we slept.",
        ], "etc. ends a sentence only before a capital")
        eq(texts("Meet at 10 a.m. Bring the keys.", .sentences), ["Meet at 10 a.m.", "Bring the keys."], "a.m. before a capital ends")
        eq(texts("He said \"Stop.\" Then he left.", .sentences), ["He said \"Stop.\"", "Then he left."], "closing quote stays with its sentence")
        eq(texts("This line wraps here\nand goes on. Next one.\nA new line starts.", .sentences),
           ["This line wraps here\nand goes on.", "Next one.", "A new line starts."], "wrapped lines join, a capital line starts anew")
    }

    static func sentencesUkrainian() {
        let t = "Привіт, команда! Зустріч у пн. о 10:00 на вул. Хрещатик, 1. Беремо яблука, груші і т.д. та інше. Ціна 12.50 грн за кг. Напр. Київ і Львів. Автор Т. Г. Шевченко писав вірші. Що далі? Див. розд. 3."
        eq(texts(t, .sentences), [
            "Привіт, команда!",
            "Зустріч у пн. о 10:00 на вул. Хрещатик, 1.",
            "Беремо яблука, груші і т.д. та інше.",
            "Ціна 12.50 грн за кг.",
            "Напр. Київ і Львів.",
            "Автор Т. Г. Шевченко писав вірші.",
            "Що далі?",
            "Див. розд. 3.",
        ], "Ukrainian sentences: вул., т.д., напр., initials, decimals")
        eq(texts("Купили хліб, молоко і т.д. Потім пішли додому.", .sentences), ["Купили хліб, молоко і т.д.", "Потім пішли додому."],
           "т.д. before a capital ends")
        eq(texts("Будинок 1990 р. побудови. Ремонт у 2020 р. Новий дах.", .sentences),
           ["Будинок 1990 р. побудови.", "Ремонт у 2020 р. Новий дах."], "р. never ends (a known limit before a capital)")
    }

    static func ranges() {
        let t = "  Перше речення.   Друге — з «лапками»!  \n\nТретє 🙂 з емодзі. Last one."
        let ns = t as NSString
        for l in PickLevel.allCases {
            for p in PickRules.split(t, l) {
                check(p.range.location >= 0 && p.range.location + p.range.length <= ns.length, "\(l) range inside the text")
                let s = ns.substring(with: p.range)
                check(s == s.trimmingCharacters(in: .whitespacesAndNewlines), "\(l) range has no spaces around: \(s)")
                check(NSLocationInRange(p.body.location, p.range) || p.body.length == 0, "\(l) body inside range")
            }
            let ps = PickRules.split(t, l)
            check(zip(ps, ps.dropFirst()).allSatisfy { $0.range.location + $0.range.length <= $1.range.location }, "\(l) in order, no overlap")
        }
        eq(texts(t, .sentences), ["Перше речення.", "Друге — з «лапками»!", "Третє 🙂 з емодзі.", "Last one."], "emoji keeps UTF-16 ranges exact")
    }

    static func paragraphsAndLines() {
        let t = "First para line one\nline two.\n\n\n  Second para.  \n\nThird."
        eq(texts(t, .paragraphs), ["First para line one\nline two.", "Second para.", "Third."], "paragraphs")
        eq(texts(t, .lines), ["First para line one", "line two.", "Second para.", "Third."], "lines")
        eq(PickRules.split(t, .sentences).map(\.para), [0, 1, 2], "sentences know their paragraph")
        eq(texts("a\r\nb\r\n\r\nc", .lines), ["a", "b", "c"], "CRLF lines")
    }

    static func items() {
        let t = "Shopping for Friday:\n- milk\n- bread\n  the dark one\n* eggs\n1. call Olena\n2) pay rent\nа) перше\n• bullet\n- [ ] task open\n- [x] task done\nNot an item.\nA. Bondar signed."
        let ps = PickRules.split(t, .items), ns = t as NSString
        eq(ps.map { ns.substring(with: $0.range) }, ["Shopping for Friday:", "- milk", "- bread\n  the dark one", "* eggs", "1. call Olena",
            "2) pay rent", "а) перше", "• bullet", "- [ ] task open", "- [x] task done", "Not an item.", "A. Bondar signed."], "items with a wrapped line")
        eq(ps.map { ns.substring(with: $0.body) }, ["Shopping for Friday:", "milk", "bread\n  the dark one", "eggs", "call Olena", "pay rent",
            "перше", "bullet", "task open", "task done", "Not an item.", "A. Bondar signed."], "item bodies without marks")
        eq(ps.map(\.kind).filter { $0 == "item" }.count, 9, "nine items")
    }

    static func tables() {
        let t = "| Name | Qty |\n|------|-----|\n| Apples | 3 |\n| Pears | 5 |\n\nName\tQty\nPlums\t7"
        let ns = t as NSString, ps = PickRules.split(t, .items)
        eq(ps.map { ns.substring(with: $0.range) }, ["| Name | Qty |", "| Apples | 3 |", "| Pears | 5 |", "Name\tQty", "Plums\t7"], "rows, rule line skipped")
        eq(ps.map { ns.substring(with: $0.body) }.prefix(2), ["Name | Qty", "Apples | 3"], "row body without outer bars")
        check(ps.allSatisfy { $0.kind == "row" }, "all rows")
        eq(PickRules.startLevel(t), .items, "a table starts at items")
        let picked = PickRules.result(t, ps, [1], .items)
        eq(picked, "| Apples | 3 |", "a row picked keeps its bars")
        eq(PickRules.rest(t, ps, [1, 2]), "| Name | Qty |\n|------|-----|\n\nName\tQty\nPlums\t7", "the rest keeps the header and rule")
    }

    static func things() {
        let t = "Invoice 2026-11-20 for $1,200 to pay@example.com, see https://example.com/inv/7. Due 15 листопада, 3 400 грн."
        let ps = PickRules.split(t, .things), ns = t as NSString
        eq(ps.map(\.kind), ["date", "amount", "email", "link", "date", "amount"], "basic things in order")
        eq(ps.map { ns.substring(with: $0.range) }, ["2026-11-20", "$1,200", "pay@example.com", "https://example.com/inv/7", "15 листопада", "3 400 грн"],
           "thing ranges exact, a link without its last dot")
        // an injected detector wins and its labels stay; overlaps keep the first, longest
        let fake: PickThings = { s in
            let n = s as NSString
            return [(n.range(of: "Olena Bondar"), "person", "Olena"), (n.range(of: "Bondar"), "person", "B"), (n.range(of: "Lantern"), "project", "Lantern")]
        }
        let q = PickRules.split("Olena Bondar works on Lantern.", .things, things: fake)
        eq(q.map(\.label), ["Olena", "Lantern"], "injected things, overlap dropped")
        eq(q.map(\.kind), ["person", "project"], "injected kinds")
    }

    static func start() {
        eq(PickRules.startLevel("Buy:\n- milk\n- bread\n- eggs\n- tea"), .items, "a list starts at items")
        eq(PickRules.startLevel("Olena\nTaras\nMaksym\nIryna\nPetro"), .lines, "short lines start at lines")
        eq(PickRules.startLevel("We met today. The plan changed. Rent goes up. Olena agreed. Next week we sign."), .sentences, "prose starts at sentences")
        let long = (1...4).map { n in (1...5).map { "Sentence \($0) of part \(n)." }.joined(separator: " ") }.joined(separator: "\n\n")
        eq(PickRules.startLevel(long), .paragraphs, "long prose starts at paragraphs")
        check(!PickRules.worthPicking("Short one. Two."), "short text is not offered")
        check(PickRules.worthPicking("One is here. Two is here. Three is here. Four is here. Five is here now."), "4+ sentences offered")
        check(PickRules.worthPicking("a line here\nb line here\nc line here\nd line here\ne line here\nf line here"), "5+ lines offered")
    }

    static func quickPicks() {
        let t = "Alpha line.\nBeta has a link https://example.com.\nGamma on 2026-01-02.\nDelta.\nЇжак тут."
        let ps = PickRules.split(t, .lines)
        eq(PickRules.all(5), Set(0..<5), "all")
        eq(PickRules.toEnd(from: 3, 5), [3, 4], "from here to the end")
        eq(PickRules.toStart(from: 1, 5), [0, 1], "to the start")
        eq(PickRules.containing(t, ps, "LI"), [0, 1], "lines containing, case folded")
        eq(PickRules.containing(t, ps, "іжак"), [4], "folds ї")
        eq(PickRules.withKind(t, ps, "link"), [1], "lines with a link")
        eq(PickRules.withKind(t, ps, "date"), [2], "lines with a date")
    }

    static func joins() {
        let t = "One. Two. Three.\n\nFour. Five."
        let s = PickRules.split(t, .sentences)
        eq(PickRules.result(t, s, [0, 2], .sentences), "One. Three.", "sentences with a space")
        eq(PickRules.result(t, s, [2, 0, 3], .sentences), "One. Three.\n\nFour.", "original order; a new paragraph gets an empty line")
        let l = "- milk   \n- bread\n- eggs"
        let li = PickRules.split(l, .items)
        eq(PickRules.result(l, li, [0, 2], .items), "- milk\n- eggs", "items with a line break, trailing spaces trimmed")
        eq(PickRules.result(l, li, [0, 2], .items, marks: false), "milk\neggs", "marks dropped")
        let p = PickRules.split(t, .paragraphs)
        eq(PickRules.result(t, p, [0, 1], .paragraphs), t, "paragraphs with an empty line")
        eq(PickRules.result(t, s, [], .sentences), "", "nothing picked")
    }

    static func rest() {
        let t = "One. Two. Three.\nFour."
        let s = PickRules.split(t, .sentences)
        eq(PickRules.rest(t, s, [1]), "One. Three.\nFour.", "a middle sentence goes with one space")
        eq(PickRules.rest(t, s, [2]), "One. Two.\nFour.", "a last sentence on its line")
        eq(PickRules.rest(t, s, [3]), "One. Two. Three.", "a whole line goes with its break")
        eq(PickRules.rest(t, s, [0, 1, 2, 3]), "", "all picked: nothing left")
        let l = "a\n\nb\nc\n\nd"
        eq(PickRules.rest(l, PickRules.split(l, .lines), [1, 2]), "a\n\nd", "at most one empty line")
        // pick + rest cover every piece once
        let r = PickRules.result(t, s, [0, 2], .sentences), back = PickRules.rest(t, s, [1, 3])
        eq(r, back.replacingOccurrences(of: "\n", with: " "), "the pick and the rest of its inverse agree")
    }

    static func carry() {
        let t = "One. Two.\n\nThree. Four."
        let s = PickRules.split(t, .sentences), p = PickRules.split(t, .paragraphs)
        eq(PickRules.carry(s, [0, 1], to: p), [0], "two sentences carry their paragraph")
        eq(PickRules.carry(s, [0], to: p), [], "half a paragraph minus a space does not")
        eq(PickRules.carry(p, [1], to: s), [2, 3], "a paragraph carries its sentences")
    }

    static func keys() {
        let t = "One. Two. Three. Four. Five has a link https://example.com here. Six."
        var st = PickState(text: t, level: .sentences)
        eq(st.pieces.count, 6, "six sentences")
        _ = st.key(.space); eq(st.picked, [0], "space picks")
        _ = st.key(.down); _ = st.key(.down); _ = st.key(.space); eq(st.picked, [0, 2], "move and pick")
        _ = st.key(.space); eq(st.picked, [0], "space unpicks")
        _ = st.key(.undo); eq(st.picked, [0, 2], "undo the unpick")
        _ = st.key(.shiftDown); _ = st.key(.shiftDown); eq(st.picked, [0, 2, 3, 4], "shift-down picks a run")
        _ = st.key(.shiftUp); eq(st.picked, [0, 2, 3], "shift-up shortens the run")
        _ = st.key(.undo); eq(st.picked, [0, 2], "the run is one undo step")
        _ = st.key(.char("i")); eq(st.picked, [1, 3, 4, 5], "I inverts")
        _ = st.key(.char("n")); eq(st.picked, [], "N none")
        _ = st.key(.char("a")); eq(st.picked.count, 6, "A all")
        _ = st.key(.char("n")); _ = st.key(.char("l")); eq(st.picked, [4], "L picks the pieces with a link")
        check(st.key(.char("d")) == .nothing("No dates here"), "D with no dates says so")
        _ = st.key(.char("n")); st.cursor = 4; _ = st.key(.toEnd); eq(st.picked, [4, 5], "from here to the end")
        eq(st.key(.enter), .save("Five has a link https://example.com here. Six."), "Return keeps the pick")
        if case .insert = st.key(.cmdEnter) {} else { check(false, "⌘Return inserts") }
        eq(st.key(.optEnter), .saveRest("One. Two. Three. Four."), "⌥Return keeps the rest")
        eq(st.status.count, "2 of 6 sentences · 46 characters", "status line")
        // levels: 1-5, picks carried, undo restores the level
        _ = st.key(.char("2")); eq(st.level, .lines, "2 = lines"); eq(st.picked, [0], "the one line, mostly picked, carries")
        _ = st.key(.undo); eq(st.level, .sentences, "undo the level"); eq(st.picked, [4, 5], "and its pick")
        _ = st.key(.char("5")); eq(st.level, .things, "5 = things"); eq(st.picked, [0], "the link inside a picked sentence carries")
        // filter
        var f = PickState(text: "Apples are red.\nPears are green.\nPlums are red too.", level: .lines)
        _ = f.key(.char("/")); check(f.filtering, "/ starts the filter")
        for c in "red" { _ = f.key(.char(String(c))) }
        eq(f.shown, [0, 2], "filter shows lines containing red")
        _ = f.key(.enter); check(!f.filtering && f.query == "red", "Return ends typing, keeps the filter")
        _ = f.key(.char("a")); eq(f.picked, [0, 2], "A picks all in view: lines containing")
        eq(f.key(.esc), .redraw, "Esc clears the filter first"); eq(f.shown.count, 3, "all lines again")
        eq(f.key(.esc), .close, "then Esc closes")
        var e = PickState(text: "Just one. Two.", level: .sentences)
        eq(e.key(.enter), .nothing("Nothing picked"), "Return with nothing picked")
        _ = e.key(.char("/")); _ = e.key(.char("x")); _ = e.key(.backspace); _ = e.key(.backspace)
        check(!e.filtering, "backspace on an empty filter leaves it")
        eq(e.key(.undo), .nothing("Nothing to undo"), "nothing to undo")
        var m = PickState(text: "- milk\n- bread")
        eq(m.level, .items, "a list opens at items")
        _ = m.key(.char("a")); _ = m.key(.char("m"))
        eq(m.key(.enter), .save("milk\nbread"), "M drops the marks")
    }

    static func keyMap() {
        let m = PickKeyMap.map
        eq(m(0, "ф", false, false, false, false), .char("a"), "A by its place on the Ukrainian layout")
        eq(m(0, "ф", false, false, false, true), .char("ф"), "a letter is text while filtering")
        eq(m(125, "", true, true, false, false), .toEnd, "⇧⌘↓ to the end")
        eq(m(126, "", false, true, false, false), .shiftUp, "⇧↑")
        eq(m(36, "\r", true, false, false, false), .cmdEnter, "⌘↵")
        eq(m(36, "\r", false, false, true, false), .optEnter, "⌥↵")
        eq(m(6, "z", true, false, false, false), .undo, "⌘Z")
        eq(m(21, "$", false, true, false, false), .char("$"), "⇧4 amounts")
        eq(m(19, "2", false, false, false, false), .char("2"), "2 lines")
        eq(m(44, ".", false, false, false, false), .char("/"), "/ by place")
        check(m(6, "z", false, false, false, false) == nil, "a plain Z does nothing")
    }

    static func mouse() {
        var st = PickState(text: "A one. B two. C three. D four.", level: .sentences)
        st.click(1); eq(st.picked, [1], "click picks")
        st.drag(from: 2, to: 3, start: true); eq(st.picked, [1, 2, 3], "drag picks a run")
        st.drag(from: 2, to: 2, start: false); eq(st.picked, [1, 2], "the drag follows the mouse back")
        _ = st.key(.undo); eq(st.picked, [1], "a drag is one undo step")
        st.drag(from: 1, to: 0, start: true); eq(st.picked, [], "a drag from a picked piece unpicks")
    }

    static func record() {
        let src = "One. Two. Three."
        let id = PickRules.sourceId(kind: "copied", text: src)
        eq(id, PickRules.sourceId(kind: "copied", text: src), "source id is stable")
        check(id != PickRules.sourceId(kind: "typed", text: src), "source id has the kind")
        let rec = PickRecord(text: "One. Three.", from: id, picked: [NSRange(location: 0, length: 4), NSRange(location: 10, length: 6)], at: 1_800_000_000.5)
        let row = rec.row(app: "Sample")
        eq(row["via"] as? String, "pick", "row marked")
        check(row["mine"] == nil, "not his writing: no mine")
        eq(PickRecord.read(row), rec, "read side round trip")
        check(PickRecord.read(["t": 1.0, "text": "plain old row", "app": "Notes"]) == nil, "an old row is not derived")
        // written to a temp folder and read back as JSON lines
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pick-test-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clipboard.jsonl")
        try? "{\"t\":1,\"text\":\"older row\",\"app\":\"Notes\"}\n".write(to: file, atomically: true, encoding: .utf8)
        PickRules.append(file, row)
        var mine = rec; mine.mine = true; mine.rest = true
        PickRules.append(file, mine.row(app: "Notes"))
        let lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n") ?? []
        eq(lines.count, 3, "two rows appended")
        let rows = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        check(PickRecord.read(rows[0]) == nil, "the old row loads as before")
        eq(PickRecord.read(rows[1]), rec, "the pick reads back")
        eq(PickRecord.read(rows[2])?.rest, true, "the rest is marked")
        eq(PickRecord.read(rows[2])?.mine, true, "his own writing is marked")
        check(PickRules.isRow(rows[1], of: rec), "undo finds its row"); check(!PickRules.isRow(rows[2], of: rec), "not the rest row")
        check(!PickRules.isRow(rows[0], of: rec), "undo leaves other rows")
    }

    static func speed() {
        let para = "Зустріч у пн. о 10:00 на вул. Хрещатик, 1. The budget grew by 2.5 percent, e.g. for rent. See https://example.com/a for it. "
        let big = (0..<40).map { _ in String(repeating: para, count: 5) }.joined(separator: "\n\n")   // ~ 24k characters
        let t0 = Date()
        var n = 0
        for l in PickLevel.allCases { n += PickRules.split(big, l).count }
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "split all five levels of %d characters: %.0f ms (%d pieces)", big.count, ms, n))
        check(ms < 1500, "splitting a 24k text stays under 1.5 s")
    }
}
