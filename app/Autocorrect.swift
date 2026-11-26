// Autocorrect and the wrong-layout fix (2026-10-31), run when a word ends with Space.
// Typos: macOS's own correction (English, Ukrainian), only for a word that is neither in the spellchecker nor in the user's
// own words, all lowercase (names and capitals are left alone), one or two letters away. Surzhyk the user writes on purpose
// ("шо", "тіки", "щас") is in the user's words, so it stays. Wrong layout: KeyLayout.fix, and the keyboard switches with it.
// Backspace right after a fix puts the user's word back and counts it (data/autocorrect-keep.json): kept after the second take-back.
// Offer, not replace (13 November 2026): by default the fix shows as "→ word" after the space and Tab puts it in
// (Fixer.offer); setting `autocorrectMode` "replace" puts it in at once, as before. A week of the live log (6-13
// November): 408 automatic fixes, 250 taken back (typos 234 of 388, layout 16 of 20), 248 of them within a second.
// The keep list they built: 346 words, 261 a letter from a word the user writes (median 90 uses) and 257 of those never
// written by the user: the Backspace was their own correction of the typo, landing after Drafter had already fixed it.
// So a Backspace within `fastBackspace` of an automatic fix is the user's and goes to the app (the fix stays, the space goes),
// and a take-back counts towards the keep list only when the word the user got back still stands 2 s later.
// Later, until the sentence ends: the dotted underline under the fixed word, its chip, a click or Tab (FixMarks.swift).
// macOS's own autocorrect is off on this Mac (NSAutomaticSpellingCorrectionEnabled 0), so nothing fixes twice.
import AppKit

enum Autocorrect {
    struct Fix { let old: String; let new: String; let kind: String; let revision: Int; let el: AXUIElement; let at: Date; let wasUk: Bool
        var deliberate = false   // put in by the user's Tab (an offer or the mid-word ghost), not by itself
    }
    /// Faster than the user could have seen the fix: the Backspace was meant for their own typo (log: 248 of 250 take-backs
    /// came within the same or the next second; the log has no finer times, so this is a judgement, logged per take-back).
    static let fastBackspace = 0.5
    static var last: Fix?
    /// Words the user put back after a fix this run (take-back, undo chip): never a typo for the typo hold (TypoHold), even
    /// before the keep list counts them. Memory only.
    static var spared = Set<String>()
    private static var mine = Set<String>(), names = Set<String>(), keep = Set<String>()
    private static var counts: [String: Int] = [:]
    private static var ownIndex = CorrectionRules.Index([:]), restored = ""
    private static var loadedSnapshot: UUID?
    private static let countWriter = DispatchQueue(label: "drafter.autocorrect-counts", qos: .utility)
    private struct Snapshot {
        let id = UUID()
        let mine: Set<String>, names: Set<String>, counts: [String: Int], index: CorrectionRules.Index
    }
    private static let files = LocalSnapshot<Snapshot>(["mywords.txt", "known-words.txt", "myword-counts.json", "autocorrect-keep.txt", "autocorrect-keep.json"].map { Home.data.appendingPathComponent($0) }) { data in
        func words(_ i: Int) -> Set<String> { Set(String(decoding: data[i] ?? Data(), as: UTF8.self).split(separator: "\n").map { $0.lowercased() }) }
        func counts(_ i: Int) throws -> [String: Int] {
            guard let bytes = data[i] else { return [:] }
            return try JSONDecoder().decode([String: Int].self, from: bytes)
        }
        return try Snapshot(mine: words(0), names: words(1),
            counts: CorrectionRules.counts(legacy: String(decoding: data[3] ?? Data(), as: UTF8.self), saved: counts(4)),
            index: CorrectionRules.Index(counts(2)))
    }
    @discardableResult static func refresh() -> Bool {
        guard let snapshot = files.read() else { return false }
        guard snapshot.id != loadedSnapshot else { return true }
        loadedSnapshot = snapshot.id
        // Preserve the previous protection if an older non-atomic writer was caught mid-write.
        if snapshot.mine.count >= mine.count / 2 { mine = snapshot.mine }
        names = snapshot.names; ownIndex = snapshot.index
        // A queued read cannot undo a just-recorded take-back.
        for (word, count) in snapshot.counts { counts[word] = max(counts[word] ?? 0, count) }
        keep = CorrectionRules.kept(counts)
        return true
    }
    static func readCounts(_ name: String) -> [String: Int] {
        guard let data = try? Data(contentsOf: Home.data.appendingPathComponent(name)),
              let values = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return values
    }
    static func reloadCounts() {
        let legacy = (try? String(contentsOf: Home.data.appendingPathComponent("autocorrect-keep.txt"), encoding: .utf8)) ?? ""
        for (word, count) in CorrectionRules.counts(legacy: legacy, saved: readCounts("autocorrect-keep.json")) {
            counts[word] = max(counts[word] ?? 0, count)
        }
        keep = CorrectionRules.kept(counts)
    }
    static func known(_ w: String) -> Bool {
        refresh()
        let l = w.lowercased(); return mine.contains(l) || names.contains(l) || keep.contains(l)
    }
    static func nameStarts(_ w: String) -> Bool {
        refresh(); let low = w.lowercased()
        return names.contains { $0.hasPrefix(low) }
    }

