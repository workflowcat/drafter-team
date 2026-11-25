// What "this entity" becomes in the app he is in (proposal section 4), pure. Step 1 rows: Obsidian, mail, AI apps and
// plain fields; the others (Notion, Slack, Telegram @username, Docs chips) come with step 3. Never key events into a
// chat app's picker: Drafter only puts text.
import Foundation

enum RefRules {
    /// Where the text goes: "obsidian", "mail", "agent" (a coding agent), "ai" (a chat assistant), "chat" or "plain".
    static let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                            "com.microsoft.VSCode", "dev.zed.Zed", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"]
    static let agentTitle = try! NSRegularExpression(pattern: #"(?i)\b(claude|codex|gemini|aider)\b"#)
    static let agentApps = ["com.openai.codex"]

    /// "agent" for Claude Code, Codex and the like in a terminal or editor; nil otherwise (AppKind decides the rest).
    static func agent(_ id: String, title: String) -> Bool {
        if agentApps.contains(id) { return true }
        guard terminals.contains(id) else { return false }
        return agentTitle.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// The destination from the app's kind (AppKind.of) and bundle id.
    static func dest(id: String, title: String, kind: String) -> String {
        if agent(id, title: title) { return "agent" }
        if id == "md.obsidian" { return "obsidian" }
        if kind == "ai" || kind == "mail" || kind == "chat" { return kind }
        return "plain"
    }

    /// The pack level a destination gets by default: no pack in chats, mail and plain fields.
    static func level(_ dest: String, ai: Int = 2, agent: Int = 3) -> Int {
        dest == "agent" ? agent : dest == "ai" ? ai : 1
    }

    /// One way to put the entity in, for the card: (what the chip shows, what goes in).
    struct Form: Equatable { let label: String; let text: String }

    /// The card's forms, the reference for this destination first. `typed`: the name as he wrote it (the card: the
    /// canonical name). Contact-only cards never get a reference, only their addresses.
    static func forms(_ e: Entity, dest: String, typed: String? = nil) -> [Form] {
        let shown = typed ?? e.name
        var out: [Form] = []
        if !e.cardOnly {
            if dest == "obsidian", let t = e.targets?["obsidian"], !t.isEmpty {
                out.append(Form(label: "link", text: "[[\(t)|\(shown)]]"))
            }
            if dest == "mail", let m = e.handles?["email"]?.first ?? e.targets?["mail"] {
                out.append(Form(label: "name", text: shown))
                out.append(Form(label: "address", text: "\(e.name) <\(m)>"))
            }
            if out.isEmpty { out.append(Form(label: dest == "ai" || dest == "agent" ? "context" : "name", text: shown)) }
            else if !out.contains(where: { $0.text == shown }) { out.append(Form(label: "name", text: shown)) }
        }
        for (key, label) in [("email", "email"), ("tg", "Telegram"), ("phone", "phone")] {
            for v in e.handles?[key] ?? [] where !v.isEmpty {
                let text = key == "tg" ? "@" + v.trimmingCharacters(in: CharacterSet(charactersIn: "@")) : v
                if !out.contains(where: { $0.text == text }) { out.append(Form(label: label, text: text)) }
            }
        }
        if !e.cardOnly, dest != "obsidian", let t = e.targets?["obsidian"], !t.isEmpty, !out.contains(where: { $0.label == "link" }) {
            out.append(Form(label: "link", text: "[[\(t)|\(shown)]]"))
        }
        return out
    }
}
