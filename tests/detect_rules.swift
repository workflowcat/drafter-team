import AppKit

// swiftc -O -parse-as-library app/DetectRules.swift app/DetectActions.swift app/ClipRules.swift tests/detect_rules.swift -o app/build/detect-test && app/build/detect-test
// What a text holds, with made-up lines in English and Ukrainian: each rule with things it must find and things it must
// not; relative dates resolved against the time the item was written (checked against the system's own text-checking
// API with a reference date); overlaps; the one-time code that never reaches a chip or the index; the summary order,
// the flags, the cache, the window for long texts; the actions, the .ics file and the issue links.
// `app/build/detect-test --measure` reads the live stores read-only and prints counts and timings only.
@main
struct DetectChecks {
    static var failures = 0, checks = 0
    static func check(_ ok: Bool, _ what: String) { checks += 1; if !ok { print("FAIL: " + what); failures += 1 } }
    static let tz = TimeZone(identifier: "Europe/Kyiv")!
    static var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = tz; c.firstWeekday = 2; return c }()
    static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 9, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    static let tue = at(2026, 11, 10)          // a Tuesday morning
    static let hints = DetectHints(timeZone: tz, home: "/Users/Shared")
    static func scan(_ s: String, _ w: Date = tue) -> [Found] { Detect.scan(s, written: w, hints: hints) }
    static func kinds(_ s: String, _ w: Date = tue) -> [String] { scan(s, w).map(\.kind.rawValue) }
    static func one(_ s: String, _ k: DetectKind, _ w: Date = tue) -> Found? { scan(s, w).first { $0.kind == k } }
    /// The thing of kind `k` must be found, with these words and this value.
    static func has(_ s: String, _ k: DetectKind, words: String? = nil, value: String? = nil, _ w: Date = tue) {
        guard let f = one(s, k, w) else { check(false, "\(k.rawValue) in «\(s)»: none, got \(kinds(s, w))"); return }
        if let x = words { check(f.words == x, "\(k.rawValue) words in «\(s)»: «\(f.words)» want «\(x)»") }
        if let v = value { check(f.value == v, "\(k.rawValue) value in «\(s)»: \(f.value) want \(v)") }
    }
    static func not(_ s: String, _ k: DetectKind, _ w: Date = tue) {
        check(one(s, k, w) == nil, "no \(k.rawValue) in «\(s)», got \(scan(s, w).filter { $0.kind == k }.map(\.words))")
    }
    static func nothing(_ s: String) { check(scan(s).isEmpty, "nothing in «\(s)», got \(scan(s))") }

    static func main() {
        if CommandLine.arguments.contains("--measure") { Measure.run(); return }
        links(); emails(); phones(); dates(); reanchor(); money(); paths(); code(); ids(); sensitive(); overlaps()
        adapter(); actions(); speed()
        print(failures == 0 ? "detect rules: \(checks) checks ok" : "detect rules: \(failures) of \(checks) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func links() {
        has("see https://example.com/a?b=1 now", .link, words: "https://example.com/a?b=1", value: "https://example.com/a?b=1")
        has("go to github.com today", .link, words: "github.com", value: "https://github.com")
        has("сайт example.ua і все", .link, value: "https://example.ua")
        has("www.example.org", .link)
        has("t.me/somechannel", .link, value: "https://t.me/somechannel")
        has("відкрий slack://open", .link, value: "slack://open")
        has("obsidian://open?vault=a", .link)
        has("dev on localhost:8080/x", .link, value: "http://localhost:8080/x")
        not("file.txt is a file", .link); has("file.txt is a file", .path, value: "file.txt")
        not("e.g. this one", .link)
        not("README.md and main.rs and config.py", .link)
        not("Drafter.app is installed", .link)
        not("node.js is fine", .link); not("node.js is fine", .path)
        not("ось note: це не посилання", .link)
        // a link wins over the domain-looking word and the file name inside it
        let f = scan("read https://example.com/docs/file.pdf please")
        check(f.count == 1 && f.first?.kind == .link, "one link, not a file inside it: \(f)")
    }
    static func emails() {
        has("write to Anna@Example.com please", .email, value: "anna@example.com")
        has("пиши на ivan.petrenko@example.org", .email, value: "ivan.petrenko@example.org")
        not("@handle is not mail", .email)
        not("user@ localhost", .email)
    }
    static func phones() {
        has("call +380 67 123 45 67", .phone, value: "+380671234567")
        has("тел. 067 123 45 67", .phone, value: "+380671234567")
        has("номер 0671234567", .phone, value: "+380671234567")
        has("+38 (067) 123-45-67", .phone, value: "+380671234567")
        has("+1 415 555 0123", .phone, value: "+14155550123")
        not("замовлення 1234567890", .phone)
        not("order 1234567890 shipped", .phone)
        not("рахунок № 067 123 45 67", .phone)
        not("1234567", .phone)
        not("у 2019 році", .phone)
    }
    static func dates() {
        has("meet tomorrow at 3pm", .date, words: "tomorrow at 3pm", value: "2026-11-11T15:00:00+02:00")
        has("зустрінемось завтра о 15:00", .date, words: "завтра о 15:00", value: "2026-11-11T15:00:00+02:00")
        has("о 15:00 завтра", .date, value: "2026-11-11T15:00:00+02:00")
        has("on Friday", .date, value: "2026-11-13")
        has("в понеділок", .date, value: "2026-11-16")
        has("наступної п'ятниці о 10", .date, words: "наступної п'ятниці о 10", value: "2026-11-20T10:00:00+02:00")
        has("next Friday", .date, value: "2026-11-20")
        has("наступного понеділка", .date, words: "наступного понеділка", value: "2026-11-16")
        has("наступного вівторка", .date, value: "2026-11-17")
        has("до 14.11", .date, words: "14.11", value: "2026-11-14")
        has("14.11 о 15:00", .date, words: "14.11 о 15:00", value: "2026-11-14T15:00:00+02:00")
        has("на 5.12", .date, value: "2026-12-05")
        has("14 листопада", .date, value: "2026-11-14")
        has("15 січня", .date, value: "2027-01-15")
        has("Nov 14 at 5pm", .date, value: "2026-11-14T17:00:00+02:00")
        has("14.11.2026", .date, value: "2026-11-14")
        has("2026-11-20", .date, value: "2026-11-20")
        has("через 2 дні", .date, value: "2026-11-12")
        has("через тиждень", .date, value: "2026-11-17")
        has("in 2 weeks", .date, value: "2026-11-24")
        has("in 3 days", .date, value: "2026-11-13")
        has("сьогодні ввечері", .date, value: "2026-11-10T17:00:00+02:00")
        // ranges
        has("з 10 до 12", .dateRange, value: "2026-11-10T10:00:00+02:00/2026-11-10T12:00:00+02:00")
        has("from 10:00 to 12:30", .dateRange, value: "2026-11-10T10:00:00+02:00/2026-11-10T12:30:00+02:00")
        has("from 2 to 4pm", .dateRange, value: "2026-11-10T14:00:00+02:00/2026-11-10T16:00:00+02:00")
        has("14-16 листопада", .dateRange, value: "2026-11-14/2026-11-16")
        has("з 14 по 16 листопада", .dateRange, value: "2026-11-14/2026-11-16")
        has("Nov 14-16", .dateRange)
        has("next week", .dateRange, value: "2026-11-16/2026-11-22")
        has("наступного тижня", .dateRange, value: "2026-11-16/2026-11-22")
        has("на вихідних", .dateRange, value: "2026-11-14/2026-11-15")
        // not dates
        not("версія 1.2.3 вийшла", .date); not("v2.0", .date); not("1.5 kg", .date); not("ratio 3:2", .date); not("16:9 screen", .date)
        not("ціна 14.99 грн", .date); not("10.5 kg", .date); not("о 12.12 подзвоню", .date)
        not("7/10 would buy again", .date); not("24/7 support", .date)
        not("з 10 до 12 людей", .dateRange); not("from 10 to 12 people", .dateRange)
        not("у 2019 році", .date); not("build 2048", .date); not("page 12", .date); not("у грудні", .date)
        not("3.10 за штуку", .date)
    }

    /// Relative dates follow the time the item was written, not the time it is viewed: the same words written on
    /// different days resolve differently, and agree with NSSpellChecker given that reference date.
    static func reanchor() {
        let sc = NSSpellChecker.shared
        let refs = [at(2026, 11, 13, 9), at(2026, 11, 13, 20), at(2026, 12, 20, 9), at(2026, 11, 15, 23, 30), at(2025, 3, 3, 10)]
        let cases = ["meet tomorrow at 3pm", "on Friday", "в п'ятницю", "next Friday", "Sunday", "14 листопада", "Nov 14", "о 15:00",
                     "tomorrow", "сьогодні ввечері", "tonight", "in 3 days", "14/11", "between 2 and 4pm", "з 10 до 12",
                     "вівторок о 10", "о 9 ранку", "в середу ввечері", "15 січня", "Jan 15", "вчора о 5", "післязавтра", "завтра о 15:00"]
        var agree = 0, total = 0
        for r in refs {
            for s in cases {
                let sys = sc.check(s, range: NSRange(location: 0, length: (s as NSString).length), types: NSTextCheckingResult.CheckingType.date.rawValue,
                                   options: [.referenceDate: r, .referenceTimeZone: tz], inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil).first
                guard let want = sys?.date else { continue }
                total += 1
                guard let got = scan(s, r).first(where: { $0.kind == .date || $0.kind == .dateRange })?.date else {
                    check(false, "reanchor «\(s)» at \(r): none"); continue
                }
                if abs(got.timeIntervalSince(want)) < 1 { agree += 1 }
                else { check(false, "reanchor «\(s)» at \(Detect.iso(r, allDay: false, cal: cal)): \(Detect.iso(got, allDay: false, cal: cal)) vs system \(Detect.iso(want, allDay: false, cal: cal))") }
            }
        }
        check(total >= 100 && agree == total, "agree with the reference-date API: \(agree) of \(total)")
        // the same words, two writing days
        check(one("tomorrow", .date, at(2026, 1, 5))?.value == "2026-01-06", "tomorrow from 5 Jan")
        check(one("завтра", .date, at(2026, 3, 31))?.value == "2026-04-01", "завтра from 31 Mar")
        check(one("14.11", .date, at(2027, 1, 20))?.value == "2027-11-14", "14.11 written in January: this November")
        check(one("14.05", .date, at(2026, 8, 1))?.value == "2027-05-14", "14.05 written in August: next May")
        check(one("через 2 дні", .date, at(2026, 2, 27))?.value == "2026-03-01", "через 2 дні over the month end")
        // the original words stay beside the resolved date
        let f = one("давай в понеділок о 10", .date)
        check(f?.words == "понеділок о 10" && f?.allDay == false, "words kept: \(String(describing: f?.words))")
    }

    static func money() {
        has("оплатити 1 200,50 грн", .money, value: "1200.5 UAH")
        has("$1,200.50 total", .money, value: "1200.5 USD")
        has("€20 for lunch", .money, value: "20 EUR")
        has("₴500", .money, value: "500 UAH")
        has("5k$", .money, value: "5000 USD")
        has("10 тис. грн", .money, value: "10000 UAH")
        has("UAH 300", .money, value: "300 UAH")
        has("50 доларів", .money, value: "50 USD")
        has("20 євро", .money, value: "20 EUR")
        has("1.200 грн", .money, value: "1200 UAH")
        has("12,5 грн", .money, value: "12.5 UAH")
        has("100 bucks", .money, value: "100 USD")
        not("100 людей", .money); not("1 200 штук", .money); not("$HOME is set", .money); not("сто гривень", .money)
        not("ціна 1200", .money)
    }
    static func paths() {
        has("see ~/Codius/Drafter/app here", .path, words: "~/Codius/Drafter/app", value: "/Users/Shared/Codius/Drafter/app")
        has("open /Users/Shared/Desktop/x.pdf.", .path, words: "/Users/Shared/Desktop/x.pdf", value: "/Users/Shared/Desktop/x.pdf")
        has("файл \"/Users/Shared/My File.txt\" тут", .path, value: "/Users/Shared/My File.txt")
        has("run ./scripts/run.sh", .path)
        has("змінив README.md", .path, value: "README.md")
        not("/clear the chat", .path); not("type /help", .path); not("1/2 of it", .path); not("та/або", .path)
        not("and/or this", .path)
    }
    static func code() {
        has("$ git push origin main", .command, value: "git push origin main")
        has("git push origin main", .command)
        has("cd ~/Codius && npm run dev", .command)
        has("use `npm run build` here", .command, value: "npm run build")
        has("the `foo_bar` field", .code, value: "foo_bar")
        has("const x = foo(); return x;", .code)
        has("```swift\nlet a = 1\nprint(a)\n```", .code, value: "let a = 1\nprint(a)")
        not("git is great", .command); not("make sure to go home", .command); not("find the file in ~/Downloads", .command)
        not("open the door please", .command); not("cat is sleeping.", .command)
        not("я запускаю git push сьогодні ввечері, добре?", .command)
        not("a = b in prose", .code)
    }
    static func ids() {
        has("IBAN UA21 3223 1300 0002 6007 2335 6600 1 please", .iban, value: "UA213223130000026007233566001")
        has("DE89370400440532013000", .iban, value: "DE89370400440532013000")
        not("IBAN UA21 3223 1300 0002 6007 2335 6600 2 wrong", .iban)
        has("ТТН 20450123456789", .tracking, value: "20450123456789")
        not("номер 20450123456789", .tracking)
        has("parcel RR123456785UA", .tracking); not("RR123456786UA", .tracking)
        has("1Z999AA10123456784", .tracking)
        has("fix owner/repo#123", .issue, value: "owner/repo#123")
        has("see PROJ-42 today", .issue, value: "PROJ-42")
        has("merged PR #77", .issue, value: "#77")
        not("COVID-19 and UTF-8 and SHA-256", .issue); not("ISO-8601", .issue); not("F-16", .issue)
        has("colour #ff8800", .color, value: "#ff8800"); has("#fff", .color); has("rgb(10, 20, 30)", .color)
        has("колір #a1b2c3", .color)
        not("#123 is an issue", .color); not("#bad day", .color); not("#decade of work", .color); not("#123456 order", .color)
        has("server 192.168.1.1:3000", .ip, value: "192.168.1.1:3000"); has("127.0.0.1", .ip)
        not("999.1.1.1", .ip); not("version 1.2.3.4", .ip)
        has("версія 1.2.3 вийшла", .version, value: "1.2.3"); has("v2.0 is out", .version, value: "2.0")
        has("macOS 15.1 too", .version, value: "15.1"); has("2.1.0-beta.1", .version)
        not("ціна 15.1 тис", .version); not("1.5 kg", .version); not("14.11.2026", .version)
    }
    static func sensitive() {
        for s in ["Your code is 482193", "ваш код підтвердження: 4821", "4821 is your verification code", "OTP 123 456", "Код: 90817263"] {
            let f = scan(s)
            check(f.count == 1 && f[0].kind == .oneTimeCode && f[0].sensitive, "one-time code in «\(s)»: \(f)")
            check(Detect.summary(f, now: tue).isEmpty, "no chip for a code: «\(s)»")
            check(Detect.flags(f) == DetectFlags(), "nothing indexed for a code: «\(s)»")
            check(!f.map(\.description).joined().contains(where: \.isNumber) || f.allSatisfy { !$0.description.contains($0.value) }, "description hides the code")
        }
        not("I wrote 4821 lines of code", .oneTimeCode)
        not("code review on 15 Nov", .oneTimeCode)
        not("call me at 0671234567", .oneTimeCode)
        not("ціна 4821 грн", .oneTimeCode)
    }
    static func overlaps() {
        // a date range over its two dates
        let r = scan("14-16 листопада")
        check(r.count == 1 && r[0].kind == .dateRange, "one range: \(r)")
        // one thing per span, in text order, no two overlapping
        let s = "Meet tomorrow at 10 at https://example.com/x, pay $20 to anna@example.com, call +380 67 123 45 67, ref owner/repo#5"
        let f = scan(s)
        check(f.map(\.kind) == [.date, .link, .money, .email, .phone, .issue], "order and kinds: \(f.map(\.kind.rawValue))")
        for (a, b) in zip(f, f.dropFirst()) { check(NSMaxRange(a.range) <= b.range.location, "no overlap \(a) \(b)") }
        // ranges point into the original text
        for x in f where x.kind != .oneTimeCode { check((s as NSString).substring(with: x.range) == x.words, "range matches words: \(x)") }
    }

    static func adapter() {
        let now = at(2026, 11, 12)
        let text = "Ready since 01.11 on https://example.com, it cost 1 200 грн; next demo next Friday at 10, ping anna@example.com, v1.2.3"
        let found = scan(text)
        let chips = Detect.summary(found, now: now)
        check(chips.map(\.kind) == [.date, .link, .money], "chips: a future date first, then link, money: \(chips.map(\.kind.rawValue))")
        check(chips.first?.value == "2026-11-20T10:00:00+02:00", "the future date, not the past one: \(String(describing: chips.first?.value))")
        check(Detect.summary(scan("v1.2.3 and README.md"), now: now).isEmpty, "no chip for a version or a bare file name")
        check(Detect.summary(scan("a.com a.com a.com b.org"), now: now).count == 2, "one chip per value")
        let fl = Detect.flags(found, timeZone: tz)
        check(fl.link && fl.date && fl.money && fl.email && !fl.phone && !fl.code, "flags: \(fl)")
        check(fl.days == ["2026-11-01", "2026-11-20"], "day keys: \(fl.days)")
        check(Detect.flags(scan("14-16 листопада"), timeZone: tz).days == ["2026-11-14", "2026-11-15", "2026-11-16"], "a range gives every day")
        check(Detect.flags(scan("$ ls -la"), timeZone: tz).code, "a command is code")
        // the window for long texts: the first `cap` characters, or the part on screen
        let filler = String(repeating: "просто слова без нічого ", count: 1200)       // ~29k characters
        let long = "start https://a.example.com " + filler + " end https://b.example.com"
        let head = Detect.scan(long, written: tue, hints: hints)
        check(head.count == 1 && head[0].value == "https://a.example.com", "long text: the head only: \(head.map(\.value))")
        let ns = long as NSString
        let tail = Detect.scan(long, written: tue, hints: hints, window: NSRange(location: ns.length - 30, length: 30))
        check(tail.count == 1 && tail[0].value == "https://b.example.com" && ns.substring(with: tail[0].range) == "https://b.example.com", "window: the tail, ranges in the whole text")
        let mid = Detect.scan("aaa https://x.example.com/long/path bbb", written: tue, hints: hints, window: NSRange(location: 12, length: 3))
        check(mid.first?.value == "https://x.example.com/long/path", "a window inside a word widens to the whole link")
    }

    static func actions() {
        func ids(_ s: String, _ k: DetectKind, _ ctx: DetectContext = DetectContext()) -> [String] {
            guard let f = one(s, k) else { return ["none"] }
            return DetectActions.actions(for: f, context: ctx).map(\.id)
        }
        check(ids("https://example.com", .link) == ["open", "copy", "markdown"], "link actions")
        check(ids("anna@example.com", .email) == ["compose", "copy"], "email actions")
        check(ids("+380 67 123 45 67", .phone) == ["call", "copy"], "phone actions")
        check(ids("завтра о 10", .date) == ["calendar", "iso", "remind"], "date actions")
        check(DetectActions.actions(for: one("завтра", .date)!).last?.built == false, "remind me is not built yet")
        check(ids("вул. Хрещатик 1, Київ", .address) == ["maps", "copy"], "address actions")
        check(ids("1 200 грн", .money) == ["number", "copy"], "money actions")
        check(ids("~/x/y", .path, DetectContext(exists: { _ in true })) == ["reveal", "copy"], "path that exists")
        check(ids("~/x/y", .path, DetectContext(exists: { _ in false })) == ["copy"], "path that does not exist")
        check(ids("$ ls -la", .command) == ["copy"], "command actions")
        check(ids("owner/repo#5", .issue) == ["copy"], "issue without a known host: copy only")
        check(ids("owner/repo#5", .issue, DetectContext(sourceLink: "https://github.com/owner/repo/pull/1")) == ["open", "copy"], "issue with a GitHub source")
        let all = [one("https://example.com", .link)!, one("завтра", .date)!, one("1 200 грн", .money)!]
        for f in all { for a in DetectActions.actions(for: f) {
            check(a.name.first!.isUppercase && !a.name.hasSuffix("ed") && !a.key.isEmpty, "imperative name and a key: \(a)")
        } }
        // copy texts
        let m = one("1 200,50 грн", .money)!
        check(DetectActions.copyText("number", m) == "1200.5" && DetectActions.copyText("copy", m) == "1 200,50 грн", "money copies")
        check(DetectActions.copyText("markdown", one("https://example.com/a", .link)!, context: DetectContext(title: "A page")) == "[A page](https://example.com/a)", "markdown with a title")
        check(DetectActions.copyText("iso", one("завтра", .date)!) == "2026-11-11", "ISO date")
        // issue links
        let gh = one("see #12", .issue) ?? one("PR #12", .issue)!
        check(DetectActions.refURL(gh, source: "https://github.com/acme/tool/issues/3")?.absoluteString == "https://github.com/acme/tool/issues/12", "#12 on a GitHub source")
        check(DetectActions.refURL(one("PROJ-42", .issue)!, source: "https://acme.atlassian.net/browse/PROJ-1")?.absoluteString == "https://acme.atlassian.net/browse/PROJ-42", "Jira")
        check(DetectActions.refURL(one("ENG-7", .issue)!, source: "https://linear.app/acme/issue/ENG-1")?.absoluteString == "https://linear.app/acme/issue/ENG-7", "Linear")
        check(DetectActions.refURL(one("PROJ-42", .issue)!, source: nil, text: "PROJ-42 at https://acme.atlassian.net/browse/X-1")?.host == "acme.atlassian.net", "host from a link in the same text")
        // event title and .ics
        let text = "Дзвінок з Оленою завтра о 15:00. Інше."
        let d = one(text, .date)!
        check(DetectActions.eventTitle(text: text, around: d.range) == "Дзвінок з Оленою", "title from the sentence: \(DetectActions.eventTitle(text: text, around: d.range))")
        let ics = DetectActions.ics(for: d, title: "Дзвінок з Оленою", notes: text, timeZone: tz, now: tue, uid: "u1")!
        check(ics.contains("DTSTART:20261111T130000Z") && ics.contains("DTEND:20261111T140000Z") && ics.contains("SUMMARY:Дзвінок з Оленою"), "timed event in UTC, one hour")
        check(ics.hasPrefix("BEGIN:VCALENDAR\r\n") && ics.hasSuffix("END:VCALENDAR\r\n"), "CRLF lines")
        check(ics.split(separator: "\r\n").allSatisfy { $0.utf8.count <= 75 }, "folded at 75 bytes")
        let day = DetectActions.ics(for: one("14-16 листопада", .dateRange)!, title: "Trip, two; days", notes: "a\nb", timeZone: tz, now: tue)!
        check(day.contains("DTSTART;VALUE=DATE:20261114") && day.contains("DTEND;VALUE=DATE:20261117"), "all-day range ends the day after")
        check(day.contains("SUMMARY:Trip\\, two\\; days") && day.contains("DESCRIPTION:a\\nb"), "escaped text")
    }

    static func speed() {
        let line = "Привіт, давай завтра о 15:00 на github.com, мій номер +380 67 123 45 67. Ще треба оплатити 1200 грн до 14.11, див. ~/Docs/a.pdf"
        _ = scan(line)
        let t0 = Date(); for _ in 0..<200 { _ = scan(line) }
        let per = Date().timeIntervalSince(t0) / 200 * 1000
        check(per < 20, "a 130-character item under 20 ms (about 0.7 ms on a quiet Mac): \(String(format: "%.2f", per)) ms")
        let big = String(repeating: line + "\n", count: 400)    // ~52k characters, scanned up to the cap
        let t1 = Date(); let n = Detect.scan(big, written: tue, hints: hints).count
        let ms = Date().timeIntervalSince(t1) * 1000
        check(ms < 1500 && n > 100, "a long transcript (cap \(Detect.cap)): \(String(format: "%.0f", ms)) ms, \(n) things")
        print(String(format: "speed: %.2f ms a line, %.0f ms for the first %d characters of a transcript", per, ms, Detect.cap))
    }
}

