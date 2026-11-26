// Insert rules shared by every path that puts text or a picture into another app (insert audit, 23 November 2026,
// docs/inserts.md). Pure: no AppKit, no Accessibility; the hooks are Focus.insert, Focus.read, ShotSend.paste,
// Keys.accept and Autocorrect.switchLast. Tests: tests/insert_rules.swift.
import Foundation

enum InsertRules {
    static let marker = "⟦drafter-test⟧"

    // MARK: 1. an AX write, read back

    /// What the field holds after an AX write that the app said went in (Focus.insert).
    /// landed: exactly the old text with ours at the caret. unchanged: the same value as before, so nothing went in and
    /// a paste is the fallback. changed: the field changed some other way (the app reformatted our text: smart quotes,
    /// a capital, a link; or it echoed it late): the write went in, and a paste on top of it put the text in twice.
    /// unreadable: no value now (it had one before).
    enum AXWrite: Equatable { case landed, unchanged, changed, unreadable }
    static func afterAXWrite(old: String, caret: Int, before: String, text: String, now: String?) -> AXWrite {
        guard let now else { return .unreadable }
        let o = old as NSString, n = now as NSString, t = text as NSString
        if n.length == o.length + t.length, caret >= 0, caret <= n.length, n.substring(to: caret) == before { return .landed }
        if now == old { return .unchanged }
        return .changed
    }
    /// Focus.replace (the old words selected, then an AX write of the new ones): the write went in when the field now
    /// holds the new words or changed at all; only a field that reads exactly as before gets a paste over the selection.
    static func replacedByAX(old: String, new: String, now: String?) -> Bool {
        guard let now else { return false }
        return now.contains(new) || now != old
    }
    /// A paste follows an AX write only when the write left no trace (unchanged) or the field cannot be read.
    static func pasteAfterAX(_ w: AXWrite) -> Bool { w == .unchanged || w == .unreadable }

    // MARK: 2. apps nothing is ever put into

    /// Password managers, the keychain and the system's password prompts: no ghost, no paste, no AX write and no voice
    /// text, whatever the skip list says (voice reads the field with an empty skip list, so Terminal can take a take).
    static let never: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess",
        "com.apple.loginwindow", "com.apple.SecurityAgent",
    ]
    static func neverInto(_ bundle: String?) -> Bool { bundle.map { never.contains($0) } ?? false }

    // MARK: 3. steps of one put-in

    /// A put-in in several pastes (the capture deck: picture, caption, picture...; a picture then its text): each
    /// later paste goes only while the app that had the keys at the first one still has them, and never under secure
    /// input. Else it stops; what was left goes to the clipboard through the check after it (PutBack.check).
    static func stepMayGo(startPid: Int32?, keyPid: Int32?, ownPid: Int32, secure: Bool) -> Bool {
        guard !secure, let s = startPid, s > 0, s != ownPid, let k = keyPid else { return false }
        return k == s
    }

    // MARK: 4. what a Tab taken in a test field may leave behind

    /// The engine's /accept row (data/accepted.jsonl: the weekly kept-letters page, the dictionary's terms read it) is written only when the field holds no test marker: a test's Tab is never
    /// learned (AGENTS.md "Privacy for agents").
    static func logAccept(field: String) -> Bool { !field.contains(marker) }

    // MARK: 5. Shift Shift

    /// Shift Shift: the selection when the field has one (Focus.spot answers "selection" and gives no spot), else the
    /// last word, else only the keyboard. Anything that stopped the read before the selection (a skipped app, secure
    /// input, a password field, Drafter's own window) leaves the text alone.
    enum LayoutWay: Equatable { case selection, lastWord, keyboardOnly }
    static func layoutWay(spot: Bool, why: String, selection: Bool) -> LayoutWay {
        if spot { return .lastWord }
        return why == "selection" && selection ? .selection : .keyboardOnly
    }
}

/// The live insert check (scripts/insert_check.sh, app/InsertCheck.swift): where it may act and how a read-back reads.
/// Pure; tests in tests/insert_rules.swift.
enum InsertCheckRules {
    /// The only apps it acts in: a TextEdit document and local pages in Chrome and Safari it wrote itself. Never Notes
    /// (it syncs to the user's account), never a messaging app.
    static let targets: Set<String> = ["com.apple.TextEdit", "com.google.Chrome", "com.apple.Safari"]
    static func mayAct(front: String?, expected: String, field: String?) -> Bool {
        guard let f = front, f == expected, targets.contains(f), let field else { return false }
        return field.contains(InsertRules.marker)
    }
    /// Its folder: a fresh one in the temp folder, named drafter-insert-check-*.
    static func dirOK(_ path: String, tmp: String) -> Bool {
        let p = (path as NSString).standardizingPath, t = (tmp as NSString).standardizingPath
        return p.hasPrefix(t + "/") && (p as NSString).lastPathComponent.hasPrefix("drafter-insert-check-") && !p.contains("..")
    }
    /// ok: the line is in the field; nothing: the field is as it was; wrong text: it changed without the line.
    /// `changed`: a picture alone, where any change counts.
    static func verdict(before: String, after: String?, line: String, changed: Bool = false) -> String {
        guard let after else { return "nothing (field gone)" }
        if after == before { return "nothing" }
        if changed { return "ok" }
        let squash = { (s: String) in PutCheckRules.squash(s) }
        if squash(after).contains(squash(line)) {
            let extra = squash(after).count - squash(before).count - squash(line).count
            return extra > 0 ? "ok, but \(extra) more chars (twice?)" : "ok"
        }
        return "wrong text"
    }
}
