import Foundation

// swiftc -parse-as-library app/ScreenContextRules.swift tests/screen_context_rules.swift -o app/build/screen-context-rules-test && app/build/screen-context-rules-test
// Screen context read as a conversation, on made-up boxes and made-up text only: blocks, who wrote what, interface
// noise, the tail under a budget, when to capture, which source per app.
@main
struct ScreenContextChecks {
    typealias R = ScreenContextRules
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }
    static func L(_ t: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double = 0.03) -> R.Line { R.Line(text: t, x: x, y: y, w: w, h: h) }

    static func main() {
        chat(); ai(); flat(); noise(); budget(); clock(); source(); geometry()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("screen context rules: all passed")
    }

    /// A chat: the other side on the left, the user's bubbles on the right, a sidebar outside the field's column.
    static func chat() {
        let lines = [
            L("Inbox", 0.01, 0.02, 0.12), L("Олена Мельник", 0.01, 0.08, 0.15), L("Pinned notes", 0.01, 0.14, 0.15),   // sidebar
            L("Привіт! Ти бачив новий draft", 0.32, 0.10, 0.40), L("of the zebra plan?", 0.32, 0.135, 0.25),
            L("10:42", 0.32, 0.17, 0.05),
            L("Так, глянув вчора ввечері", 0.62, 0.25, 0.35),
            L("Окей, тоді коли зідзвонимось?", 0.32, 0.40, 0.42), L("Може у четвер після обіду", 0.32, 0.435, 0.35),
            L("Reply", 0.32, 0.47, 0.06),
        ]
        let c = R.conversation(lines, kind: "chat", column: (0.30, 0.99), budget: 1600)
        let want = "Вони: Привіт! Ти бачив новий draft of the zebra plan?\nЯ: Так, глянув вчора ввечері\nВони: Окей, тоді коли зідзвонимось? Може у четвер після обіду"
        check(c.text == want, "chat: two sides, wrapped lines joined, sidebar, time and button dropped -> \(c.text.debugDescription)")
        check(c.blocks == 3 && c.marked == 3, "chat: three marked messages")
        // the same conversation with no column known: the sidebar is in, but it is not called the user's
        let bs = R.speakers(R.blocks(R.clean(lines)), kind: "chat")
        check(bs.contains { $0.text.hasPrefix("Так") && $0.who == .me }, "chat without a column: his right bubble is still his")
    }

    /// An AI app: the user's prompt as a narrow bubble on the right, the answer across the column.
    static func ai() {
        let lines = [
            L("Draft a short note to the landlord about the boiler", 0.45, 0.05, 0.50),
            L("Here is a short note you could send:", 0.05, 0.15, 0.60),
            L("Добрий день! Котел знову не вмикається з понеділка.", 0.05, 0.20, 0.85),
            L("Чи можна прислати майстра цього тижня?", 0.05, 0.235, 0.70),
            L("Copy", 0.05, 0.30, 0.05), L("Retry", 0.12, 0.30, 0.06),
            L("Claude can make mistakes. Please double-check responses.", 0.20, 0.95, 0.6),
        ]
        let c = R.conversation(lines, kind: "ai", column: (0.0, 1.0))
        check(c.text.hasPrefix("Я: Draft a short note"), "ai: his prompt marked as his -> \(c.text.debugDescription)")
        check(c.text.contains("\nАсистент: Here is a short note"), "ai: the answer marked as the assistant's")
        check(!c.text.contains("Copy") && !c.text.contains("mistakes"), "ai: buttons and the footer dropped")
    }

    /// Slack-like: everything on the left: nobody is named.
    static func flat() {
        let lines = [L("Maria  9:14 AM", 0.1, 0.1, 0.2), L("Can we move the sync to 3?", 0.1, 0.14, 0.4),
                     L("Ivan  9:20 AM", 0.1, 0.25, 0.2), L("Sure, works for me", 0.1, 0.29, 0.3)]
        let c = R.conversation(lines, kind: "chat")
        check(c.marked == 0 && !c.text.contains("Я:") && !c.text.contains("Вони:"), "flat layout: no marks -> \(c.text.debugDescription)")
        check(c.text.contains("Can we move the sync to 3?"), "flat layout: text kept")
        check(R.conversation(lines, kind: "other").marked == 0, "other apps: never marked")
    }

    static func noise() {
        for t in ["12:04", "9:41 PM", "Сьогодні", "Yesterday", "Reply", "Відповісти", "·", "5m", "14.11.2026", "ок", "Edited", "вчора о 21:15"] {
            check(R.isChrome(t), "interface text: \(t)")
        }
        for t in ["Ок, домовились на завтра", "See you at 3", "Тримай лінк на draft"] { check(!R.isChrome(t), "a message: \(t)") }
        // the field's own text, seen above the caret in the picture, is not read twice; a trailing time is cut
        let ls = [L("Привіт, як ти? 14:02", 0.1, 0.1, 0.5), L("я тут пишу довгий текст", 0.1, 0.5, 0.5), L("below the field", 0.1, 0.9, 0.5)]
        let kept = R.clean(ls, cut: 0.8, typing: "Я тут пишу довгий текст і ще трохи")
        check(kept.map { $0.text } == ["Привіт, як ти?"], "own field text, below-the-cut text and the time dropped -> \(kept.map { $0.text })")
    }

    static func budget() {
        func B(_ t: String, _ who: R.Who?) -> R.Block { R.Block(lines: [L(t, 0.1, 0, 0.5)], who: who) }
        let long = String(repeating: "довге питання ", count: 20)   // 280 characters
        let bs = [B("old one", .them), B("old reply", .me), B(long, .them), B("my answer", .me), B("short follow-up", .them)]
        let t = R.tail(bs, budget: 60)
        check(t.map { $0.text } == ["my answer", "short follow-up"], "tight budget: the last message of each side -> \(t.map { $0.text })")
        let t2 = R.tail(bs, budget: 10_000)
        check(t2.count == 5 && t2.first?.text == "old one", "big budget: all, oldest first")
        // the other side's last message longer than the budget: its end is kept
        let t3 = R.tail([B("hi", .me), B(long, .them)], budget: 50)
        check(t3.count == 1 && t3[0].text.count <= 50 && long.hasSuffix(t3[0].text), "an over-long last message: its end")
        let r = R.render(R.tail(bs, budget: 1600))
        check(r.count <= 1600 + 5 * 7, "rendered tail stays near the budget")
        check(R.tail([], budget: 100).isEmpty && R.tail(bs, budget: 0).isEmpty, "nothing in, nothing out")
    }

    static func waits(_ w: R.When, _ s: Double) -> Bool { if case .later(let x) = w { return abs(x - s) < 1e-6 }; return false }

    static func clock() {
        let now = 1_000.0
        check(R.when(.focus, now: now, lastCapture: now - 10, lastKey: now - 500) == .now, "focus reads even after a long pause")
        check(R.when(.scroll, now: now, lastCapture: now - 0.5, lastKey: now - 1) == .later(1.0), "at most one capture per 1.5 s")
        check(R.when(.poll, now: now, lastCapture: now - 5, lastKey: now - 1) == .no, "a pause inside 10 s of a capture: no look")
        check(R.when(.poll, now: now, lastCapture: now - 12, lastKey: now - 1) == .now, "a pause 10 s after a capture: a look")
        check(waits(R.when(.poll, now: now, lastCapture: now - 12, lastKey: now - 0.4), 0.6), "still typing: the look waits for the pause")
        check(R.when(.poll, now: now, lastCapture: now - 3, lastKey: now - 5) == .no, "looked since the last key: one look per pause")
        check(R.when(.poll, now: now, lastCapture: now - 100, lastKey: now - 61) == .no, "no captures a minute after the last key")
        check(R.when(.moved, now: now, lastCapture: now - 100, lastKey: now - 61) == .no, "a moved window while idle: no capture")
        // a ghost request with kept text: a look in the next pause, never a queued full read
        check(R.looks(.request) && R.looks(.poll) && !R.looks(.focus) && !R.looks(.scroll), "requests and polls look first")
        check(waits(R.when(.request, now: now, lastCapture: now - 20, lastKey: now - 0.2), 0.8), "a request while typing: a look once he pauses")
        check(R.when(.request, now: now, lastCapture: now - 20, lastKey: now - 1.5) == .now, "a request in a pause: a look")
        // a typing minute: keys every 0.2 s for 3 s, then 1.5 s of pause, over and over; requests every 0.5 s and the
        // pause check at each key + 1 s: at most 6 looks (one per pause, 10 s apart)
        var captures = 0, last = -100.0, key = -1.0
        for i in 0..<600 {
            let s = Double(i) * 0.1
            if s.truncatingRemainder(dividingBy: 4.5) < 3, abs((s * 5).rounded() - s * 5) < 1e-6 { key = s }
            if R.when(.request, now: s, lastCapture: last, lastKey: key) == .now { captures += 1; last = s }
        }
        check(captures <= 6 && captures >= 5, "a bursty typing minute: 5-6 looks, \(captures)")
        // without pauses (keys every 0.2 s all minute): no look until the user stops
        captures = 0; last = -100
        for i in 0..<300 { let s = Double(i) * 0.2; if R.when(.poll, now: s + 0.1, lastCapture: last, lastKey: s) == .now { captures += 1; last = s } }
        check(captures == 0, "typing without a pause: no looks, \(captures)")
        // looks compared with a tolerance: a new line reads again, a ticking timestamp does not
        let base = [UInt8](repeating: 240, count: 96 * 90)
        var line = base; for i in 0..<120 { line[40 * 96 + i % 96 + (i / 96) * 96] = 30 }
        var tick = base; for i in 0..<10 { tick[5 * 96 + i] = 30 }
        var faint = base; for i in base.indices { faint[i] = 236 }
        check(!R.lookChanged(base, base), "the same look: unchanged")
        check(R.lookChanged(base, line), "a new one-line message: changed")
        check(!R.lookChanged(base, tick), "a timestamp's few pixels: unchanged")
        check(!R.lookChanged(base, faint), "a slight shade everywhere (scaling): unchanged")
        check(R.lookChanged(base, Array(base.prefix(96 * 80))), "another size (window resized): changed")
    }

    static func source() {
        let clean = (1...8).map { "Повідомлення номер \($0) у цій розмові, досить довге" }.joined(separator: "\n")
        let page = (["Home", "Search", "Inbox", "Settings", "Profile", "Help", "Home", "Search"] + ["One real sentence with words here"]).joined(separator: "\n")
        check(R.axClean(clean), "clean Accessibility text")
        check(!R.axClean("short"), "under 120 characters is not enough")
        check(!R.axClean(page + "\n" + String(repeating: "x", count: 100)), "a page of labels is not clean")
        var m = R.AppMemory()
        check(R.source(ax: clean, memory: m, now: 0) == .ax, "clean -> Accessibility")
        check(R.source(ax: "", memory: m, now: 0) == .screen, "empty -> the picture")
        m.note(ok: false, now: 0); m.note(ok: false, now: 0)
        check(m.allowed(1), "two failures: still tried")
        m.note(ok: false, now: 0)
        check(!m.allowed(10) && R.source(ax: "", memory: m, now: 10) == .ax, "three failures in a row: this app rests 30 s")
        check(m.allowed(31), "then it is tried again")
        m.note(ok: true, now: 40)
        check(m.badInRow == 0 && m.allowed(40), "a success clears it")
    }

    static func geometry() {
        let r = R.region(window: (800, 1000), fieldTop: 900, caretTop: 950)!
        check(r.y == 0 && r.h == 900, "the field's top cuts, not the caret (his own lines are not read)")
        let r2 = R.region(window: (800, 2000), fieldTop: nil, caretTop: nil)!
        check(r2.y == 800 && r2.h == 900, "no caret and no field: 85% down the window, 900 pt above -> \(r2)")
        check(R.region(window: (800, 1000), fieldTop: 10, caretTop: nil)?.h == 850, "a field top under 20 pt is ignored")
        let (w, h) = R.pixels(w: 800, h: 900, scale: 1)
        check(w == 1600 && h == 1800, "a 1x display is read at 2x")
        let (w2, h2) = R.pixels(w: 1600, h: 1200, scale: 2)
        check(w2 * h2 <= 3_000_100 && w2 <= 2600, "big windows capped near 3 MP -> \(w2)x\(h2)")
    }
}
