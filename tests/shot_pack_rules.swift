import Foundation
import CoreGraphics

// swiftc -parse-as-library app/PenRules.swift app/ShotPackRules.swift tests/shot_pack_rules.swift -o app/build/shot-pack-test && app/build/shot-pack-test
// The shot pack: names, the agent text, the send-to order, JSON round trip. Made-up lines only.
@main
struct ShotPackTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func handOff(_ p0: ShotPack) {
        var p = p0; p.read = ""
        // the list keys
        check(ShotPack.listKey(code: 19, sel: 0, count: 8) == .pick(1) && ShotPack.listKey(code: 28, sel: 0, count: 8) == .pick(7), "digits 2 and 8")
        check(ShotPack.listKey(code: 28, sel: 0, count: 6) == .none, "a digit past the list")
        check(ShotPack.listKey(code: 125, sel: 7, count: 8) == .move(7) && ShotPack.listKey(code: 126, sel: 0, count: 8) == .move(0), "arrows stop at the ends")
        check(ShotPack.listKey(code: 36, sel: 3, count: 8) == .pick(3) && ShotPack.listKey(code: 53, sel: 3, count: 8) == .back, "↵ picks, esc back")
        check(ShotPack.listKey(code: 36, sel: 0, count: 0) == .none, "↵ on an empty list")
        // the field's kind
        let ai = ["com.anthropic.claudefordesktop", "com.openai.codex"]
        check(ShotPack.fieldWay(bundle: "com.openai.codex", ai: ai) == .agent, "Codex is an agent")
        check(ShotPack.fieldWay(bundle: "com.mitchellh.ghostty", ai: ai) == .terminal, "Ghostty is a terminal")
        check(ShotPack.fieldWay(bundle: "com.apple.Notes", ai: ai) == .other, "Notes is a field")
        check(ShotPack.mayPaste(bundle: "com.apple.Terminal", skip: ["com.apple.Terminal", "com.1password.1password"]), "a skipped terminal still takes ↵")
        check(!ShotPack.mayPaste(bundle: "com.1password.1password", skip: ["com.1password.1password"]), "a password app never")
        let agent = p.fieldPut(.agent, path: "/s/shot.png", md: "/s/shot.md")
        check(agent.picture && agent.text?.hasPrefix("Screenshot attached") == true, "agent: picture, then the text without the path")
        p.note = "line one\nline two\u{7}"
        let term = p.fieldPut(.terminal, path: "/s/shot.png", md: "/s/shot.md")
        check(!term.picture && term.text?.contains("\n") == false && term.text?.contains("\u{7}") == false, "terminal: one line, no control characters")
        check(term.text?.hasPrefix("Screenshot /s/shot.png (1280×720 px, Safari «Test page»)") == true && term.text?.contains("/s/shot.md") == true
              && term.text?.hasSuffix("Note: line one line two") == true, "terminal line: \(term.text ?? "")")
        p.note = "  "
        check(p.fieldPut(.other, path: "", md: "") == ShotPack.Put(picture: true, text: nil), "other, no note: the picture alone")
        p.note = "see the total"
        check(p.fieldPut(.other, path: "", md: "").text == "see the total", "other: the picture, then the note")
        // apps
        check(ShotPack.appBundle(.claude) == ShotPack.claudeApp && ShotPack.appBundle(.codex) == ShotPack.codexApp
              && ShotPack.appBundle(.file) == nil, "app bundles")
        let old = try? JSONDecoder().decode(ShotSent.self, from: Data(#"{"to": "gone", "t": 1, "detail": ""}"#.utf8))
        check(old?.to == .clipboard, "a removed target in an old shot.json still loads")
        check(ShotPack.claudeCodeApp(running: ["com.apple.Safari", "com.googlecode.iterm2", "com.apple.Terminal"]) == "com.googlecode.iterm2", "the front terminal")
        check(ShotPack.claudeCodeApp(running: ["com.apple.Safari"]) == ShotPack.claudeApp, "no terminal: the Claude app")
        // ask
        check(ShotPack.askInput("md").hasSuffix("\n\n" + ShotPack.askTail) && ShotPack.askArgs.contains("Read") && !ShotPack.askArgs.contains("Bash"), "ask: Read only")
        // person
        check(ShotPack.beeperSearch("Ola") == ["chats", "search", "Ola", "--json", "-q", "--read-only", "--limit", "6"], "search read only")
        check(ShotPack.beeperDraft(chat: "c1", file: "/s/shot.png", note: " hi ") == ["chats", "draft", "--chat", "c1", "--file", "/s/shot.png", "--text", "hi"], "draft with the note")
        check(!ShotPack.beeperDraft(chat: "c1", file: "/f", note: "").contains("--text") && !ShotPack.beeperDraft(chat: "c1", file: "/f", note: "").contains("send"), "draft only, no empty text")
        let j = #"{"data":[{"id":"g1","title":"Team","type":"group"},{"id":"s1","title":"Ola K.","type":"single"},{"title":"no id"}]}"#
        let c = ShotPack.chats(Data(j.utf8))
        check(c.map(\.id) == ["s1", "g1"], "direct chats first, rows without an id dropped")
        check(ShotPack.chats(Data("not json".utf8)).isEmpty, "bad output: none")
        // found things
        let f = ShotPack.foundValues([(kind: "link", value: "https://example.com", sensitive: false), (kind: "oneTimeCode", value: "123456", sensitive: true),
                                      (kind: "version", value: "1.2", sensitive: false), (kind: "link", value: "https://example.com", sensitive: false),
                                      (kind: "email", value: "a@example.com", sensitive: false)])
        check(f == ["https://example.com", "a@example.com"], "found: no sensitive, no version, each once: \(f)")
        // merge with disk
        var disk = p; disk.sent = [ShotSent(to: .clipboard, t: 1)]; disk.answer = "an answer"
        var now = p; now.note = "new note"; now.sent = []
        let m = now.merged(onDisk: disk)
        check(m.note == "new note" && m.sent.count == 1 && m.answer == "an answer", "a later write keeps sends and the answer")
        check(now.merged(onDisk: nil) == now, "nothing on disk")
    }


    /// A set: several pictures in one hand-off; an older shot.json (no `pictures`) still reads.
    static func sets() {
        var p = ShotPack(id: "20261115-104207-3fa1", t: 1_763_200_000, app: "Safari", window: "Invoice 0042", width: 800, height: 400)
        p.note = "compare the totals"
        check(p.count == 1 && p.pics[0].file == "shot.png" && p.pictures == nil, "one picture: no set")
        p.setPictures([ShotPicture(file: "x", width: 800, height: 400, marks: [ShotMark(kind: "pin", x: 10, y: 20, n: 1, text: "here")]),
                       ShotPicture(file: "y", width: 600, height: 300),
                       ShotPicture(file: "z", width: 500, height: 200, marks: [ShotMark(kind: "box", x: 1, y: 2, w: 30, h: 40)], original: "o")])
        check(p.count == 3 && p.pics.map(\.file) == ["shot.png", "shot-2.png", "shot-3.png"] && p.pics[2].original == "original-3.png", "files renumbered")
        check(p.marks.count == 1 && p.width == 800, "the first picture mirrored into the pack's fields")
        let t = p.agentText(path: "/d/shots/x/shot.png")
        check(t.hasPrefix("Screenshots: 3 pictures (Safari «Invoice 0042», "), "set head: \(t.prefix(60))")
        check(t.contains("Picture 1 of 3: /d/shots/x/shot.png (800×400 px)") && t.contains("Picture 3 of 3: /d/shots/x/shot-3.png (500×200 px)"), "each picture with its path")
        check(t.contains("1. pin at 10,20 - \"here\"") && t.contains("- box 1,2 to 31,42") && t.contains("Note: compare the totals"), "marks per picture, one note")
        let a = p.agentText(path: nil)
        check(a.hasPrefix("Screenshots attached: 3 pictures") && a.contains("Picture 2 of 3 (600×300 px)") && !a.contains("/d/"), "pasted: no paths")
        let line = p.terminalLine(path: "/d/shots/x/shot.png", md: "/d/shots/x/shot.md")
        check(line.hasPrefix("Screenshots /d/shots/x/shot.png /d/shots/x/shot-2.png /d/shots/x/shot-3.png (3 pictures") && !line.contains("\n"), "one terminal line, all paths")
        check(ShotPack.fileNames(p.t, count: 3, taken: []).count == 3 && Set(ShotPack.fileNames(p.t, count: 3, taken: [])).count == 3, "File: three free names")
        let first = ShotPack.fileName(p.t)
        check(ShotPack.fileNames(p.t, count: 2, taken: [first])[0] != first, "taken names skipped")
        let d = try! JSONEncoder().encode(p), back = try! JSONDecoder().decode(ShotPack.self, from: d)
        check(back == p && back.count == 3, "a set round trips")
        let old = #"{"v":1,"id":"a","t":1,"app":"","window":"","width":10,"height":20,"note":"","noteVia":"typed","marks":[],"read":"","found":[],"sent":[]}"#
        let o = try? JSONDecoder().decode(ShotPack.self, from: Data(old.utf8))
        check(o?.count == 1 && o?.pics.first?.width == 10, "an older shot.json still reads as one picture")
        var q = p; q.setPictures(Array(p.pics.prefix(1)))
        check(q.pictures == nil && q.count == 1, "back to one: no set")
    }

    static func main() {
        sets()
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 15; c.hour = 10; c.minute = 42; c.second = 7
        let t = Calendar.current.date(from: c)!.timeIntervalSince1970
        check(ShotPack.makeId(t, random: 0x3fa1) == "20261115-104207-3fa1", "id")
        check(ShotPack.fileName(t) == "Screenshot 2026-11-15 at 10.42.07.png", "macOS-like file name")
        let n = "Screenshot 2026-11-15 at 10.42.07.png"
        check(ShotPack.freeName(n, taken: []) == n, "free name as is")
        check(ShotPack.freeName(n, taken: [n, "Screenshot 2026-11-15 at 10.42.07 (2).png"]) == "Screenshot 2026-11-15 at 10.42.07 (3).png", "free name counts up")

        var p = ShotPack(id: "x", t: t, app: "Safari", window: "Test page", width: 1280, height: 720)
        p.note = "  the save button does nothing  "
        p.marks = [ShotMark(kind: "box", x: 100, y: 40, w: 280, h: 50),
                   ShotMark(kind: "pin", x: 500, y: 300, n: 2),
                   ShotMark(kind: "pin", x: 420, y: 188, n: 1, text: "this button"),
                   ShotMark(kind: "arrow", x: 500, y: 300, toX: 420, toY: 190),
                   ShotMark(kind: "blur", x: 40, y: 600, w: 360, h: 40)]
        p.read = String(repeating: "a", count: 2000)
        let a = p.agentText(path: "/tmp/shot.png")
        let lines = a.components(separatedBy: "\n")
        check(lines[0] == "Screenshot: /tmp/shot.png (1280×720 px, Safari «Test page», 15 November 2026 10:42)", "head line: " + lines[0])
        check(lines[1] == "Note: the save button does nothing", "note trimmed")
        check(lines[3] == "1. pin at 420,188 - \"this button\"" && lines[4] == "2. pin at 500,300", "pins first, by number")
        check(lines[5] == "- box 100,40 to 380,90", "box")
        check(lines[6] == "- arrow 500,300 → 420,190", "arrow")
        check(lines[7] == "- blurred 40,600 to 400,640 (hidden on purpose)", "blur")
        check(lines.last!.count == 1500, "read text cut to 1,500")
        check(p.agentText(path: nil).hasPrefix("Screenshot attached (1280×720 px"), "attached head")

        let bare = ShotPack(id: "y", t: t, width: 10, height: 10)
        check(bare.agentText(path: nil).components(separatedBy: "\n").count == 1, "no note, marks or text: one line")

        check(ShotPack.order(last: nil).first == .clipboard && !ShotPack.order(last: nil).contains(.field), "default order, no field")
        let o = ShotPack.order(last: .claudeCode)
        check(o.first == .claudeCode && o.count == ShotTarget.allCases.count - 1 && Set(o).count == o.count, "last used first, once")
        check(ShotTarget.ask.cloud && !ShotTarget.claude.cloud, "cloud mark")

        p.sent = [ShotSent(to: .file, t: t, detail: n)]
        let d = try! JSONEncoder().encode(p)
        check((try? JSONDecoder().decode(ShotPack.self, from: d)) == p, "JSON round trip")

        check(ShotPack.place(app: "Claude", window: "Claude") == "Claude" && ShotPack.place(app: "Safari", window: "Page") == "Safari «Page»", "window like its app: once")
        check(a.contains("first 1,500 characters"), "the count without the locale's space")
        check(!p.agentText(path: nil).contains("Screen text") && !p.agentText(path: "/s", screenText: false).contains("Screen text"), "no screen text beside the picture")
        handOff(p)
        print(failures == 0 ? "shot pack rules: all passed" : "shot pack rules: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
