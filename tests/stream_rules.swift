// swiftc -parse-as-library app/StreamRules.swift app/StreamZoomRules.swift tests/stream_rules.swift -o app/build/stream-rules-test && app/build/stream-rules-test
// The stream's pure rules (app/StreamRules.swift): scope words over the search, the keys, the player's time math, what an
// edit's save and undo store. Made-up lines only.
import Foundation

@main struct StreamRulesTest {
    static var bad = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { bad += 1; print("FAIL " + what) } }

    static func main() {
        scopes(); keys(); player(); editing()
        print(bad == 0 ? "stream rules: pass" : "stream rules: \(bad) failed"); exit(bad == 0 ? 0 : 1)
    }

    static func scopes() {
        let q = StreamRules.parse("@mila links station in:slack today")
        check(q.who == ["mila"] && q.kind == "link" && q.app == "slack" && q.day == "today" && q.words == ["station"], "parse all scopes")
        check(StreamRules.parse("\"links\"").kind == nil && StreamRules.parse("\"links\"").words == ["links"], "quoted word is a word")
        check(StreamRules.parse("").isEmpty, "empty")
        // the search gets the words, quotes and its own filters; never the scope words
        check(StreamRules.coreText("@mila links station in:slack today") == "station", "core text drops scopes")
        check(StreamRules.coreText("calls \"links\" kind:voice") == "\"links\" kind:voice", "core keeps quotes and core filters")
        check(StreamRules.coreText("links links") == "links", "a second kind word is searched")
        check(StreamRules.coreText("lantern in:today") == "lantern in:today", "in: with a time is the search's")
        check(StreamRules.coreText("lantern in:monday") == "lantern in:monday", "in: a weekday is time")
        check(StreamRules.parse("in:monzo").app == "monzo", "in: an app that starts like a weekday")
        check(StreamRules.parse("in:\"last week\"").app == nil, "in: a quoted time")
        let now = Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970
        let f = StreamRules.Facts(kindId: "link", pinned: false, app: "Slack", tags: ["Mila Synthetic"], at: now - 60, hay: "station map")
        check(StreamRules.matches(f, StreamRules.parse("@mil links station in:sla"), now: now), "match")
        check(!StreamRules.matches(f, StreamRules.parse("@ana"), now: now), "other person")
        check(!StreamRules.matches(f, StreamRules.parse("calls"), now: now), "other kind")
        check(StreamRules.matches(f, StreamRules.parse("clips"), now: now), "clips holds links")
        // screens: a capture kept as a shot is a screen whatever its row kind; it is not a plain clip
        let shot = StreamRules.Facts(kindId: "copied", pinned: false, app: "Safari", tags: [], at: now, hay: "", shot: true)
        check(StreamRules.inScope(shot, StreamRules.parse("screens"), now: now), "a shot is a screen")
        check(!StreamRules.inScope(shot, StreamRules.parse("clips"), now: now), "a shot is not a clip")
        let pic = StreamRules.Facts(kindId: "picture", pinned: false, app: "Preview", tags: [], at: now, hay: "")
        check(StreamRules.inScope(pic, StreamRules.parse("screens"), now: now), "a picture clip is a screen")
        // today / yesterday by the calendar day
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!.timeIntervalSince1970
        var y = f; y.at = noon - 86400
        check(StreamRules.inScope(y, StreamRules.parse("yesterday"), now: noon, cal: cal) && !StreamRules.inScope(y, StreamRules.parse("today"), now: noon, cal: cal), "yesterday")
        check(StreamRules.setting(kindToken: "calls", in: "links station") == "calls station", "scope swap")
        check(StreamRules.setting(kindToken: "", in: "links station") == "station", "scope cleared")
        check(StreamRules.scopeToken(digit: 1) == "" && StreamRules.scopeToken(digit: 5) == "calls" && StreamRules.scopeToken(digit: 10) == nil, "⌘digit scopes")
    }

    static func keys() {
        typealias K = StreamKeys
        var s = K.State(); s.rows = 5
        // the field: ↓ lands on the best row, ↵ opens it
        var (t, e) = K.route(s, .down); check(t.region == .list && e == .move(0), "↓ from the field")
        (t, e) = K.route(s, .ret); check(t.region == .list && e == .open, "↵ in the field opens the best")
        (t, e) = K.route(s, .letter); check(e == .pass, "letters type in the field")
        // the list
        s.region = .list
        (t, e) = K.route(s, .up); check(t.region == .search && e == .none, "↑ on the first row: the field")
        s.row = 2; (t, e) = K.route(s, .down); check(e == .move(1), "↓ moves")
        (t, e) = K.route(s, .letter); check(t.region == .search && e == .typeInSearch, "a letter searches")
        (t, e) = K.route(s, .e); check(e == .typeInSearch, "E on a closed row searches")
        // an open text row: ↵ and E edit, space opens nothing, esc closes
        s.open = .text
        (t, e) = K.route(s, .ret); check(t.region == .editor && e == .edit, "↵ edits an open text row")
        (t, e) = K.route(s, .e); check(t.region == .editor && e == .edit, "E edits")
        (t, e) = K.route(s, .esc); check(e == .close, "esc closes")
        (t, e) = K.route(s, .space); check(e == .close, "space without audio closes")
        // an open recording: ↵ opens its page, space plays
        s.open = .recording; s.audio = true
        (t, e) = K.route(s, .ret); check(e == .openPage, "↵ on a recording opens the page")
        (t, e) = K.route(s, .space); check(e == .playPause, "space plays")
        (t, e) = K.route(s, .e); check(e == .edit && t.region == .editor, "E edits a recording")
        // the editor: ⌘↵ saves, esc cancels, the rest is the editor's
        var ed = s; ed.region = .editor
        (t, e) = K.route(ed, .insert); check(e == .save && t.region == .list, "⌘↵ saves")
        (t, e) = K.route(ed, .esc); check(e == .cancel && t.region == .list, "esc cancels")
        (t, e) = K.route(ed, .ret); check(e == .pass, "↵ is a new line")
        (t, e) = K.route(ed, .space); check(e == .pass, "space is a space")
        // several rows
        var p = s; p.open = .none; p.audio = false
        (t, e) = K.route(p, .shiftDown); check(e == .extend(1), "⇧↓ picks")
        p.picked = 3
        (t, e) = K.route(p, .combine); check(e == .combine && t.region == .editor, "⌘⇧E combines")
        (t, e) = K.route(p, .esc); check(e == .single, "esc: back to one")
        p.picked = 1; (t, e) = K.route(p, .combine); check(e == .none, "one row: nothing to combine")
        (t, e) = K.route(p, .esc); check(e == .closeWindow, "esc with nothing open")
        // Go to, history, scopes
        (t, e) = K.route(p, .goTo); check(t.region == .palette && e == .openPalette, "⌘T")
        var pal = t; (t, e) = K.route(pal, .down); check(e == .paletteMove(1), "palette ↓")
        (t, e) = K.route(pal, .ret); check(e == .palettePick && t.region == .list, "palette ↵")
        pal.region = .palette; (t, e) = K.route(pal, .esc); check(e == .closePalette, "palette esc")
        (t, e) = K.route(p, .back); check(e == .historyBack, "⌘[")
        (t, e) = K.route(p, .forward); check(e == .historyForward, "⌘]")
        (t, e) = K.route(p, .digit(3)); check(e == .scope(3), "⌘3")
        (t, e) = K.route(p, .cmdDown); check(e == .jumpDay(1), "⌘↓ next day")
        // the field's esc: clear, then the stream
        var f = K.State(); f.rows = 2; f.query = true
        (t, e) = K.route(f, .esc); check(e == .clearSearch, "esc clears")
        f.query = false; (t, e) = K.route(f, .esc); check(t.region == .list, "esc again: the stream")
        f.command = true; (t, e) = K.route(f, .ret); check(e == .plan, "↵ asks in command mode")
        check(!K.hints(s).isEmpty && K.hints(ed).contains("⌘↵ save"), "hints")
    }

    static func player() {
        check(PlayerRules.clock(65) == "1:05" && PlayerRules.clock(3723) == "1:02:03" && PlayerRules.clock(-2) == "0:00", "clock")
        check(PlayerRules.skip(5, by: -10, total: 60) == 0 && PlayerRules.skip(55, by: 10, total: 60) == 60 && PlayerRules.skip(20, by: 10, total: 60) == 30, "skip ±10 s stays inside")
        check(PlayerRules.nextSpeed(1) == 1.5 && PlayerRules.nextSpeed(1.5) == 2 && PlayerRules.nextSpeed(2) == 1 && PlayerRules.nextSpeed(1.25) == 1, "speeds")
        check(PlayerRules.speedLabel(1) == "1×" && PlayerRules.speedLabel(1.5) == "1.5×", "speed label")
        check(PlayerRules.line(at: 12, starts: [0, 10, 20]) == 1 && PlayerRules.line(at: 1, starts: [5, 10]) == nil && PlayerRules.line(at: 30, starts: [0, nil, 20]) == 2, "line playing")
        let ss = PlayerRules.sentences("Call the studio. Then the drawings!\nLast line")
        check(ss == ["Call the studio.", "Then the drawings!", "Last line"], "sentences: \(ss)")
        let g = PlayerRules.guessedStarts(["ab", "abcd", "ab"], total: 8)
        check(g == [0, 2, 6], "guessed starts by length: \(g)")
    }

    static func editing() {
        typealias S = StreamRules.Store
        check(StreamRules.save(original: "a", before: nil, draft: "a") == S.keep, "no change")
        check(StreamRules.save(original: "a", before: nil, draft: "b") == S.change("b"), "a change")
        check(StreamRules.save(original: "a", before: "b", draft: "a") == S.original, "back to the original")
        check(StreamRules.save(original: "a", before: "b", draft: "b") == S.keep, "same change")
        check(StreamRules.undo(original: "a", before: nil) == S.original, "undo a first change")
        check(StreamRules.undo(original: "a", before: "b") == S.change("b"), "undo to the earlier change")
        check(StreamRules.points("• one\n\n- two\n  three  ") == ["one", "two", "three"], "points from the editor")
        check(StreamRules.canCombine(3, texts: 2) && !StreamRules.canCombine(3, texts: 1) && !StreamRules.canCombine(1, texts: 1), "combine needs two texts")
    }
}
