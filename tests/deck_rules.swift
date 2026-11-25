import Foundation
import CoreGraphics

// swiftc -parse-as-library app/PenRules.swift app/QuickRules.swift app/PictureLookRules.swift app/ClipRules.swift app/ShotRules.swift app/MarkupRules.swift app/ShotPackRules.swift app/DeckRules.swift tests/deck_rules.swift -o app/build/deck-rules-test && app/build/deck-rules-test
// The capture deck: card order, captions, keys, place, the pack text with captions. Made-up lines only.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

@main struct DeckRulesTest {
    static func main() {
        // order
        check(DeckRules.move(["a", "b", "c", "d"], from: 0, to: 2) == ["b", "c", "a", "d"], "move forward")
        check(DeckRules.move(["a", "b", "c", "d"], from: 3, to: 0) == ["d", "a", "b", "c"], "move to the front")
        check(DeckRules.move(["a", "b"], from: 5, to: 0) == ["a", "b"], "out of range unchanged")
        check(DeckRules.move(["a", "b", "c"], from: 1, to: 9) == ["a", "c", "b"], "past the end goes last")
        check(DeckRules.slot(x: 5, centres: [50, 150, 250]) == 0, "slot before the first")
        check(DeckRules.slot(x: 160, centres: [50, 150, 250]) == 2, "slot after the second centre")
        check(DeckRules.slot(x: 999, centres: [50, 150, 250]) == 2, "slot past the end is the last")
        check(DeckRules.picked(after: 0, to: 2, picked: 0, count: 4) == 2, "picked follows its card")
        check(DeckRules.picked(after: 0, to: 2, picked: 1, count: 4) == 0, "a card moved past the picked one shifts it left")
        check(DeckRules.picked(after: 3, to: 0, picked: 1, count: 4) == 2, "a card moved in front shifts it right")
        check(DeckRules.picked(afterRemoving: 1, picked: 2, count: 3) == 1, "removing before the picked one")
        check(DeckRules.picked(afterRemoving: 2, picked: 2, count: 3) == 1, "removing the last picked one")
        check(DeckRules.picked(afterRemoving: 0, picked: 0, count: 3) == 0, "removing the first picked one")

        // captions
        check(DeckRules.add("the total is wrong", to: "") == "the total is wrong", "first words")
        check(DeckRules.add(" and the date ", to: "the total") == "the total and the date", "words added with a space")
        check(DeckRules.add(".", to: "kept") == "kept", "a lone dot is not words")
        check(DeckRules.add("", to: "kept") == "kept", "nothing heard")
        // the live caption: the last words under the card
        let tail = DeckRules.labelTail("the order form opens on the second step only", width: 14)
        check(tail.map(\.line) == ["…second step", "only"] || tail.map(\.line) == ["…on the second", "step only"],
              "two last lines, the first starting with an ellipsis: \(tail.map(\.line))")
        check(tail.allSatisfy { $0.line.count <= 14 }, "tail lines inside the width")
        check(DeckRules.labelTail("short one", width: 20).map(\.line) == ["short one"], "fits: no ellipsis")
        check(DeckRules.labelTail("short one", width: 20).first?.firstWord == 0, "first word index")
        let t2 = DeckRules.labelTail("mine said and spoken words", width: 11)
        check(t2.last?.line == "words" || t2.last?.line.hasSuffix("words") == true, "the newest word shows: \(t2.map(\.line))")
        check(t2.allSatisfy { $0.firstWord >= 0 && $0.firstWord < 5 }, "word indexes in range")
        check(DeckRules.labelTail("", width: 20).isEmpty, "nothing heard: no lines")
        check(DeckRules.stripWords("hello", deckTake: true) == "" && DeckRules.stripWords("hello", deckTake: false) == "hello",
              "a caption take shows no words in the strip")
        check(DeckRules.label("", width: 20) == [], "no caption, no lines")
        check(DeckRules.label("the order form", width: 20) == ["the order form"], "fits on one line")
        check(DeckRules.label("the order form opens on the second step only", width: 14) == ["the order form", "opens on the…"],
              "two lines, cut with an ellipsis: \(DeckRules.label("the order form opens on the second step only", width: 14))")
        let long = DeckRules.label("supercalifragilistic word", width: 8)
        check(long.allSatisfy { $0.count <= 8 }, "a long word is cut inside the width: \(long)")
        check(DeckRules.target(picked: nil, count: 3) == 2, "typing goes to the last card")
        check(DeckRules.target(picked: 0, count: 3) == 0, "typing goes to the picked card")
        check(DeckRules.target(picked: 7, count: 3) == 2, "a stale pick falls back to the last")
        check(DeckRules.target(picked: nil, count: 0) == nil, "no cards")

        // keys
        check(DeckRules.key(code: 36, cmd: false, shift: false, picked: 0, count: 2) == .putIn, "↵ puts the deck in")
        check(DeckRules.key(code: 36, cmd: true, shift: false, picked: 0, count: 2) == .putIn, "⌘↵ is ↵ (one key for put in)")
        check(DeckRules.key(code: 53, cmd: false, shift: false, picked: 0, count: 2) == .escape, "esc is escape: stops the take, else passive")
        check(DeckRules.key(code: 45, cmd: true, shift: false, picked: 0, count: 2) == .add, "⌘N adds")
        check(DeckRules.key(code: 14, cmd: true, shift: false, picked: 0, count: 2) == .markup, "⌘E marks up")
        check(DeckRules.key(code: 15, cmd: true, shift: false, picked: 0, count: 2) == .retake, "⌘R retakes")
        check(DeckRules.key(code: 48, cmd: false, shift: false, picked: 0, count: 2) == .sendList, "⇥ send to")
        check(DeckRules.key(code: 51, cmd: true, shift: false, picked: 1, count: 2) == .delete, "⌘⌫ deletes the picked card")
        check(DeckRules.key(code: 51, cmd: true, shift: false, picked: 0, count: 1) == .none, "⌘⌫ on the last card does nothing (no typing)")
        check(DeckRules.key(code: 51, cmd: false, shift: false, picked: 0, count: 2) == .backspace, "⌫ edits the caption")
        check(DeckRules.key(code: 123, cmd: true, shift: false, picked: 1, count: 3) == .pick(0), "⌘← picks the card before")
        check(DeckRules.key(code: 124, cmd: true, shift: false, picked: 2, count: 3) == .pick(2), "⌘→ stops at the last")
        check(DeckRules.key(code: 124, cmd: true, shift: true, picked: 0, count: 3) == .move(1), "⌘⇧→ moves the card right")
        check(DeckRules.key(code: 123, cmd: true, shift: true, picked: 0, count: 3) == .none, "⌘⇧← at the front does nothing")
        check(DeckRules.key(code: 9, cmd: true, shift: false, picked: 0, count: 2) == .pass, "⌘V is not the deck's: it passes")
        check(DeckRules.key(code: 35, cmd: true, shift: false, picked: 0, count: 1) == .pin && DeckRules.takes(code: 35, cmd: true), "⌘P pins the picked card")
        let pinScreen = CGSize(width: 1440, height: 900)
        check(DeckRules.pinSize(pixels: CGSize(width: 800, height: 400), scale: 2, screen: pinScreen) == CGSize(width: 400, height: 200), "a pin at its own size")
        check(DeckRules.pinSize(pixels: CGSize(width: 2000, height: 20000), scale: 2, screen: pinScreen) == CGSize(width: 77, height: 765), "a tall scroll picture: 85% of the screen high")
        check(DeckRules.pinSize(pixels: CGSize(width: 40, height: 20), scale: 2, screen: pinScreen) == CGSize(width: 80, height: 40), "at least 80 pt long")
        let z = DeckRules.pinZoom(CGSize(width: 400, height: 200), dy: 5, screen: pinScreen)
        check(z == CGSize(width: 440, height: 220), "scroll up grows, shape kept: \(z)")
        check(DeckRules.pinZoom(CGSize(width: 1400, height: 700), dy: 50, screen: pinScreen) == CGSize(width: 1440, height: 720), "never past the screen")
        check(DeckRules.pinZoom(CGSize(width: 90, height: 45), dy: -50, screen: pinScreen) == CGSize(width: 80, height: 40), "never under 80 pt")
        check(DeckRules.key(code: 53, cmd: false, shift: false, picked: 0, count: 1) == .escape, "esc on one card never keeps or sends")
        check(DeckRules.takes(code: 0, cmd: false), "plain keys stay with the deck (caption)")
        check(DeckRules.takes(code: 45, cmd: true) && DeckRules.takes(code: 14, cmd: true) && DeckRules.takes(code: 51, cmd: true), "⌘N ⌘E ⌘⌫ are the deck's")
        check(!DeckRules.takes(code: 9, cmd: true) && !DeckRules.takes(code: 23, cmd: true) && !DeckRules.takes(code: 12, cmd: true),
              "⌘V, ⌘⇧5 (capture key) and ⌘Q pass to the app")
        for code in 0..<128 where DeckRules.takes(code: code, cmd: true) {
            check(DeckRules.key(code: code, cmd: true, shift: false, picked: 0, count: 2) != .pass, "a taken ⌘ key \(code) does something or nothing, never passes")
        }
        check(DeckRules.key(code: 0, cmd: false, shift: false, picked: 0, count: 1) == .typing, "a letter is typing")

        // round 3: passive until he clicks the deck (made-up key codes only)
        for code in 0..<128 {
            check(!DeckRules.takes(code: code, cmd: false, hold: .passive) && !DeckRules.takes(code: code, cmd: true, hold: .passive),
                  "passive: key \(code) goes to his app, plain or ⌘")
            check(DeckRules.takes(code: code, cmd: false, hold: .active) == DeckRules.takes(code: code, cmd: false)
                  && DeckRules.takes(code: code, cmd: true, hold: .active) == DeckRules.takes(code: code, cmd: true), "active: the deck's keys as before, key \(code)")
        }
        check(!DeckRules.takes(code: 36, cmd: false, hold: .passive) && !DeckRules.takes(code: 53, cmd: false, hold: .passive), "passive: ↵ and esc are his app's")
        check(DeckRules.takes(code: 36, cmd: false, hold: .active) && DeckRules.takes(code: 53, cmd: false, hold: .active), "active: ↵ puts in, esc is the deck's")
        check(DeckRules.takes(code: 0, cmd: false, hold: .active) && !DeckRules.takes(code: 9, cmd: true, hold: .active), "active: a letter edits the caption, ⌘V still passes")
        check(DeckRules.hold(afterClickInside: true) == .active && DeckRules.hold(afterClickInside: false) == .passive, "a click inside makes it active, outside passive")
        check(DeckRules.esc(listening: true) == .stopTalk && DeckRules.esc(listening: false) == .passive, "esc stops a caption take first, else passive")
        check(DeckRules.esc(listening: true, spread: true) == .stopTalk && DeckRules.esc(listening: false, spread: true) == .gather,
              "round 4: esc on a spread deck gathers it (a take still stops first)")
        check(!DeckRules.takesVoice(open: true, hold: .passive, collecting: false), "passive: Right Option voice goes to his app")
        check(DeckRules.takesVoice(open: true, hold: .active, collecting: false), "active: a take is the card's caption")
        check(DeckRules.takesVoice(open: true, hold: .passive, collecting: true), "dimmed for the next shot: the take is the deck's")
        check(!DeckRules.takesVoice(open: false, hold: .active, collecting: true), "closed: never the deck's")
        check(!DeckRules.autoTalk(setting: true, hold: .passive) && DeckRules.autoTalk(setting: true, hold: .active)
              && !DeckRules.autoTalk(setting: false, hold: .active), "the caption mic starts by itself only when active and on")
        // round 4 "Hand", 4b: at the caret, a click selects, the row acts (made-up screens and rects)
        let scr4 = CGRect(x: 0, y: 0, width: 1440, height: 900), side4 = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        check(DeckRules.appKit(ax: CGRect(x: 100, y: 50, width: 2, height: 18), mainHeight: 900) == CGRect(x: 100, y: 832, width: 2, height: 18), "AX to AppKit flips y")
        check(DeckRules.anchor(caret: CGRect(x: 100, y: 200, width: 2, height: 20), field: CGRect(x: 0, y: 0, width: 500, height: 400)) == CGPoint(x: 101, y: 210), "the caret wins")
        check(DeckRules.anchor(caret: nil, field: nil) == nil, "neither: no anchor")
        let hs = CGSize(width: 400, height: 300), caret4 = CGRect(x: 600, y: 300, width: 2, height: 18)
        let atC = DeckRules.placeHand(hs, fanLeft: 56, caret: caret4, field: nil, screens: [scr4, side4], screen: scr4)
        check(atC == CGRect(x: 544, y: 324, width: 400, height: 300), "just above the caret line, the fan's left at the caret: \(atC)")
        let high = DeckRules.placeHand(hs, fanLeft: 56, caret: CGRect(x: 600, y: 760, width: 2, height: 18), field: nil, screens: [scr4], screen: scr4)
        check(high.minX >= 602 + 12 - 0.5 && high.minY <= 760 && high.maxY >= 778, "caret in the top 300 pt: right of the caret line, level with it \(high)")
        check(!(high.minX < 602 && high.maxY > 760), "never over the lines under a high caret")
        let edge4 = DeckRules.placeHand(hs, fanLeft: 56, caret: CGRect(x: 1430, y: 10, width: 2, height: 18), field: nil, screens: [scr4], screen: scr4)
        check(scr4.insetBy(dx: 8, dy: 8).contains(edge4), "at a corner the deck stays whole on the screen \(edge4)")
        let onSide4 = DeckRules.placeHand(hs, fanLeft: 56, caret: CGRect(x: 2000, y: 300, width: 2, height: 18), field: nil, screens: [scr4, side4], screen: scr4)
        check(side4.contains(onSide4), "the caret's own screen")
        let byField = DeckRules.placeHand(hs, fanLeft: 56, caret: nil, field: CGRect(x: 200, y: 100, width: 600, height: 300), screens: [scr4], screen: scr4)
        check(byField.minX == 200 + 12 - 56 && byField.minY > 100, "no caret: the field's top-left line \(byField)")
        check(DeckRules.placeHand(hs, fanLeft: 56, caret: nil, field: nil, screens: [scr4], screen: scr4) == CGRect(x: 520, y: 300, width: 400, height: 300), "nothing: the screen's middle")
        // selection and the fan
        check(DeckRules.selected(nil, count: 4) == 3 && DeckRules.selected(1, count: 4) == 1 && DeckRules.selected(9, count: 4) == 3 && DeckRules.selected(nil, count: 0) == nil,
              "the newest is selected by default; a gone card falls back to the newest")
        check(DeckRules.handShown(count: 0, selected: nil).shown == [], "no cards")
        check(DeckRules.handShown(count: 2, selected: nil).shown == [0, 1] && DeckRules.handShown(count: 2, selected: nil).folded == [], "two cards, nothing folded")
        let sh7 = DeckRules.handShown(count: 7, selected: nil)
        check(sh7.shown == [4, 5, 6] && sh7.folded == [0, 1, 2, 3], "seven: the newest three, 4 folded behind the badge")
        let sel1 = DeckRules.handShown(count: 7, selected: 1)
        check(sel1.shown.last == 1 && sel1.shown == [5, 6, 1] && sel1.folded == [0, 2, 3, 4], "a folded card selected comes to the top: \(sel1)")
        check(DeckRules.handShown(count: 3, selected: 0).shown == [1, 2, 0], "the selected card on top")
        let top4 = DeckRules.handTop(pixels: CGSize(width: 3024, height: 1964))
        check(abs(top4.width - 300) <= 10 && top4.height == 190, "a screen shot's top card about 300x190: \(top4)")
        check(DeckRules.handTop(pixels: CGSize(width: 4000, height: 800)).width == 360, "a wide picture: 360 at most")
        check(DeckRules.handTop(pixels: CGSize(width: 600, height: 1800)).width >= 150, "a tall picture: still 150 wide")
        let tCard = DeckRules.fanCard(slot: 2, of: 3, top: top4), fs4 = DeckRules.fanSize(3, top: top4)
        check(tCard.degrees == 0 && tCard.frame.size == top4 && abs(tCard.frame.maxX - fs4.width) < 0.5, "the top card straight, whole size, at the right")
        let back4 = DeckRules.fanCard(slot: 0, of: 3, top: top4), mid4 = DeckRules.fanCard(slot: 1, of: 3, top: top4)
        check(abs(back4.frame.width - top4.width * 0.85) < 0.5 && back4.frame.minX >= -0.5, "the deepest at 85%, inside the fan")
        check(abs((mid4.frame.midX - back4.frame.midX) - 28) < 0.5 && mid4.degrees - back4.degrees == 3, "peeks 28 pt apart, 3 degrees apart")
        let lift4 = DeckRules.fanCard(slot: 1, of: 3, top: top4, lifted: true)
        check(lift4.frame.minX == mid4.frame.minX && mid4.frame.minY - lift4.frame.minY == 6 && lift4.degrees == mid4.degrees, "hover lifts 6 pt, nothing else moves")
        check(DeckRules.fanSize(1, top: top4) == top4, "one card: the fan is that card")
        // the row
        check(DeckRules.HandButton.row(count: 3).map { $0.word(listening: false) } == ["Insert this", "Next shot", "Voice", "Mark up", "Drop", "Insert all"], "the bar's words, Insert all at the right end")
        check(DeckRules.HandButton.row(count: 1).last == .insertAll, "Insert all at the right end with one card too")
        check(!DeckRules.HandButton.row(count: 1).contains(.insertThis), "one card: no Insert this")
        check(DeckRules.HandButton.allCases.allSatisfy { !$0.word(listening: false).contains("Put in") && !$0.tip(captureKey: "", count: 2).word.contains("Put in") }, "no Put in wording")
        check(DeckRules.HandButton.voice.word(listening: true) == "Stop", "Voice while listening: Stop")
        check(DeckRules.HandButton.next.tip(captureKey: "⌘⇧5", count: 1).key == "⌘⇧5" && DeckRules.HandButton.drop.tip(captureKey: "x", count: 1).key == "", "only the next shot names a key")
        check(DeckRules.rowGap == 8 && DeckRules.rowH == 32 && DeckRules.rowFontSize == 12 && DeckRules.rowSpacing == 8 && DeckRules.pressSeconds == 0.08, "the bar's sizes")
        check(DeckRules.corner == 10 && DeckRules.plusSize == 24 && DeckRules.captionInset == 6, "one corner, the round +, the caption inset")
        // insert, drop, drag
        check(DeckRules.putOne(1, count: 3) == .one(1), "a card of three goes alone")
        check(DeckRules.putOne(0, count: 1) == .all, "the last card: all, the deck closes")
        check(DeckRules.putOne(5, count: 3) == nil, "no such card")
        check(DeckRules.mayInsert(busy: false, count: 2) && !DeckRules.mayInsert(busy: true, count: 2) && !DeckRules.mayInsert(busy: false, count: 0), "one insert at a time")
        check(DeckRules.backAt(2, count: 4) == 2 && DeckRules.backAt(5, count: 2) == 2, "a failed card goes back where it was")
        check(DeckRules.reorders(dx: 9, dy: 2) && !DeckRules.reorders(dx: 7, dy: 0) && !DeckRules.reorders(dx: 10, dy: 30), "a drag reorders after 8 pt sideways only")
        check(DeckRules.undoSeconds == 10 && DeckRules.stripH == 56 && DeckRules.gripH == 12 && DeckRules.closeSize == 24, "undo, strip, grip, close")
        check(!DeckRules.takesKeys, "the deck never takes his keys")
        // round 5 "Stack": one column, newest at the bottom, placed once and never moved by a new shot
        let shotPx = CGSize(width: 3024, height: 1964)
        let im5 = DeckRules.stackImage(pixels: shotPx)
        check(im5.width == 272 && abs(im5.height - 177) <= 1, "a screen shot 272 pt wide in its own shape: \(im5)")
        let tall5 = DeckRules.stackImage(pixels: CGSize(width: 800, height: 6000))
        check(tall5.height == 360 && tall5.width < 272, "a tall shot at most 360 high, narrower: \(tall5)")
        check(DeckRules.stackBox(pixels: CGSize(width: 4000, height: 400)).height == 120, "a thin shot's box keeps room for its buttons")
        let scr5 = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let low = DeckRules.placeStack(CGSize(width: 296, height: 500), spot: CGRect(x: 600, y: 200, width: 2, height: 18), screen: scr5)
        check(!low.growsDown && low.frame.minY == 226 && low.frame.minX == 588, "room above: just above the caret, its bottom stays: \(low)")
        check(low.maxH == 630, "it may grow to 70% of the screen before it scrolls: \(low.maxH)")
        let high5 = DeckRules.placeStack(CGSize(width: 296, height: 500), spot: CGRect(x: 600, y: 760, width: 2, height: 18), screen: scr5)
        check(high5.growsDown && high5.frame.maxY == 752, "no room above: under the caret, its top stays: \(high5)")
        check(high5.frame.minY >= 8 && high5.frame.maxY <= 892, "whole on the screen")
        let huge = DeckRules.placeStack(CGSize(width: 296, height: 2000), spot: CGRect(x: 600, y: 100, width: 2, height: 18), screen: scr5)
        check(huge.frame.height == huge.maxH && huge.frame.height <= 630, "a long column scrolls past 70%: \(huge.frame.height)")
        let edge = DeckRules.placeStack(CGSize(width: 296, height: 300), spot: CGRect(x: 1430, y: 200, width: 2, height: 18), screen: scr5)
        check(edge.frame.maxX <= 1432, "at the right edge: whole on the screen")
        let grown = DeckRules.restack(low.frame, height: 620, growsDown: false)
        check(grown.minY == low.frame.minY && grown.minX == low.frame.minX, "a new shot: the bottom stays, it grows up")
        let grownDown = DeckRules.restack(high5.frame, height: 620, growsDown: true)
        check(grownDown.maxY == high5.frame.maxY && grownDown.minX == high5.frame.minX, "growing down: the top stays")
        check(DeckRules.stackRoom(CGRect(x: 0, y: 800, width: 296, height: 90), growsDown: false, screen: scr5) == DeckRules.stackChrome + DeckRules.stackMinH, "dragged near the top: still room for one shot")
        check(DeckRules.clampScroll(900, content: 1000, room: 400) == 600 && DeckRules.clampScroll(-5, content: 1000, room: 400) == 0, "the scroll stays inside")
        check(DeckRules.reordersInColumn(dx: 1, dy: 9) && !DeckRules.reordersInColumn(dx: 12, dy: 9), "a drag up or down reorders")
        check(DeckRules.ShotAct.words.map { $0.word() } == ["Insert", "Copy", "Delete"], "each shot: Insert, Copy, Delete")
        check(DeckRules.FootAct.allCases.map { $0.word(count: 3) } == ["Next shot", "Copy all", "Insert all"], "the foot")
        check(DeckRules.FootAct.insertAll.key(captureKey: "x", returnKey: true) == "↵" && DeckRules.FootAct.insertAll.key(captureKey: "x", returnKey: false) == "", "↵ on Insert all only while ↵ inserts")
        // round 4c: ↵ inserts all until he types in his app
        check(DeckRules.returnInserts(deckOpen: true, keysSinceOpen: 0, mods: []), "↵ right after the deck opened: insert all")
        check(DeckRules.returnInserts(deckOpen: true, keysSinceOpen: 0, mods: [.maskNumericPad]), "keypad Enter counts")
        check(DeckRules.returnInserts(deckOpen: true, keysSinceOpen: 0, mods: [.maskNumericPad, .maskSecondaryFn]), "fn Return (keypad Enter) counts")
        check(!DeckRules.returnInserts(deckOpen: true, keysSinceOpen: 1, mods: []), "one key typed: ↵ is his app's")
        check(!DeckRules.returnInserts(deckOpen: true, keysSinceOpen: 12, mods: []), "a message being written is never taken")
        check(!DeckRules.returnInserts(deckOpen: false, keysSinceOpen: 0, mods: []), "no deck: ↵ is his app's")
        for m: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            check(!DeckRules.returnInserts(deckOpen: true, keysSinceOpen: 0, mods: m), "a modifier: ↵ is his app's (\(m.rawValue))")
        }
        check(DeckRules.isReturn(36) && DeckRules.isReturn(76) && !DeckRules.isReturn(48) && !DeckRules.isReturn(53), "Return and keypad Enter only")
        check(DeckRules.returnLog(inserted: true, keysSinceOpen: 0) == "shot: ↵ inserted all", "the insert log line")
        check(DeckRules.returnLog(inserted: false, keysSinceOpen: 3) == "shot: ↵ passed to app, 3 keys since open", "the pass log line")
        check(DeckRules.HandButton.insertAll.tip(captureKey: "", count: 2, returnKey: true).key == "↵", "Insert all names ↵ while it inserts")
        check(DeckRules.HandButton.insertAll.tip(captureKey: "", count: 2).key == "", "and nothing once he typed")
        // Insert all: N cards give N picture steps in deck order; captions after their picture, or the agent text first
        for n in 1...6 {
            let caps = (0..<n).map { $0 % 2 == 0 ? "caption \($0)" : "" }
            let other = DeckRules.steps(captions: caps, agent: false)
            let pics = other.compactMap { s -> Int? in if case .picture(let i) = s { return i }; return nil }
            check(pics == Array(0..<n), "other field, \(n) cards: \(n) pictures in deck order")
            for (k, s) in other.enumerated() {
                if case .text(let t) = s {
                    let i = Int(t.split(separator: " ").last!)!
                    check(k > 0 && other[k - 1] == .picture(i), "other field, \(n) cards: caption \(i) right after its picture")
                }
            }
            check(other.filter { if case .text = $0 { return true }; return false }.count == caps.filter { !$0.isEmpty }.count, "other field, \(n) cards: each caption once")
            let agent = DeckRules.steps(captions: caps, agent: true, agentText: "made-up agent text")
            check(agent == [.text("made-up agent text")] + (0..<n).map { .picture($0) }, "agent app, \(n) cards: the text first, then \(n) pictures in order")
        }
        check(DeckRules.handVoice(open: true, micOpening: true) && !DeckRules.handVoice(open: true, micOpening: false) && !DeckRules.handVoice(open: false, micOpening: true),
              "his voice is a caption only when the deck's Voice opens the take")
        check(DeckRules.endsCaption(clickInside: false, onMic: false) && DeckRules.endsCaption(clickInside: true, onMic: true) && !DeckRules.endsCaption(clickInside: true, onMic: false),
              "a caption ends on Voice again or a click outside")
        check(DeckRules.slideSeconds == 0.12 && DeckRules.flySeconds == 0.18 && DeckRules.peekPreviewDelay == 0.7 && DeckRules.previewW == 480, "the hand's motion and preview")
        check(DeckRules.arriveSeconds >= 0.15 && DeckRules.arriveSeconds <= 0.2 && DeckRules.closeSeconds == 0, "arrival 150-200 ms, no motion on close")
        check(DeckRules.arriveScale < 1 && DeckRules.arriveScale >= 0.95 && DeckRules.arriveRise > 0 && DeckRules.arriveRise <= 16, "a small rise and scale")

