import Foundation

// swiftc -parse-as-library -O app/TypoGraphRules.swift tests/typography_rules.swift -o app/build/typography-rules-test && app/build/typography-rules-test
// Typography as you type (15 November 2026) with made-up lines: each combo fires, each guard holds, Ukrainian and
// English quotes, nested quotes, the apostrophe only between Ukrainian letters, take-back data, and the rule's time.
@main
struct TypographyChecks {
    static var failures = 0, cases = 0
    static func check(_ ok: Bool, _ what: String) { cases += 1; if !ok { print("FAIL: " + what); failures += 1 } }

    /// The field after typing `key` behind `before`, with the swap applied (or the key as it is).
    static func typed(_ before: String, _ key: String, uk: Bool = false, _ o: TypoOptions = TypoOptions()) -> String {
        guard let s = TypoGraphRules.swap(before: before, key: key, ukrainian: uk, options: o) else { return before + key }
        return String(before.dropLast(s.remove)) + s.insert
    }
    static func expect(_ before: String, _ key: String, _ want: String, uk: Bool = false, _ o: TypoOptions = TypoOptions()) {
        let got = typed(before, key, uk: uk, o)
        check(got == want, "\(before.debugDescription) + \(key.debugDescription) -> \(got.debugDescription), want \(want.debugDescription)")
    }
    /// Types `text` key by key, each key seeing the field as the swaps left it.
    static func run(_ text: String, uk: Bool = false, _ o: TypoOptions = TypoOptions()) -> String {
        var field = ""
        for ch in text { field = typed(field, String(ch), uk: uk, o) }
        return field
    }

    static func main() {
        dashes(); dots(); quotes(); apostrophe(); arrowsMath(); symbols(); offByDefault(); guards(); options(); helpers(); timing()
        if failures > 0 { print("\(failures) of \(cases) failed"); exit(1) }
        print("typography rules: all \(cases) passed")
    }

    static func dashes() {
        // `--` fires lazily, on the key after it
        expect("wait --", " ", "wait — ")
        expect("so--", ",", "so—,")
        expect("word--", "w", "word—w")                       // word--word: a dash
        check(run("це -- не те") == "це — не те", "typed through: це -- не те")
        expect("-- ", "x", "-- x")                            // nothing pending
        expect("--", " ", "— ")                               // line start, then space: a dialogue dash
        // the flag case stays
        expect("run it --", "v", "run it --v")
        expect("--", "v", "--v")
        check(run("try git log --oneline today") == "try git log --oneline today", "a CLI flag typed through stays")
        expect("a --", "-", "a ---")                          // a third hyphen: no swap
        expect("a ---", " ", "a --- ")                        // `---` stays
        expect("a --", ">", "a -->")                          // `-->` stays
        // a spaced hyphen between words
        expect("Kyiv -", " ", "Kyiv — ")
        expect("тиша -", " ", "тиша — ", uk: true)
        expect("(so) -", " ", "(so) — ")
        expect("5 -", " ", "5 - ")                            // a minus
        expect("-", " ", "- ")                                // a list item
        expect("a -", " ", "a — ")
    }

    static func dots() {
        expect("well..", ".", "well…")
        check(run("hmm... ok") == "hmm… ok", "typed through: hmm... ok")
        expect("1..", ".", "1...")                            // a range
        expect("well...", ".", "well....")                    // a fourth dot: no swap (the third already did)
        expect("../src/..", ".", "../src/...")                // a path
    }

