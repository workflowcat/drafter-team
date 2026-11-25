// One put-in rule for every place Drafter remembers an app and later pastes into it or raises it (17 November 2026,
// after the Beeper bug; Andrii: "for all of it, not just Beeper"). Pure; the hook is app/PutBack.swift.
//  1. The target is the app with the keys (Capture.keyApp: the accessibility focus), never the workspace's guess.
//  2. The target is raised only when Drafter itself is in front. Another app in front is where he moved to: raising
//     the target over it hid his window (Beeper) and the paste went into the wrong app. That goes to the clipboard.
//  3. After a paste the same app must still hold the keys, keep its windows and a field; else "unsure", the clipboard
//     and the pill.
import Foundation

enum PutRules {
    /// Who holds the keys now, seen from the remembered target.
    enum Front: Equatable { case target, drafter, other, none }
    static func front(keyPid: Int32?, targetPid: Int32?, ownPid: Int32) -> Front {
        guard let k = keyPid, k > 0 else { return .none }
        if k == ownPid { return .drafter }
        return k == targetPid ? .target : .other
    }

    /// What moved the front app away from the target (PutBack.SwitchWatch, 17 November 2026, Obsidian: Claude came
    /// to the front during the deck with no click on it). user: a click, a key or a modifier went just before the
    /// switch; system: nothing did (macOS or an app handed the focus over); unknown: no switch was seen.
    enum Moved: Equatable { case user, system, unknown }
    /// A switch this soon after his input is his.
    static let userWindow = 0.8
    static func moved(switchAt: Double?, lastInputAt: Double?) -> Moved {
        guard let s = switchAt else { return .unknown }
        if let i = lastInputAt, i <= s + 0.05, s - i <= userWindow { return .user }
        return .system
    }

    /// Where a put-in goes (17 November 2026: 5 shots "lost": each time he took the shot in Dia or Obsidian, clicked
    /// into the Claude app, then pressed ↵; the rule sent it to the clipboard). He moved there himself: there, the app
    /// he is in at ↵. Anything else: the app the shot was taken in (raised back over Drafter or after a system handoff).
    static func goesHere(front: Front, moved: Moved) -> Bool { front == .other && moved == .user }

    /// go: paste now. bringBack: raise the target once, then check again. clipboard: put it there, say so.
    enum Way: Equatable { case go, bringBack, clipboard }
    static func way(front: Front, targetAlive: Bool, moved: Moved = .unknown) -> Way {
        switch front {
        case .target: return targetAlive ? .go : .clipboard
        case .drafter: return targetAlive ? .bringBack : .clipboard
        case .other: return targetAlive && moved == .system ? .bringBack : .clipboard   // he moved there: leave him
        case .none: return .clipboard
        }
    }
    /// The same from Capture.targetWhyNot's answer (nil: the target holds the keys and has a field).
    static func way(why: String?, targetAlive: Bool, moved: Moved = .unknown) -> Way {
        guard let why else { return .go }
        if why == "front app moved (Drafter)" { return way(front: .drafter, targetAlive: targetAlive) }
        if why == "front app moved" { return way(front: .other, targetAlive: targetAlive, moved: moved) }
        return .clipboard
    }
    /// A panel or window closing: is its target raised again? Only over Drafter itself.
    static func mayRaise(front: Front, targetAlive: Bool) -> Bool { way(front: front, targetAlive: targetAlive) == .bringBack }

    /// After the paste: nil when it went where it was meant to, else why not.
    static func landed(target: Int32, keyApp: Int32?, windowsBefore: Int, windowsAfter: Int, field: Bool) -> String? {
        if keyApp != target { return "the front app changed during the paste" }
        if windowsAfter < windowsBefore { return "a window closed during the paste" }
        if !field { return "the field is gone" }
        return nil
    }

    /// The pill when the front app is not the one he started in.
    static func movedPill(front: String?, target: String?, what: String = "On the clipboard") -> String {
        guard let f = front, !f.isEmpty, let o = target, !o.isEmpty, f != o else { return "\(what) · ⌘V to paste" }
        return "\(f) is in front, not \(o) · \(what.prefix(1).lowercased() + what.dropFirst()), ⌘V to paste"
    }
    /// The pill when the check after a paste is unsure.
    static let unsurePill = "Not sure it went in · on the clipboard too, ⌘V to paste"

    // MARK: accessibility asks while a capture is up (17 November 2026, Andrii: "screenshots keep getting lost … I
    // think it's accessibility"). Setting AXEnhancedUserInterface on a Chromium or Electron app can reorder its windows
    // and move the focus; it is never asked while the capture overlay, the deck, a scrolling capture or the markup
    // panel is up. Electron gets AXManualAccessibility first and AXEnhancedUserInterface only if that gave no focus.
    static func mayAskAccessibility(captureUp: Bool) -> Bool { !captureUp }
    static func enhancedAtOnce(browser: Bool) -> Bool { browser }
}