        // what goes in: each card as one unit
        check(DeckRules.steps(captions: ["a", "", "c"], agent: false) == [.picture(0), .text("a"), .picture(1), .picture(2), .text("c")],
              "ordinary field: picture, its caption, next picture")
        check(DeckRules.steps(captions: ["a", "b"], agent: true, agentText: "Screenshots attached: 2 pictures") ==
              [.text("Screenshots attached: 2 pictures"), .picture(0), .picture(1)], "agent app: the text first, then the pictures (one message)")
        check(DeckRules.steps(captions: [""], agent: true, agentText: "") == [.picture(0)], "agent app, no text: the picture")
        // speed round: gaps between steps, what ↵ waits for
        check(DeckRules.gap(after: .text("a")) == 0.25 && DeckRules.gap(after: .picture(0)) == 0.8, "gaps: text 0.25 s, picture 0.8 s")
        check(!DeckRules.waitsForRead(terminal: false) && DeckRules.waitsForRead(terminal: true), "only a terminal waits for the read")
        check(DeckRules.waitsForTalk(idle: false, deckTake: true), "the deck's caption take: wait")
        check(!DeckRules.waitsForTalk(idle: false, deckTake: false), "a take in another app: no wait")
        check(!DeckRules.waitsForTalk(idle: true, deckTake: true), "idle: no wait")
        check(DeckRules.steps(captions: ["a"], agent: false, pictures: false, agentText: "line") == [.text("line")], "terminal: text alone")
        check(DeckRules.steps(captions: [""], agent: false) == [.picture(0)], "no caption: the picture alone")
        check(DeckRules.pictureHold >= 1.5, "pictures stay on the clipboard long enough for Electron apps")

