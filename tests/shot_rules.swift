import Foundation
import CoreGraphics

// swiftc -parse-as-library app/PenRules.swift app/QuickRules.swift app/PictureLookRules.swift app/ClipRules.swift app/ShotRules.swift app/MarkupRules.swift app/ShotPackRules.swift tests/shot_rules.swift -o app/build/shot-rules-test && app/build/shot-rules-test
// Quick capture's rules: the key, the dimmed screen's keys, the region on its display, the picture-and-text strip.
@main
struct ShotRulesTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func markup() {
        var m = Markup(size: CGSize(width: 1000, height: 600))
        check(Markup.toolCodes[18] == .arrow && Markup.toolCodes[22] == .crop && Markup.toolCodes.count == 8 && Markup.toolCodes[26] == .pin && Markup.toolCodes[35] == .pen, "1-7 pick the tool, 7 the pin, P the pen")
        m.add(PicMark(tool: .arrow, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 11)))
        check(m.marks.isEmpty, "a click is no arrow")
        m.add(PicMark(tool: .label, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10)))
        check(m.marks.isEmpty, "an empty label is dropped")
        m.add(PicMark(tool: .box, from: CGPoint(x: 900, y: 500), to: CGPoint(x: 1200, y: -40)))
        check(m.marks.first?.rect == CGRect(x: 900, y: 0, width: 100, height: 500), "clamped to the picture")
        m.add(PicMark(tool: .crop, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400)))
        m.add(PicMark(tool: .crop, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 450, y: 350)))
        check(m.marks.filter { $0.tool == .crop }.count == 1 && m.crop == CGRect(x: 50, y: 50, width: 400, height: 300), "one crop, the last")
        m.undo(); check(m.crop == CGRect(x: 100, y: 100, width: 400, height: 300), "undo the second crop: the first comes back")
        m.undo(); check(m.crop.size == CGSize(width: 1000, height: 600), "undo the first: whole picture"); m.redo()
        m.redo(); check(m.crop.width == 400, "redo")
        m.undo(); m.add(PicMark(tool: .highlight, from: .zero, to: CGPoint(x: 40, y: 40))); m.redo()
        check(m.marks.last?.tool == .highlight, "a new mark clears redo")
        let f = Markup.fit(CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 800, height: 800))
        check(f.scale == 0.4 && f.rect == CGRect(x: 0, y: 200, width: 800, height: 400), "fit: \(f)")
        check(Markup.toPicture(CGPoint(x: 400, y: 400), fitted: f.rect, scale: f.scale) == CGPoint(x: 1000, y: 500), "editor point to pixels")
        check(Markup.fit(CGSize(width: 100, height: 50), in: CGRect(x: 0, y: 0, width: 800, height: 800)).scale == 1, "never scaled up")
        check(Markup.stroke(CGSize(width: 2600, height: 1600)) == 10 && Markup.stroke(CGSize(width: 300, height: 200)) == 3, "stroke width")
        check(Markup.block(CGRect(x: 0, y: 0, width: 300, height: 30)) == 8, "pixel block at least 8")
        pins()
    }

    static func pins() {
        var m = Markup(size: CGSize(width: 1000, height: 600))
        for x in [100, 300, 500] { m.add(PicMark(tool: .pin, from: CGPoint(x: x, y: 50), to: CGPoint(x: x, y: 50))) }
        check(m.marks.map(\.n) == [1, 2, 3], "a click puts the next number")
        m.undo(); check(m.nextPin == 3, "undo the third: the next is 3 again")
        m.redo(); check(m.marks.last?.n == 3 && m.nextPin == 4, "redo keeps its number")
        m.add(PicMark(tool: .pin, from: CGPoint(x: 700, y: 60), to: CGPoint(x: 700, y: 60), text: "this one"))
        check(m.marks.last?.n == 4 && m.marks.last?.text == "this one", "a pin with its text")
        check(Markup.pinRadius(CGSize(width: 2600, height: 1600)) > Markup.pinRadius(CGSize(width: 300, height: 200)), "pin grows with the picture")
        // as data: crop at 200,0 400×300: the pin at 100 and the box outside it are dropped, the rest shifted
        m.add(PicMark(tool: .box, from: CGPoint(x: 0, y: 400), to: CGPoint(x: 100, y: 500)))
        m.add(PicMark(tool: .box, from: CGPoint(x: 150, y: 100), to: CGPoint(x: 260, y: 200)))
        m.add(PicMark(tool: .arrow, from: CGPoint(x: 550, y: 250), to: CGPoint(x: 320, y: 60)))
        m.add(PicMark(tool: .pixelate, from: CGPoint(x: 220, y: 10), to: CGPoint(x: 300, y: 40)))
        m.add(PicMark(tool: .crop, from: CGPoint(x: 200, y: 0), to: CGPoint(x: 600, y: 300)))
        let d = m.shotMarks
        check(d.filter { $0.kind == "pin" }.map { $0.n ?? 0 } == [2, 3], "pins outside the crop dropped: \(d.filter { $0.kind == "pin" }.map { $0.n ?? 0 })")
        check(d.first { $0.n == 2 }.map { [$0.x, $0.y] } == [100, 50], "pin shifted by the crop origin")
        check(d.filter { $0.kind == "box" }.count == 1 && d.first { $0.kind == "box" }.map { [$0.x, $0.w] } == [0, 60], "box clipped to the crop")
        check(d.first { $0.kind == "arrow" }.map { [$0.x, $0.y, $0.toX ?? 0, $0.toY ?? 0] } == [350, 250, 120, 60], "arrow in crop pixels")
        check(d.contains { $0.kind == "blur" && $0.x == 20 && $0.w == 80 }, "blur kept as blur")
        check(m.shotCrop == [200, 0, 400, 300], "crop kept: \(String(describing: m.shotCrop))")
        check(Markup(size: CGSize(width: 10, height: 10)).shotCrop == nil, "no crop: nil")
    }

    static func newKeys() {
        check(ShotRules.allowed("⌘⇧5"), "⌘⇧5 may be set now")
        check(ShotRules.systemKeyOn(nil) && ShotRules.systemKeyOn([:]), "no entry: macOS keeps ⌘⇧5")
        check(!ShotRules.systemKeyOn(["184": ["enabled": false]]) && !ShotRules.systemKeyOn(["184": ["enabled": NSNumber(value: 0)]]), "turned off")
        check(ShotRules.systemKeyOn(["184": ["enabled": 1]]), "turned on")
        // keys round two (17 November 2026): ⌘⇧5 is the key, only once macOS lets it go; an optional fallback; ⌘⇧S off by default
        check(ShotRules.defaultKey == "⌘⇧5", "the default is ⌘⇧5")
        check(ShotRules.keys(setting: "", systemOn: false, cmdShiftS: true, fallback: "⌃⌥S") == [], "off: no key at all, not the fallback or ⌘⇧S")
        check(ShotRules.keys(setting: "⌘⇧5", systemOn: false, cmdShiftS: false) == ["⌘⇧5"], "macOS let go: ⌘⇧5 alone")
        check(ShotRules.keys(setting: "⌘⇧5", systemOn: true, cmdShiftS: false) == [], "macOS holds ⌘⇧5, no fallback: no key yet")
        check(ShotRules.keys(setting: "⌘⇧5", systemOn: true, cmdShiftS: false, fallback: "⌃⌥S") == ["⌃⌥S"], "macOS holds ⌘⇧5: the fallback")
        check(ShotRules.keys(setting: "⌘⇧5", systemOn: false, cmdShiftS: false, fallback: "⌃⌥S") == ["⌘⇧5", "⌃⌥S"], "⌘⇧5 first, the fallback beside it")
        check(ShotRules.keys(setting: "⌘⇧5", systemOn: false, cmdShiftS: true) == ["⌘⇧5", "⌘⇧S"], "⌘⇧S only when he turns it on, after ⌘⇧5")
        check(ShotRules.keys(setting: "⌘⇧5", systemOn: false, cmdShiftS: false, fallback: "⌘⇧5") == ["⌘⇧5"], "a fallback equal to the key: once")
        check(ShotRules.keys(setting: "⌘⇧5", systemOn: true, cmdShiftS: false, fallback: "⌘⇧5") == [], "the fallback is never macOS's held ⌘⇧5")
        check(ShotRules.keys(setting: "⌘⇧5", systemOn: false, cmdShiftS: false, fallback: "⌘⇧4") == ["⌘⇧5"], "a taken fallback is left out")
        check(ShotRules.keys(setting: "⌃⌥S", systemOn: true, cmdShiftS: false) == ["⌃⌥S"], "the old key, set by hand, still works")
        check(ShotRules.keys(setting: "⌃⌥⇧S", systemOn: false, cmdShiftS: false) == ["⌃⌥⇧S"], "his own key alone")
        check(ShotRules.keys(setting: "⌘⇧S", systemOn: true, cmdShiftS: true) == ["⌘⇧S"], "⌘⇧S set as the key: once")
        check(ShotRules.keys(setting: "⌘⇧4", systemOn: false, cmdShiftS: true) == ["⌘⇧S"], "a taken key: none of its own")
        check(ShotRules.allowed("⌘⇧S"), "⌘⇧S is allowed (apps' Save As; the setting gives it back)")
        check(ShotRules.showSystemStep(setting: "⌘⇧5", systemOn: true) && !ShotRules.showSystemStep(setting: "⌘⇧5", systemOn: false)
              && !ShotRules.showSystemStep(setting: "", systemOn: true) && !ShotRules.showSystemStep(setting: "⌃⌥S", systemOn: true),
              "the step only while ⌘⇧5 is the key and macOS holds it")
        check(ShotRules.hintDue(setting: "⌘⇧5", systemOn: true, shown: false), "the hint: due once")
        check(!ShotRules.hintDue(setting: "⌘⇧5", systemOn: true, shown: true) && !ShotRules.hintDue(setting: "⌘⇧5", systemOn: false, shown: false)
              && !ShotRules.hintDue(setting: "", systemOn: true, shown: false), "the hint: never twice, never when free or off")
        check(ShotRules.systemPath.contains("Keyboard Shortcuts") && ShotRules.systemPath.contains("Screenshots"), "the path names the place")
        check(ShotRules.key(18, dragging: false) == .pick(.region) && ShotRules.key(19, dragging: false) == .pick(.window)
              && ShotRules.key(20, dragging: false) == .screen && ShotRules.key(19, dragging: true) == .none, "1 2 3")
        check(ShotRules.key(1, dragging: false) == .pick(.scroll) && ShotRules.key(1, dragging: true) == .none, "S: scrolling capture")
        let tb = ShotRules.toolbar(screen: CGSize(width: 1440, height: 900))
        check(ShotRules.hit(CGPoint(x: tb.items[3].midX, y: tb.items[3].midY), tb.items) == .scroll, "hit scroll")
        check(abs(tb.bar.midX - 720) <= 1 && tb.bar.minY == 72 && tb.bar.height == 56, "bottom centre, 56 tall: \(tb.bar)")
        check(tb.items.count == 8 && tb.items.allSatisfy { tb.bar.contains($0) && $0.width == 42 && $0.height == 42 }, "eight 42 pt buttons inside the bar")
        check(tb.items[4].minX - tb.items[3].maxX == 13 && tb.items[1].minX - tb.items[0].maxX == 2, "a wider gap between groups")
        check(ShotRules.hit(CGPoint(x: tb.items[1].midX, y: tb.items[1].midY), tb.items) == .window, "hit window")
        check(ShotRules.hit(CGPoint(x: tb.items[7].midX, y: tb.items[7].midY), tb.items) == .cancel, "hit esc")
        check(ShotRules.hit(CGPoint(x: tb.items[3].maxX + 7, y: tb.items[3].midY), tb.items) == nil, "a gap is nothing")
        check(ShotRules.toolbarPill(screen: CGSize(width: 1440, height: 900)).dividers.count == 2, "two hairlines: capture | options | send")
        check(Set(ShotRules.Tool.allCases.map(\.glyph)).count == ShotRules.Tool.allCases.count && ShotRules.Tool.allCases.allSatisfy { !$0.key.isEmpty && !$0.word.isEmpty }, "every button: its own glyph, a key, a word")
        pills()
        check(ShotRules.strip(code: 14, cmd: true, line: "") == .markup && ShotRules.strip(code: 48, cmd: false, line: "x") == .sendList, "⌘E, ⇥")
        check(ShotRules.strip(code: 36, cmd: false, line: " a ") == .note(.pictureAndLine("a")) && ShotRules.strip(code: 0, cmd: false, line: "") == .typing, "↵ and typing")
    }



    /// The pills: layout, the markup pill's hit, attaching under a picture; the markup model's look round.
    static func pills() {
        let p = ShotRules.pill([[32, 32], [24], [32]], at: CGPoint(x: 100, y: 50))
        check(p.bar == CGRect(x: 100, y: 50, width: 7 + 32 + 2 + 32 + 13 + 24 + 13 + 32 + 7, height: 56), "pill size: \(p.bar)")
        check(p.items[0].minX == 107 && p.items[2].minX == p.items[1].maxX + 13 && p.dividers.count == 2, "groups split")
        check(p.dividers[0] > p.items[1].maxX && p.dividers[0] < p.items[2].minX, "the hairline sits between the groups")
        let mp = ShotRules.markPill(at: .zero)
        check(mp.items.count == 8 + 5 + 3 + 2 + 2 && mp.bar.size == ShotRules.markPillSize, "markup pill: 20 buttons")
        check(ShotRules.markHit(CGPoint(x: mp.items[0].midX, y: mp.items[0].midY), mp) == .tool(.arrow), "hit arrow")
        check(ShotRules.markHit(CGPoint(x: mp.items[8].midX, y: mp.items[8].midY), mp) == .color(0), "hit red")
        check(ShotRules.markHit(CGPoint(x: mp.items[1].midX, y: mp.items[1].midY), mp) == .tool(.pen), "hit pen, next to the arrow")
        check(ShotRules.markHit(CGPoint(x: mp.items[19].midX, y: mp.items[19].midY), mp) == .done && ShotRules.markHit(CGPoint(x: mp.items[17].midX, y: mp.items[17].midY), mp) == .add, "hit done, add")
        check(ShotRules.markHit(CGPoint(x: -5, y: 5), mp) == nil, "outside")
        check(Set(MarkTool.allCases.map(\.glyph)).count == 8, "a glyph per tool")
        check(Set(ShotRules.StripButton.allCases.map(\.glyph)).count == ShotRules.StripButton.allCases.count, "a glyph per strip key")
        check(Set(ShotTarget.allCases.map(\.glyph)).count >= 6, "the send-to list's glyphs")
        check(mp.bar.width <= 1440 - 16 && mp.items.allSatisfy { $0.height == 42 && $0.width >= 32 }, "the bigger markup pill stays one row on a 1440 pt screen: \(mp.bar.width)")
        check(ShotRules.toolbar(screen: CGSize(width: 1440, height: 900)).bar.width < 600, "the capture pill too")
        // attach (flipped, y down): under the picture; no room: the bottom edge, never above; beside it when it reaches
        // the bottom and there is room; else over its foot
        let b = CGRect(x: 0, y: 0, width: 1440, height: 900), s = CGSize(width: 400, height: 56)
        let under = ShotRules.attach(s, to: CGRect(x: 300, y: 200, width: 600, height: 300), in: b)
        check(under.minY == 510 && under.midX == 600, "under the picture: \(under)")
        let low = ShotRules.attach(s, to: CGRect(x: 300, y: 500, width: 600, height: 330), in: b)
        check(low.maxY == 892 && low.minY >= 830, "little room under: on the bottom edge, still under the picture: \(low)")
        let reach = ShotRules.attach(s, to: CGRect(x: 300, y: 500, width: 600, height: 380), in: b)
        check(reach.maxY == 892 && reach.minX == 910, "reaches the bottom: on the bottom edge, beside it on the right: \(reach)")
        let left = ShotRules.attach(s, to: CGRect(x: 700, y: 500, width: 700, height: 400), in: b)
        check(left.maxY == 892 && left.maxX == 690, "no room right: beside it on the left: \(left)")
        let full = ShotRules.attach(s, to: b, in: b)
        check(full.maxY == 892 && full.midX == 720, "a full-screen picture: the bottom edge over its foot: \(full)")
        check(ShotRules.attach(s, to: CGRect(x: 0, y: 100, width: 100, height: 100), in: b).minX == 8, "kept on the screen")
        // the visible frame starts under the menu bar and ends above the Dock: the pill stays inside it
        let vis0 = CGRect(x: 0, y: 25, width: 1440, height: 800)
        check(ShotRules.attach(s, to: CGRect(x: 300, y: 600, width: 600, height: 200), in: vis0).maxY == 817, "above the Dock")
        // the strip (AppKit points, y up): under the region on its left edge; never above it
        let vis = CGRect(x: 0, y: 0, width: 1440, height: 875), ss = CGSize(width: 680, height: 76)
        let reg = CGRect(x: 300, y: 400, width: 600, height: 300)
        check(ShotRules.stripPlace(ss, region: reg, full: false, screen: vis) == CGRect(x: 300, y: 314, width: 680, height: 76), "under the region, its left edge")
        let near = ShotRules.stripPlace(ss, region: CGRect(x: 300, y: 90, width: 600, height: 300), full: false, screen: vis)
        check(near.minY == 8 && near.maxY <= 90 && near.minX == 300, "little room under: the bottom edge, under the picture, not above it: \(near)")
        let lowR = CGRect(x: 100, y: 20, width: 500, height: 500)
        let side = ShotRules.stripPlace(ss, region: lowR, full: false, screen: vis)
        check(side.minY == 8 && side.minX == 610 && !side.intersects(lowR), "reaches the bottom: the bottom edge, beside it: \(side)")
        let wide = CGRect(x: 0, y: 20, width: 1440, height: 840)
        let over = ShotRules.stripPlace(ss, region: wide, full: false, screen: vis)
        check(over.minY == 8 && over.minX == 8, "the lower screen filled: the bottom edge over its foot, its left edge: \(over)")
        check(ShotRules.stripPlace(ss, region: CGRect(x: 1200, y: 400, width: 200, height: 100), full: false, screen: vis).maxX == 1432, "kept on the screen")
        let fs = ShotRules.stripPlace(ss, region: vis, full: true, screen: vis)
        check(fs.midX == 720 && fs.minY == 8, "a whole screen: bottom centre: \(fs)")
        let dock = CGRect(x: 0, y: 70, width: 1440, height: 805)
        check(ShotRules.stripPlace(ss, region: dock, full: true, screen: dock).minY == 78, "inside the visible frame (above the Dock)")
        // the send-to list makes the card taller: placed again, the top stays while it fits under the region
        let grown = ShotRules.stripPlace(CGSize(width: 680, height: 354), region: reg, full: false, screen: vis)   // six rows
        check(grown.maxY == 390 && grown.minY == 36, "the list grows down, the top stays: \(grown)")
        let tall = ShotRules.stripPlace(CGSize(width: 680, height: 442), region: CGRect(x: 300, y: 300, width: 600, height: 400), full: false, screen: vis)
        check(tall.minY == 8 && tall.minX == 300, "no room for the list under it and none beside: the bottom edge, its left edge: \(tall)")
        // at a caret (no region): under, else above, as before
        check(ShotRules.caretPlace(ss, caret: CGRect(x: 300, y: 400, width: 2, height: 18), screen: vis).maxY == 390, "under the caret")
        check(ShotRules.caretPlace(ss, caret: CGRect(x: 300, y: 40, width: 2, height: 18), screen: vis).minY == 68, "above the caret near the foot")
        let g = ShotRules.stripGrow(CGRect(x: 300, y: 314, width: 680, height: 76), to: 300, screen: vis)
        check(g.maxY == 390 && g.minY == 90, "at a caret the list grows down, the top stays")
        check(ShotRules.stripGrow(CGRect(x: 0, y: 40, width: 680, height: 76), to: 300, screen: vis).minY == 8, "pushed up at the bottom")
        check(ShotRules.strip(code: 45, cmd: true, line: "") == .addAnother && Markup.key(45, cmd: true, shift: false) == .addAnother, "⌘N adds another picture")
        check(ShotRules.stripPick(code: 123, cmd: true, picked: nil, count: 3) == .pick(2) && ShotRules.stripPick(code: 123, cmd: true, picked: 0, count: 3) == .pick(0), "⌘← picks the last, then to the left")
        check(ShotRules.stripPick(code: 124, cmd: true, picked: 2, count: 3) == .pick(nil) && ShotRules.stripPick(code: 124, cmd: true, picked: 0, count: 3) == .pick(1), "⌘→ to the right, past the last back to the line")
        check(ShotRules.stripPick(code: 51, cmd: false, picked: 1, count: 3) == .remove(1) && ShotRules.stripPick(code: 51, cmd: false, picked: nil, count: 3) == nil, "⌫ takes the picked one out, else edits the line")
        check(ShotRules.stripPick(code: 53, cmd: false, picked: 1, count: 3) == .pick(nil) && ShotRules.stripPick(code: 123, cmd: true, picked: nil, count: 1) == nil, "esc lets go; one picture: no picking")
        selectMove()
    }

    static func selectMove() {
        var m = Markup(size: CGSize(width: 1000, height: 600))
        m.add(PicMark(tool: .box, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200)))
        m.add(PicMark(tool: .arrow, from: CGPoint(x: 500, y: 500), to: CGPoint(x: 700, y: 300)))
        m.add(PicMark(tool: .highlight, from: CGPoint(x: 600, y: 50), to: CGPoint(x: 900, y: 90)))
        m.add(PicMark(tool: .pin, from: CGPoint(x: 50, y: 400), to: CGPoint(x: 50, y: 400)))
        check(m.hit(CGPoint(x: 101, y: 150), slop: 4) == 0, "a box by its edge")
        check(m.hit(CGPoint(x: 200, y: 150), slop: 4) == nil, "not inside a box: a new mark can start there")
        check(m.hit(CGPoint(x: 600, y: 400), slop: 4) == 1, "an arrow by its line")
        check(m.hit(CGPoint(x: 750, y: 70), slop: 4) == 2, "a highlight by its area")
        check(m.hit(CGPoint(x: 58, y: 405), slop: 4) == 3, "a pin by its circle")
        check(m.hit(CGPoint(x: 400, y: 30), slop: 4) == nil, "nothing")
        m.selected = 0; m.move(0, by: 50, 20)
        check(m.marks[0].rect == CGRect(x: 150, y: 120, width: 200, height: 100), "moved")
        m.move(0, by: 5000, -5000)
        check(m.marks[0].rect == CGRect(x: 800, y: 0, width: 200, height: 100), "kept on the picture, shape kept")
        m.undo(); check(m.marks[0].rect.minX == 150, "undo the move")
        m.undo(); check(m.marks[0].rect.minX == 100, "undo the first move")
        m.redo(); m.redo(); check(m.marks[0].rect.minX == 800, "redo both")
        m.selected = 1; m.pick(color: 3); m.pick(size: 2)
        check(m.marks[1].color == 3 && m.marks[1].size == 2 && m.color == 3 && m.stroke == 2, "the selected mark takes colour and size")
        m.undo(); check(m.marks[1].size == 1 && m.marks[1].color == 3, "undo the size")
        m.delete(2); check(m.marks.count == 3 && !m.marks.contains { $0.tool == .highlight }, "delete")
        m.undo(); check(m.marks.count == 4 && m.marks[2].tool == .highlight, "undo the delete")
        m.add(PicMark(tool: .box, from: .zero, to: CGPoint(x: 40, y: 40), color: m.color, size: m.stroke))
        check(m.marks.last?.color == 3 && m.marks.last?.size == 2 && m.selected == nil, "a new mark gets the colour and size")
        check(Markup.key(15, cmd: false, shift: false) == .color(0) && Markup.key(9, cmd: false, shift: false) == .color(4), "R red, V violet")
        check(Markup.key(33, cmd: false, shift: false) == .sizeStep(-1) && Markup.key(30, cmd: false, shift: false) == .sizeStep(1), "[ and ]")
        check(Markup.key(51, cmd: false, shift: false) == .delete && Markup.key(6, cmd: true, shift: true) == .redo
              && Markup.key(6, cmd: true, shift: false) == .undo && Markup.key(18, cmd: false, shift: false) == .tool(.arrow), "⌫, ⌘⇧Z, ⌘Z, 1")
        check(Markup.stroke(CGSize(width: 2600, height: 1600), level: 0) < Markup.stroke(CGSize(width: 2600, height: 1600), level: 2), "three sizes")
        check(Markup.blurRadius(CGRect(x: 0, y: 0, width: 300, height: 30)) >= 7, "blur radius about a block")
        check(Markup.distance(CGPoint(x: 5, y: 5), .zero, CGPoint(x: 10, y: 0)) == 5, "distance to a segment")
    }

    /// shot.json's marks go back onto the first picture and give the same marks again (journal "mark up again").
    static func markAgain() {
        var m = Markup(size: CGSize(width: 1000, height: 600))
        m.add(PicMark(tool: .pin, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 300, y: 200), text: "here"))
        m.add(PicMark(tool: .pin, from: CGPoint(x: 400, y: 250), to: CGPoint(x: 400, y: 250)))
        m.add(PicMark(tool: .box, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 500, y: 300)))
        m.add(PicMark(tool: .arrow, from: CGPoint(x: 600, y: 400), to: CGPoint(x: 420, y: 260)))
        m.add(PicMark(tool: .pixelate, from: CGPoint(x: 200, y: 350), to: CGPoint(x: 400, y: 380)))
        m.add(PicMark(tool: .crop, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 700, y: 500)))
        let shot = m.shotMarks, crop = m.shotCrop
        let back = Markup.picMarks(shot, crop: crop)
        var m2 = Markup(size: m.size)
        for p in back { m2.add(p) }
        check(m2.shotMarks == shot && m2.shotCrop == crop, "mark up again gives the same marks and crop")
        check(m2.marks.filter { $0.tool == .pin }.map(\.n) == [1, 2] && m2.nextPin == 3, "pins keep their numbers")
        check(Markup.picMarks([], crop: nil).isEmpty, "no marks, no crop")
    }

    /// The highlight by the background under it (17 November 2026: on dark screens the multiply marker read as a
    /// shadow): a marker on light, a lightening fill with an outline on dark.
    static func highlightLook() {
        let white = Markup.luminance(1, 1, 1), black = Markup.luminance(0, 0, 0)
        check(abs(white - 1) < 1e-9 && black == 0, "luminance ends")
        let darkMode = Markup.luminance(0.12, 0.12, 0.13), midGrey = Markup.luminance(0.5, 0.5, 0.5), paper = Markup.luminance(0.96, 0.96, 0.95)
        check(darkMode < 0.02 && abs(midGrey - 0.214) < 0.01 && paper > 0.85, "luminance: dark mode \(darkMode), mid grey \(midGrey), paper \(paper)")
        let onDark = Markup.highlightLook(background: darkMode), onPaper = Markup.highlightLook(background: paper)
        check(onDark.lighten && onDark.outline, "on a dark screen: lightens and outlines, never darkens")
        check(!onPaper.lighten && !onPaper.outline && onPaper.fill == 0.72, "on paper: the marker as before")
        check(Markup.highlightLook(background: midGrey).lighten, "on mid-grey UI: lightens (multiply there made brown boxes)")
        check(Markup.highlightLook(background: 0.39).lighten && !Markup.highlightLook(background: 0.4).lighten, "the edge: 0.4")
        // the mean over pixels: a dark toolbar with a little white text is still dark
        var px: [UInt8] = []
        for i in 0..<64 { let v: UInt8 = i % 8 == 0 ? 240 : 30; px += [v, v, v, 255] }
        check(Markup.highlightLook(background: Markup.meanLuminance(px)).lighten, "dark UI with light text: lightens (\(Markup.meanLuminance(px)))")
        check(Markup.meanLuminance([]) == 1, "no pixels: light, the marker")
        let line = CGRect(x: 100, y: 200, width: 300, height: 18), around = Markup.highlightSample(line)
        check(around == CGRect(x: 82, y: 182, width: 336, height: 54), "measured round a text line, by its height: \(around)")
        check(Markup.highlightSample(CGRect(x: 10, y: 10, width: 40, height: 2)).minY == 2, "at least 8 px round a thin one")
        let sample = [UInt8](repeating: 250, count: 64 * 4)
        check(!Markup.highlightLook(background: Markup.meanLuminance(sample)).lighten, "a white sample: the marker")
    }

    static func main() {
        newKeys()
        markAgain()
        check(ShotRules.allowed(ShotRules.defaultKey) && ShotRules.allowed(ShotRules.oldKey), "⌘⇧5 and ⌃⌥S are allowed")
        for k in ["⌘⇧3", "⌘⇧4", "⌘⇧6", "⌃⌥V", "⌘⇧V", "S", "⇧S"] { check(!ShotRules.allowed(k), "\(k) refused") }
        check(ShotRules.allowed("⌃⌥⇧S"), "another chord is fine")

        check(ShotRules.key(53, dragging: false) == .cancel, "esc cancels")
        check(ShotRules.key(36, dragging: false) == .screen, "return takes the screen")
        check(ShotRules.key(36, dragging: true) == .none, "return during a drag does nothing")
        check(ShotRules.key(49, dragging: false) == .windowMode, "space picks a window")
        check(ShotRules.key(40, dragging: false) == .mode(.keep) && ShotRules.key(17, dragging: false) == .mode(.text), "K and T")

        check(ShotRules.region(CGPoint(x: 10, y: 10), CGPoint(x: 12, y: 300)) == nil, "too thin is a click")
        check(ShotRules.region(CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 50)) == CGRect(x: 100, y: 50, width: 200, height: 150), "any drag direction")
        // a 1440 × 900 main display, a second one above it
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900), top = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        check(ShotRules.sourceRect(CGRect(x: 100, y: 700, width: 200, height: 100), display: main) == CGRect(x: 100, y: 100, width: 200, height: 100), "flipped to the display's top-left")
        check(ShotRules.sourceRect(CGRect(x: 0, y: 1880, width: 100, height: 100), display: top) == CGRect(x: 0, y: 0, width: 100, height: 100), "second display")
        check(ShotRules.sourceRect(CGRect(x: 1400, y: 0, width: 100, height: 50), display: main).width == 40, "clipped to the display")
        check(ShotRules.sourceRect(CGRect(x: 2000, y: 0, width: 10, height: 10), display: main) == .zero, "off the display")
        check(ShotRules.hint(.text, pick: .region).hasSuffix("puts its text in"), "hint says the mode")

        // Part C: the strip after a capture
        check(ShotRules.note(code: 36, cmd: false, line: "") == .picture, "return on an empty line: the picture at once")
        check(ShotRules.note(code: 36, cmd: false, line: "  the error on step 3 ") == .pictureAndLine("the error on step 3"), "his line")
        check(ShotRules.note(code: 36, cmd: true, line: "x") == .pictureAndText, "⌘return: the read text")
        check(ShotRules.note(code: 53, cmd: false, line: "half typed") == .picture, "esc: the picture alone")
        check(ShotRules.note(code: 0, cmd: false, line: "") == nil, "a letter is typing")
        let d = ShotRules.delivery(.pictureAndLine("see the total"), read: "")
        check(d.picture && d.text == "see the total" && d.gapMs > 0, "picture first, then the line")
        check(ShotRules.delivery(.pictureAndText, read: "  ").text == nil, "no read text: the picture alone")
        check(ShotRules.apps.count == 6 && ShotRules.apps.allSatisfy { $0.status == "known" || $0.status == "needs a live test" }, "app table")
        markup()
        highlightLook()
        print(failures == 0 ? "shot rules: all passed" : "shot rules: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
