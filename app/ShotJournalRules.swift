// The screenshot tool, journal side (15 November 2026; design: docs/research/2026-11-15-screenshot-tool.md, "Journal"):
// what a shot's card and row say and which keys it has. Pure (Foundation only, with ShotPackRules.swift), tested in
// tests/shot_journal_rules.swift. Reading the pack, drawing and the actions: app/ShotJournal.swift, Stream,
// JournalModel.
import Foundation

enum ShotJournalRules {
    /// A shot id from a history row is safe to put in a path: 1-64 letters, digits and "-", never "." or "/".
    static func validId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }

    /// Text on one line: lines joined with a space, spaces folded.
    static func flat(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The card's (and the row's) line: the note, else what the row says now (the picture's size line).
    static func cardLine(_ p: ShotPack?, fallback: String) -> String {
        let n = flat(p?.note ?? "")
        return n.isEmpty ? fallback : n
    }

    /// Marks that point at something: every mark except a blur (a blur hides, it does not point).
    static func markCount(_ p: ShotPack) -> Int { p.pics.flatMap(\.marks).filter { $0.kind != "blur" }.count }
    /// How many pictures the shot holds (a set: several captures handed off together); the card shows the first and,
    /// past one, this count beside an image glyph.
    static func pictureText(_ p: ShotPack) -> String { p.count > 1 ? String(p.count) : "" }
    /// The count as the card draws it in its small ring: "" for none, "9+" past nine.
    static func markText(_ n: Int) -> String { n <= 0 ? "" : n > 9 ? "9+" : String(n) }

    /// Where it went last (the newest hand-off), nil when never passed on. `field` (put in) counts.
    static func lastSent(_ p: ShotPack) -> ShotSent? { p.sent.max { $0.t < $1.t } }
    /// The word on hover beside the sent mark: "Claude", "File · Screenshot … .png".
    static func sentWord(_ p: ShotPack) -> String? {
        guard let s = lastSent(p) else { return nil }
        let d = s.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? s.to.word : s.to.word + " · " + d
    }

    /// The answer's first lines for the card: blank lines dropped, Markdown heads and list marks taken off, at most
    /// `max` lines. [] when there is no answer.
    static func answerLines(_ answer: String?, max: Int = 2) -> [String] {
        guard let a = answer else { return [] }
        var out: [String] = []
        for raw in a.split(whereSeparator: \.isNewline) {
            var l = raw.trimmingCharacters(in: .whitespaces)
            while let f = l.first, "#>*-".contains(f) { l.removeFirst(); l = l.trimmingCharacters(in: .whitespaces) }
            if l.hasPrefix("```") || l.isEmpty { continue }
            out.append(flat(l))
            if out.count >= max { break }
        }
        return out
    }

    /// What the journal search reads for a shot besides the picture's own read text: the note, the marks' words, the
    /// window title and the answer. Lines, the note first (it is the title the search marks).
    static func searchText(_ p: ShotPack) -> String {
        var parts = [p.note.trimmingCharacters(in: .whitespacesAndNewlines)] + (p.count > 1 ? p.captions : [])
        parts += p.pics.flatMap(\.marks).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        parts.append(p.window)
        parts.append(p.answer ?? "")
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: the row's keys

    enum Act: String { case send, insert, copyAgent, markUp, showFile, pin, delete }
    struct Spec: Equatable { let key: String; let word: String; let tip: String; let act: Act }

    /// A shot row's actions in the reader's order (the open row and the right-click menu show the same). Its ⌘E is
    /// Mark up again (Pick parts stays for other pictures), its ⌘C copies the picture with the text an agent reads.
    static func actions(pinned: Bool) -> [Spec] {
        [Spec(key: "⇥", word: "Send to…", tip: "the send-to list again: Clipboard, File, Claude, Codex, Claude Code, Ask, Person", act: .send),
         Spec(key: "⌘↵", word: "Insert", tip: "into the app you came from", act: .insert),
         Spec(key: "⌘C", word: "Copy for agent", tip: "the picture and its text (note, marks with pixels, the path) on the clipboard", act: .copyAgent),
         Spec(key: "⌘E", word: "Mark up again", tip: "the marks again over the first picture; the shot is kept", act: .markUp),
         Spec(key: "⌘O", word: "Show file", tip: "shot.png in Finder", act: .showFile),
         Spec(key: "⌘P", word: pinned ? "Unpin" : "Pin", tip: pinned ? "take it off the top of the Quick panel" : "keep it on top of the Quick panel", act: .pin),
         Spec(key: "⌘⌫", word: "Delete", tip: "out of the journal and the history; ⌘Z Undo within 8 seconds; the shot's folder stays", act: .delete)]
    }

    /// ⇥ on a row sends a shot again only from the list (not the search field, the sidebar, the reader or the
    /// editor) and with one item chosen; elsewhere ⇥ moves between the panes as before.
    static func tabSends(isShot: Bool, inList: Bool, picked: Int) -> Bool { isShot && inList && picked <= 1 }

    /// A marked shot adds a second picture row with the same shot id: of the rows of one shot only the newest stays
    /// (indices kept, in order). Rows without a shot always stay.
    static func newestPerShot(_ rows: [(shot: String, when: Double)]) -> [Int] {
        var newest: [String: Int] = [:]
        for (i, r) in rows.enumerated() where !r.shot.isEmpty {
            if let j = newest[r.shot], rows[j].when > r.when { continue }
            newest[r.shot] = i
        }
        return rows.indices.filter { rows[$0].shot.isEmpty || newest[rows[$0].shot] == $0 }
    }
}
