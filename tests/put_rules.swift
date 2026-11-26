// swiftc -parse-as-library app/PutRules.swift tests/put_rules.swift -o app/build/put-rules-test && app/build/put-rules-test
import Foundation

@main
struct PutRulesTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL line \(line): \(what)") } }

    static func main() {
        let me: Int32 = 1, beeper: Int32 = 20, notes: Int32 = 30
        // who holds the keys, seen from the remembered target
        check(PutRules.front(keyPid: notes, targetPid: notes, ownPid: me) == .target, "the target holds the keys")
        check(PutRules.front(keyPid: me, targetPid: notes, ownPid: me) == .drafter, "Drafter holds the keys")
        check(PutRules.front(keyPid: beeper, targetPid: notes, ownPid: me) == .other, "he moved to another app")
        check(PutRules.front(keyPid: nil, targetPid: notes, ownPid: me) == .none, "nobody")

        // case 1: the front app moved to another app (the Beeper bug): never raise, the clipboard
        check(PutRules.way(front: .other, targetAlive: true) == .clipboard, "another app in front: clipboard")
        check(!PutRules.mayRaise(front: .other, targetAlive: true), "another app in front: no raise on close")
        check(PutRules.way(why: "front app moved", targetAlive: true) == .clipboard, "deck: front app moved: clipboard")
        check(PutRules.movedPill(front: "Beeper Desktop", target: "Notes") == "Beeper Desktop is in front, not Notes · on the clipboard, ⌘V to paste", "pill names both apps")
        check(PutRules.movedPill(front: "Beeper Desktop", target: "Notes", what: "Text on the clipboard").contains("text on the clipboard"), "pill keeps what went there")
        check(PutRules.movedPill(front: nil, target: "Notes") == "On the clipboard · ⌘V to paste", "pill without both names")

        // case 2: the front app moved to Drafter itself: bring the target back once
        check(PutRules.way(front: .drafter, targetAlive: true) == .bringBack, "Drafter in front: bring back")
        check(PutRules.mayRaise(front: .drafter, targetAlive: true), "Drafter in front: raise on close")
        check(PutRules.way(why: "front app moved (Drafter)", targetAlive: true) == .bringBack, "deck: Drafter in front: bring back")
        check(PutRules.way(front: .drafter, targetAlive: false) == .clipboard, "the target quit: clipboard")
        check(PutRules.way(front: .target, targetAlive: true) == .go, "target in front: go")
        check(PutRules.way(why: nil, targetAlive: true) == .go, "deck: field ready: go")
        check(PutRules.way(why: "no field (none)", targetAlive: true) == .clipboard, "deck: no field: clipboard")
        check(PutRules.way(front: .none, targetAlive: true) == .clipboard, "nobody holds the keys: clipboard")

        // a switch to another app during the deck: the user's (a click or key just before) or the system's (nothing before)
        check(PutRules.moved(switchAt: 100, lastInputAt: 99.7) == .user, "a click 0.3 s before: his switch")
        check(PutRules.moved(switchAt: 100, lastInputAt: 100.02) == .user, "input in the same instant: his")
        check(PutRules.moved(switchAt: 100, lastInputAt: 98) == .system, "input 2 s before: a system handoff")
        check(PutRules.moved(switchAt: 100, lastInputAt: nil) == .system, "no input at all: a system handoff")
        check(PutRules.moved(switchAt: 100, lastInputAt: 101) == .system, "input only after the switch: a system handoff")
        check(PutRules.moved(switchAt: nil, lastInputAt: 99) == .unknown, "no switch seen: unknown")
        check(PutRules.way(front: .other, targetAlive: true, moved: .system) == .bringBack, "system handoff: bring back")
        check(PutRules.way(front: .other, targetAlive: true, moved: .user) == .clipboard, "his click: clipboard")
        check(PutRules.way(front: .other, targetAlive: true, moved: .unknown) == .clipboard, "unknown: clipboard")
        check(PutRules.way(front: .other, targetAlive: false, moved: .system) == .clipboard, "system handoff, target quit: clipboard")
        check(PutRules.way(front: .drafter, targetAlive: true, moved: .user) == .bringBack, "switch to Drafter: bring back")
        check(PutRules.way(why: "front app moved", targetAlive: true, moved: .system) == .bringBack, "deck: system handoff: bring back")
        check(PutRules.way(why: "front app moved", targetAlive: true, moved: .user) == .clipboard, "deck: his click: clipboard")
        check(PutRules.way(why: "no field (none)", targetAlive: true, moved: .system) == .clipboard, "no field stays clipboard")
        check(!PutRules.mayRaise(front: .other, targetAlive: true), "a closing panel never raises over another app")

        // case 3: a window closed after the paste: unsure, the clipboard
        check(PutRules.landed(target: beeper, keyApp: beeper, windowsBefore: 2, windowsAfter: 1, field: true) == "a window closed during the paste", "window closed")
        check(PutRules.landed(target: beeper, keyApp: beeper, windowsBefore: 2, windowsAfter: 2, field: true) == nil, "landed")
        check(PutRules.landed(target: beeper, keyApp: beeper, windowsBefore: 1, windowsAfter: 2, field: true) == nil, "a new window is fine")
        check(PutRules.landed(target: beeper, keyApp: notes, windowsBefore: 1, windowsAfter: 1, field: true) != nil, "front app changed")
        check(PutRules.landed(target: beeper, keyApp: nil, windowsBefore: 1, windowsAfter: 1, field: true) != nil, "nobody holds the keys")
        check(PutRules.landed(target: beeper, keyApp: beeper, windowsBefore: 1, windowsAfter: 1, field: false) == "the field is gone", "field gone")

        // where a put-in goes: the app the user moved to themselves, else the app the shot was taken in
        check(PutRules.goesHere(front: .other, moved: .user), "he clicked into another app, then ↵: put in there")
        check(!PutRules.goesHere(front: .other, moved: .system), "a system handoff: back to the shot's app")
        check(!PutRules.goesHere(front: .other, moved: .unknown), "no switch seen: not there")
        check(!PutRules.goesHere(front: .drafter, moved: .user), "Drafter in front: back to the shot's app")
        check(!PutRules.goesHere(front: .target, moved: .user), "still in the shot's app: there anyway")

        // accessibility asks: none while a capture is up; Electron gets the manual flag first
        check(!PutRules.mayAskAccessibility(captureUp: true), "capture up: no accessibility ask")
        check(PutRules.mayAskAccessibility(captureUp: false), "no capture: ask as before")
        check(PutRules.enhancedAtOnce(browser: true) && !PutRules.enhancedAtOnce(browser: false), "browsers at once, Electron manual first")
        print(failed == 0 ? "put rules: all passed" : "put rules: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