        // the action row: cancel left, two in the middle, send and put in right
        let rr = DeckRules.row(widths: [80, 90, 100, 90, 100], groups: (1, 2, 2), x0: 10, x1: 710, y: 0, h: 36)
        check(rr[0].minX == 10, "cancel on the left")
        check(rr[4].maxX == 710, "put in is the rightmost")
        check(rr[3].maxX + 6 == rr[4].minX, "send to sits next to put in")
        check(abs((rr[1].minX + rr[2].maxX) / 2 - (rr[0].maxX + rr[3].minX) / 2) <= 1, "the middle group is centred")
        check(rr[0].maxX < rr[1].minX && rr[2].maxX < rr[3].minX, "no overlap")
        check(DeckRules.rowWidth(widths: [80, 90, 100, 90, 100], groups: (1, 2, 2)) == 460 + 24 + 48, "least width")

        // size and place
        check(DeckRules.cardWidth(n: 3, room: 1000) == DeckRules.cardW, "few cards: full width")
        check(DeckRules.cardWidth(n: 20, room: 1000) == DeckRules.minCardW, "many cards: never under the minimum")
        let mid = DeckRules.cardWidth(n: 8, room: 900)
        check(mid > DeckRules.minCardW && mid < DeckRules.cardW, "cards shrink to fit: \(mid)")
        check(DeckRules.parse("120,40") == CGPoint(x: 120, y: 40), "saved place read back")
        check(DeckRules.parse("") == nil && DeckRules.parse("a,b") == nil && DeckRules.parse("1") == nil, "a bad place is none")
        check(DeckRules.save(CGPoint(x: 120.4, y: 39.6)) == "120,40", "place written rounded")
        let scr = CGRect(x: 0, y: 0, width: 1440, height: 875), size = CGSize(width: 600, height: 150)
        let d = DeckRules.place(size, saved: nil, screens: [scr], screen: scr)
        check(d.midX == 720 && d.minY == 24, "default: bottom centre \(d)")
        let s = DeckRules.place(size, saved: CGPoint(x: 100, y: 500), screens: [scr], screen: scr)
        check(s.minX == 100 && s.minY == 500, "the dragged place \(s)")
        let off = DeckRules.place(size, saved: CGPoint(x: 1400, y: 860), screens: [scr], screen: scr)
        check(off.maxX <= 1432 && off.maxY <= 867, "kept inside its screen \(off)")
        let gone = DeckRules.place(size, saved: CGPoint(x: 3000, y: 500), screens: [scr], screen: scr)
        check(gone.minY == 24, "a screen no longer there: the default \(gone)")
        let g = DeckRules.regrow(d, to: CGSize(width: 800, height: 150), centred: true, screen: scr)
        check(g.midX == d.midX && g.width == 800, "centred deck grows both ways")
        let l = DeckRules.regrow(s, to: CGSize(width: 800, height: 150), centred: false, screen: scr)
        check(l.minX == 100, "dragged deck keeps its left edge")