    static let russian = CharacterSet(charactersIn: "ыэъёЫЭЪЁ")

    /// `before` ends with the space just typed: (what to replace, with what, kind) for the word before it.
    static func check(_ given: String, layout: Bool, typos: Bool, typosUk: Bool = false, ranked: Bool = false, app: String = "", appKind: String = "other") -> (old: String, new: String, kind: String)? {
        // Chromium rich boxes keep a typed space at the end as a no-break space (2026-11-01: no fixes there at all)
        let before = given.replacingOccurrences(of: "\u{A0}", with: " ")
        guard before.hasSuffix(" "), !before.hasSuffix("  ") else { return nil }
        guard refresh() else { return nil }
        let line = String((before.components(separatedBy: "\n").last ?? "").dropLast())
        guard let token = line.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init), !token.isEmpty else { return nil }
        if token.trimmingCharacters(in: .punctuationCharacters).lowercased() == restored {
            restored = ""; return nil
        }
        restored = ""
        if layout, let f = KeyLayout.fix(token, known: known) { return (f.old + " ", f.new + " ", f.toUk ? "layout uk" : "layout en") }
        guard typos else { return nil }
        // 15 November 2026: the ranked fix (app/TypoEngine.swift) instead of the macOS-only one below
        if ranked { return TypoEngine.check(token, line: line, app: app, kind: appKind, typosUk: typosUk) }
        // the word without quotes and brackets in front and punctuation after it
        let lead = token.prefix { "(\"«'„“".contains($0) }, rest = token.dropFirst(lead.count)
        let core = String(rest.reversed().drop { ",.!?;:)»\"”".contains($0) }.reversed())
        let tail = String(rest.dropFirst(core.count))
        guard core.count >= 3, core.count <= 24, core == core.lowercased(),
              core.allSatisfy({ $0.isLetter || "'’".contains($0) }), core.unicodeScalars.allSatisfy({ !russian.contains($0) }) else { return nil }
        let uk = core.unicodeScalars.contains { KeyLayout.cyr.contains($0) }
        // Ukrainian typos only when switched on: on the user's history the Ukrainian dictionary "fixed" real forms
        // (доробляв -> доробляє, колаба -> колба) as often as typos; English was right 10 of 10 (2026-10-31)
        if uk && !typosUk { return nil }
        let lang = uk ? "uk" : "en"
        guard !known(core), !Spell.known(core, lang) else { return nil }
        if let own = CorrectionRules.candidate(core, index: ownIndex, ukrainian: uk),
           own.unicodeScalars.allSatisfy({ !russian.contains($0) }) {
            return (token + " ", String(lead) + own + tail + " ", "typo")
        }
        guard let c = Spell.correction(core, lang), c != core,
              c == c.lowercased(), c.allSatisfy({ $0.isLetter || "'’".contains($0) }),
              c.unicodeScalars.allSatisfy({ !russian.contains($0) }),
              distance(core, c) <= (uk ? 1 : 2),
              // typos almost never hit the first letter, and a 3-letter word is often the user's acronym (mvp, lem):
              // there only a swap of two letters counts (teh, nad); 2026-10-31 history check
              c.first == core.first, core.count > 3 || (c.count == 3 && Set(c) == Set(core)) else { return nil }
        return (token + " ", String(lead) + c + tail + " ", "typo")
    }

    /// Replace the word in the field (key events, as a snippet does) and remember it for Backspace.
    static func replace(_ f: (old: String, new: String, kind: String), at s: Spot) {
        let wasUk = KeyLayout.ukrainianNow
        Keys.shared.cancel()
        Focus.backspace(f.old.count)
        Focus.typeText(f.new)
        if f.kind == "layout uk" { KeyLayout.select(uk: true) } else if f.kind == "layout en" { KeyLayout.select(uk: false) }
        last = Fix(old: f.old, new: f.new, kind: f.kind, revision: Keys.shared.editRevision, el: s.el, at: Date(), wasUk: wasUk)
        log("autocorrect \(f.kind) \(f.old.count) -> \(f.new.count) chars" + TypoEngine.tail(f.new))
        FixMarks.shared.add(new: f.new, old: f.old, kind: f.kind, wasUk: wasUk, el: s.el, pid: s.app.processIdentifier, markers: s.viaMarkers)
    }

    /// A fix at a word end: offered as "→ word" (Tab takes it), or in "replace" mode put in at once.
    static func apply(_ f: (old: String, new: String, kind: String), at s: Spot) {
        // "sure" mode: the ranked fix goes in by itself only when its gate is past `fixAt`, else it is offered
        if Drafter.shared.settings.autocorrectMode != "replace" && !TypoEngine.sure(f.new) { Fixer.offer(old: f.old, new: f.new, kind: f.kind, at: s); return }
        replace(f, at: s)
    }

    /// Backspace as the very next key after a fix: the user's word comes back (without the space); it counts one take-back
    /// once it still stands 2 s later. A Backspace faster than the user could have seen an automatic fix is their own edit:
    /// false, so it goes to the app.
    static func takeBack() -> Bool {
        guard let f = last, Keys.shared.editRevision == f.revision + 1, Date().timeIntervalSince(f.at) < 8 else { last = nil; return false }
        last = nil
        let ms = Int(Date().timeIntervalSince(f.at) * 1000)
        if !f.deliberate, Date().timeIntervalSince(f.at) < fastBackspace {
            log("autocorrect kept, backspace \(ms)ms is the user's own (\(f.kind))")
            return false
        }
        DispatchQueue.main.async {
            guard let s = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(s.el, f.el), s.before.replacingOccurrences(of: "\u{A0}", with: " ").hasSuffix(f.new) else { return }
            Focus.backspace(f.new.count)
            Focus.typeText(String(f.old.dropLast()))
            if f.kind.hasPrefix("layout") { KeyLayout.select(uk: f.wasUk) }
            FixMarks.shared.clear()
            let word = String(f.old.dropLast())
            restored = word.trimmingCharacters(in: .punctuationCharacters).lowercased()   // the next space leaves it alone
            Fixer.refused = word.lowercased()
            spared.insert(restored)
            log("autocorrect taken back (\(f.kind)) \(ms)ms" + (f.deliberate ? " after tab" : ""))
            keepIfStands(word, el: f.el)
        }
        return true
    }

    /// A take-back teaches the keep list only when the user leaves the word as it came back: 2 s later it is still a whole
    /// word in the last few lines before the caret. If the user went on deleting into it, it was a typo the user was fixing.
    static func keepIfStands(_ word: String, el: AXUIElement, after: Double = 2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            guard let s = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(s.el, el) else { log("autocorrect take-back not counted: field changed"); return }
            if stands(word, in: s.before) { keepWord(word) } else { log("autocorrect take-back not counted: edited") }
        }
    }

    /// The word, whole, among the last words before the caret (pure, for tests).
    static func stands(_ word: String, in before: String) -> Bool {
        let w = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
        guard !w.isEmpty else { return false }
        let tail = String(before.replacingOccurrences(of: "\u{A0}", with: " ").suffix(w.count + 300)).lowercased()
        return tail.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.contains(w)
    }

    /// The user's word, put back: kept after two take-backs; the legacy text file counts as one.
    static func keepWord(_ old: String) {
        let word = old.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .punctuationCharacters).lowercased()
        guard !word.isEmpty else { return }
        reloadCounts()
        CorrectionRules.takeBack(word, counts: &counts)
        let file = Home.data.appendingPathComponent("autocorrect-keep.json")
        let saved = counts
        countWriter.async {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
            files.invalidate()
        }
        keep = CorrectionRules.kept(counts)
    }

    /// Double Shift: the last word (or the selection) goes into the other layout and the keyboard switches with it;
    /// with nothing typed it only switches the keyboard.
    static func switchLast() {
        // insert audit 2026-11-23: spot gives no spot for a selection ("selection"), so the selection branch never ran
        // after it; the read's own order keeps skipped apps, secure input and password fields out (InsertRules.layoutWay)
        let (sp, why) = Focus.spot(skip: Drafter.shared.settings.skip)
        let sel = sp == nil && why == "selection" ? Focus.selectedText() : nil
        switch InsertRules.layoutWay(spot: sp != nil, why: why, selection: sel != nil) {
        case .keyboardOnly: KeyLayout.select(uk: !KeyLayout.ukrainianNow); return
        case .selection:
            guard let sel else { return }
            let toUk = sel.unicodeScalars.contains { KeyLayout.latin.contains($0) }
            Focus.typeText(KeyLayout.convert(sel, toUk: toUk))
            KeyLayout.select(uk: toUk); log("layout switch: selection"); return
        case .lastWord: break
        }
        guard let s = sp else { return }
        let line = s.before.components(separatedBy: "\n").last ?? ""
        let trailing = line.reversed().prefix { $0 == " " }.count
        let token = String(line.dropLast(trailing).split(separator: " ", omittingEmptySubsequences: false).last ?? "")
        guard !token.isEmpty else { KeyLayout.select(uk: !KeyLayout.ukrainianNow); log("layout switch: keyboard"); return }
        let toUk = token.unicodeScalars.contains { KeyLayout.latin.contains($0) }
        let new = KeyLayout.convert(token, toUk: toUk)
        Focus.backspace(token.count + trailing)
        Focus.typeText(new + String(repeating: " ", count: trailing))
        KeyLayout.select(uk: toUk)
        log("layout switch: last word")
    }

    /// Letters to change, one swap of neighbours counting as one.
    static func distance(_ a: String, _ b: String) -> Int {
        CorrectionRules.distance(a, b)
    }
}