/// Live counts, read-only, numbers only: the files History reads, and call transcripts (capped).
enum Measure {
    static func rows(_ path: String) -> [(t: Double, text: String)] {
        guard let d = FileManager.default.contents(atPath: path), let s = String(data: d, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { l in
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let t = o["text"] as? String else { return nil }
            return ((o["t"] as? Double) ?? Date().timeIntervalSince1970, t)
        }
    }
    static func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a.sorted()[min(a.count - 1, Int(Double(a.count) * p))] }
    static func run() {
        let data = FileManager.default.currentDirectoryPath + "/data"
        var items: [(t: Double, text: String)] = []
        for f in ["takes", "clipboard", "typed", "drafts"] { let r = rows("\(data)/\(f).jsonl"); print("\(f): \(r.count) rows"); items += r }
        let calls = (try? FileManager.default.contentsOfDirectory(atPath: data + "/calls")) ?? []
        var transcripts = 0
        for c in calls { if let t = try? String(contentsOfFile: "\(data)/calls/\(c)/transcript.txt", encoding: .utf8) { items.append((Date().timeIntervalSince1970, t)); transcripts += 1 } }
        print("transcripts: \(transcripts)")
        var kindsHit: [DetectKind: Int] = [:]
        var per: [Double] = [], times: [Double] = []
        var ukItems = 0, ukSys = 0, ukAll = 0, sensitive = 0
        let cyr = try! NSRegularExpression(pattern: "[А-Яа-яІіЇїЄєҐґ]")
        let t0 = Date()
        for it in items {
            let a = Date()
            let f = Detect.scan(it.text, written: Date(timeIntervalSince1970: it.t))
            times.append(Date().timeIntervalSince(a) * 1000)
            per.append(Double(f.count))
            for k in Set(f.map(\.kind)) { kindsHit[k, default: 0] += 1 }
            sensitive += f.filter(\.sensitive).count
            let ns = it.text as NSString
            let head = NSRange(location: 0, length: Detect.span(ns, nil).length)
            if cyr.numberOfMatches(in: it.text, range: head) * 2 > max(1, it.text.filter(\.isLetter).count / 4) {
                ukItems += 1
                ukSys += Detect.detector.numberOfMatches(in: it.text, range: head)
                ukAll += f.count
            }
        }
        let total = Date().timeIntervalSince(t0) * 1000
        print("items: \(items.count)")
        for k in DetectKind.allCases { print("  items with \(k.rawValue): \(kindsHit[k] ?? 0)") }
        print("  items with a date or range: \((kindsHit[.date] ?? 0) + (kindsHit[.dateRange] ?? 0)) (may overlap)")
        print(String(format: "things per item: p50 %.0f, p90 %.0f, max %.0f; items with at least one: %d", pct(per, 0.5), pct(per, 0.9), per.max() ?? 0, per.filter { $0 > 0 }.count))
        print(String(format: "scan per item: p50 %.3f ms, p99 %.2f ms, max %.1f ms; whole store %.0f ms", pct(times, 0.5), pct(times, 0.99), times.max() ?? 0, total))
        print("Ukrainian items: \(ukItems); Apple's detector alone: \(ukSys) things; with the rules: \(ukAll) (+\(ukAll - ukSys))")
        print("one-time codes hidden: \(sensitive)")
    }
}