    static func quotes() {
        expect("he said ", "\"", "he said “", uk: false)
        expect("he said “yes", "\"", "he said “yes”", uk: false)
        expect("каже ", "\"", "каже «", uk: true)
        expect("каже «так", "\"", "каже «так»", uk: true)
        expect("", "\"", "«", uk: true)                       // line start opens
        expect("(", "\"", "(«", uk: true)                     // after a bracket opens
        // nested in «»: „“
        expect("назва «Клуб ", "\"", "назва «Клуб „", uk: true)
        expect("назва «Клуб „Сад", "\"", "назва «Клуб „Сад“", uk: true)
        expect("назва «Клуб „Сад“", "\"", "назва «Клуб „Сад“»", uk: true)
        check(run("вона читала \"Пісню про \"Сад\" і ліс\" вчора", uk: true) == "вона читала «Пісню про „Сад“ і ліс» вчора", "nested typed through: \(run("вона читала \"Пісню про \"Сад\" і ліс\" вчора", uk: true))")
        check(run("say \"hi\" now") == "say “hi” now", "English typed through")
        expect("5'10", "\"", "5'10\"")                         // inches stay
        expect("a href=", "\"", "a href=\"")                   // code: =
        expect("{", "\"", "{\"")                               // JSON
    }

    static func apostrophe() {
        expect("п'", "я", "пʼя", uk: true)
        check(run("м'ята і сім'я", uk: true) == "мʼята і сімʼя", "typed through: м'ята і сім'я")
        expect("don'", "t", "don't")                          // English stays
        expect("п'", "t", "п't")                              // Latin after: stays
        expect("'", "я", "'я", uk: true)                      // no letter before
        expect("d'", "я", "d'я", uk: true)                    // a Latin letter before
        var o = TypoOptions(); o.apostropheMark = "’"
        expect("б'", "ю", "б’ю", uk: true, o)
        let s = TypoGraphRules.swap(before: "п'", key: "я", ukrainian: true)
        check(s == TypoSwap(kind: "apostrophe", remove: 1, insert: "ʼя", plain: "'я"), "apostrophe swap data: \(String(describing: s))")
    }

    static func arrowsMath() {
        expect("A -", ">", "A →")
        expect("then <", "-", "then ←")
        expect("then ←", ">", "then ↔")
        expect("a --", ">", "a -->")
        expect("<!-", "-", "<!--")                            // an HTML comment: no dash, no arrow
        expect("x =", "-", "x =-")
        expect("10 +", "-", "10 ±")
        expect("c++", "-", "c++-")
        expect("3x", "4", "3×4")
        expect("1920х", "1", "1920×1", uk: true)              // Cyrillic х
        expect("0x", "1", "0x1")                              // hex stays
        expect("ab2x", "3", "ab2x3")                          // an identifier stays
        expect("x", "4", "x4")                                // no digit before x
    }

    static func symbols() {
        expect("(c", ")", "©")
        expect("Acme (C", ")", "Acme ©")
        expect("(r", ")", "®")
        expect("Name(tm", ")", "Name(tm)")                    // `(` must start the token
        expect("Name (TM", ")", "Name ™")
        expect("(с", ")", "©", uk: true)                       // Cyrillic с
        expect("f(c", ")", "f(c)")                            // a call
        expect("(x", ")", "(x)")
    }

    static func offByDefault() {
        expect("100 грн", " ", "100 грн ")
        expect("в", " ", "в ")
        var o = TypoOptions(); o.hryvnia = true; o.nbsp = true
        expect("ціна 100 грн", " ", "ціна 100 ₴ ", uk: true, o)
        expect("ціна 100 грн", ".", "ціна 100 ₴.", uk: true, o)
        expect("сто грн", " ", "сто грн ", uk: true, o)        // no number
        expect("100грн", " ", "100грн ", uk: true, o)          // no space before грн
        expect("іду в", " ", "іду в\u{A0}", uk: true, o)
        expect("і", " ", "і\u{A0}", uk: true, o)
        expect("слово", " ", "слово ", uk: true, o)
        expect("(а", " ", "(а\u{A0}", uk: true, o)
        expect("ба", " ", "ба ", uk: true, o)                  // not a one-letter word
    }

    static func guards() {
        expect("see https://x.io/a--", " ", "see https://x.io/a-- ")    // URL
        expect("see www.site..", ".", "see www.site...")
        expect("mail me@example.com --", "b", "mail me@example.com --b")
        expect("me@host--", " ", "me@host-- ")                          // email
        expect("cd ~/src/a-", ">", "cd ~/src/a->")                       // path
        expect("open file.md..", ".", "open file.md...")                 // file name
        expect("run `a --", " ", "run `a -- ")                           // inline code
        expect("ok `x` then --", " ", "ok `x` then — ")                  // closed inline code: prose again
        expect("```\nlet a = b -", ">", "```\nlet a = b ->")             // code block
        expect("snake_case..", ".", "snake_case...")
        expect("2 -", " ", "2 - ")                                       // digits: minus
        expect("e.g", ".", "e.g.")                                       // a short abbreviation is prose
        expect("т.д..", ".", "т.д…")
    }

    static func options() {
        var o = TypoOptions(); o.dash = false; o.spacedDash = false; o.ellipsis = false; o.quotes = false
        o.apostrophe = false; o.arrows = false; o.math = false; o.symbols = false
        for (b, k) in [("a --", " "), ("a -", " "), ("a..", "."), ("a ", "\""), ("п'", "я"), ("a -", ">"), ("+", "-"), ("2x", "3"), ("(c", ")")] {
            check(TypoGraphRules.swap(before: b, key: k, ukrainian: true, options: o) == nil, "all off: \(b) + \(k)")
        }
    }

    static func helpers() {
        check(TypoGraphRules.ukrainian("hello світ, як справи") == true, "Ukrainian text")
        check(TypoGraphRules.ukrainian("hello there, ок") == false, "English text")
        check(TypoGraphRules.ukrainian("123 ...") == nil, "no letters")
        check(TypoGraphRules.mayFire(recent: "ab", key: "\""), "quote key reads the field")
        check(!TypoGraphRules.mayFire(recent: "ab", key: "c"), "a plain letter does not")
        check(TypoGraphRules.mayFire(recent: "п'", key: "я"), "a letter after an apostrophe does")
        check(TypoGraphRules.mayFire(recent: "a--", key: "w"), "a letter after -- does")
        check(TypoGraphRules.mayFire(recent: "3x", key: "4"), "a digit after x does")
        check(!TypoGraphRules.mayFire(recent: "34", key: "5"), "a digit after a digit does not")
        // take-back: the very next key, soon; the field must still end with the swap
        let s = TypoGraphRules.swap(before: "wait --", key: " ", ukrainian: false)!
        check(s.plain == "-- " && s.insert == "— " && s.remove == 2, "dash swap data: \(s)")
        check(TypoGraphRules.takeBack(rev: 11, swapRev: 10, now: 101, at: 100), "Backspace right after takes back")
        check(!TypoGraphRules.takeBack(rev: 12, swapRev: 10, now: 101, at: 100), "a key between: no take-back")
        check(!TypoGraphRules.takeBack(rev: 11, swapRev: 10, now: 109, at: 100), "too late: no take-back")
        check(TypoGraphRules.stillEnds(before: "wait — ", insert: s.insert), "field ends with the swap")
        check(TypoGraphRules.stillEnds(before: "в ", insert: "\u{A0}"), "a no-break space reads as a space")
        check(!TypoGraphRules.stillEnds(before: "wait —x", insert: s.insert), "field changed")
        // after a take-back the plain keys are back; the next key does not swap them again
        expect("wait ...", ".", "wait ....")
        expect("wait --", "-", "wait ---")
    }

    static func timing() {
        let lines = ["she said ", "назва «Клуб „Сад", "wait --", "п'", "1920x", "hello world and more text -", "(tm", "hmm..",
                     String(repeating: "довгий рядок тексту ", count: 20) + "--"]
        let keys = ["\"", "\"", " ", "я", "1", " ", ")", ".", " "]
        var times: [Double] = []
        for _ in 0..<2000 {
            for (b, k) in zip(lines, keys) {
                let t = DispatchTime.now().uptimeNanoseconds
                _ = TypoGraphRules.swap(before: b, key: k, ukrainian: true)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1000)
            }
        }
        times.sort()
        let p50 = times[times.count / 2], p99 = times[times.count * 99 / 100], mx = times.last!
        print(String(format: "rule time per call: p50 %.1f µs, p99 %.1f µs, max %.1f µs (%d calls)", p50, p99, mx, times.count))
        check(p50 < 1000, "rule p50 under 1 ms")
    }
}