        // level
        check(DeckRules.level(peak: 0) == 0, "silence")
        check(DeckRules.level(peak: 0.001) == 0, "room noise shows nothing")
        check(DeckRules.level(peak: 1) == 1, "loud is full")
        check(DeckRules.bars([0.5]) == [0, 0, 0, 0, 0.5], "bars filled from the right")

        // the pack text with captions
        var p = ShotPack(id: "20261117-101010-abcd", t: 1_763_370_000, app: "Safari", window: "Order form", width: 800, height: 500)
        p.setPictures([ShotPicture(file: "", width: 800, height: 500, caption: "the first step"),
                       ShotPicture(file: "", width: 640, height: 400, caption: ""),
                       ShotPicture(file: "", width: 900, height: 600, caption: "the total is wrong")])
        let a = p.agentText(path: nil)
        check(a.hasPrefix("Screenshots attached: 3 pictures"), "the hand-off line")
        check(a.contains("Picture 1 of 3 (800×500 px)\nCaption: the first step"), "caption under its picture: \(a)")
        check(!a.contains("Picture 2 of 3 (640×400 px)\nCaption"), "no caption line when empty")
        check(p.deckText == "1. the first step\n3. the total is wrong", "numbered captions for a field: \(p.deckText)")
        check(p.fieldPut(.other, path: "/x/shot.png", md: "/x/shot.md") == ShotPack.Put(picture: true, text: p.deckText), "↵ in a field: pictures, then captions")
        let t = p.terminalLine(path: "/x/shot.png", md: "/x/shot.md")
        check(t.contains("Captions: 1 - the first step; 3 - the total is wrong") && !t.contains("\n"), "terminal: one line \(t)")
        // one picture: its caption is the note, as before
        var one = ShotPack(id: "20261117-101011-abcd", t: 1_763_370_000, width: 800, height: 500)
        one.setPictures([ShotPicture(file: "", width: 800, height: 500, caption: "only one")])
        check(one.note == "only one" && one.pictures == nil, "one card: the note")
        check(one.agentText(path: nil).contains("Note: only one"), "one card: Note line")
        check(one.pics[0].caption == "only one", "one card reads its caption back")
        check(p.summary == "the first step · the total is wrong", "journal line: the captions \(p.summary)")
        check(one.summary == "only one", "journal line: the note")
        // JSON round trip, and an older shot.json without captions
        let enc = try! JSONEncoder().encode(p)
        check((try? JSONDecoder().decode(ShotPack.self, from: enc)) == p, "round trip")
        var old = p; old.pictures = old.pictures?.map { var x = $0; x.caption = nil; return x }
        let oj = String(data: try! JSONEncoder().encode(old), encoding: .utf8)!
        check(!oj.contains("caption"), "no caption key when none")
        check((try? JSONDecoder().decode(ShotPack.self, from: oj.data(using: .utf8)!))?.captions == ["", "", ""], "older pack reads")

        print(failures == 0 ? "deck rules: all passed" : "deck rules: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