extension Autocorrect {
    /// `Drafter --autocorrect-test`: fixed cases, then every word of data/typed.jsonl as if Space ended it; prints what
    /// would change, so false fixes show before the user meets them. Nothing is typed anywhere.
    static func selfTest() {
        files.invalidate()
        let deadline = Date().addingTimeInterval(5)
        while !refresh() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard refresh() else { print("word snapshot unavailable"); return }
        print("layout map: \(KeyLayout.maps.toUk.count) keys; known words \(mine.count)")
        let cases: [(String, String?)] = [
            ("ghbdsn ", "привіт "), ("lj,hjuj ", "доброго "), ("руддщ ", "hello "), ("incoporatng ", "incorporating "),
            ("teh ", "the "), ("recieve ", "receive "), ("привт ", nil), ("шо ", nil), ("тіки ", nil), ("drafter ", nil),
            ("pixelkit ", nil), ("Madeupenko ", nil), ("ok ", nil), ("cool, ", nil), ("https://docs.new ", nil), ("ghbdsn, ", "привіт, ")]
        var bad = 0
        for (input, want) in cases {
            let got = check(input, layout: true, typos: true).map { String(input.dropLast($0.old.count)) + $0.new }
            let ok = got == want
            if !ok { bad += 1 }
            print(ok ? "ok  " : "FAIL", input, "->", got ?? "-", ok ? "" : "(want \(want ?? "-"))")
        }
        // the user's history: what would have changed
        let t = (try? String(contentsOf: Home.data.appendingPathComponent("typed.jsonl"), encoding: .utf8)) ?? ""
        var words = 0, fixes: [String: Int] = [:]
        for row in t.split(separator: "\n") {
            guard let j = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any], let text = j["text"] as? String else { continue }
            var before = ""
            for ch in text {
                before.append(ch)
                if ch == " " {
                    words += 1
                    if let f = check(before, layout: true, typos: true) { fixes["\(f.kind): \(f.old)-> \(f.new)", default: 0] += 1 }
                }
            }
        }
        print("history: \(words) words, \(fixes.values.reduce(0, +)) fixes")
        // recall: the user's own words typed in the other layout should come back
        var back = 0, tried = 0, misses: [String] = []
        for w in mine.shuffled().prefix(800) where w.count >= 3 && w.allSatisfy({ $0.isLetter }) {
            let uk = w.unicodeScalars.contains { KeyLayout.cyr.contains($0) }
            let typed = KeyLayout.convert(w, toUk: !uk)
            guard typed != w else { continue }
            tried += 1
            if let f = check(typed + " ", layout: true, typos: false), f.new == w + " " { back += 1 } else if misses.count < 12 { misses.append("\(typed)→\(w)") }
        }
        print("layout recall: \(back) of \(tried) of the user's words typed in the other layout came back; missed e.g. \(misses.joined(separator: ", "))")
        for (k, n) in fixes.sorted(by: { $0.value > $1.value }).prefix(80) { print("  \(n)× \(k)") }
        print(bad == 0 ? "all cases ok" : "\(bad) cases failed")
    }
}
