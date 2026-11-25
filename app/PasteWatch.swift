// Feeds the paste trail (PasteTrail.swift): a ⌘V the event tap sees (one line in Keys.swift) and Drafter's own pastes
// (Focus.paste). Kept: when, the app's identity, a hash of the clipboard's words. Never the text; never in a skipped
// app, a password field or under secure input; never Drafter's own window.
import AppKit
import Carbon

enum PasteWatch {
    static let url = Home.data.appendingPathComponent("paste-trail.jsonl")
    private static let queue = DispatchQueue(label: "drafter.paste-trail", qos: .utility)
    private static var recent: [PasteTrail.Paste] = []   // only on `queue`
    private static var written = 0

    /// ⌘V in another app (the event tap's thread): looked at on the main thread, written off it.
    static func keyPaste() { DispatchQueue.main.async { note(NSPasteboard.general.string(forType: .string)) } }
    /// Drafter put text in by pasting (Focus.paste).
    static func own(_ text: String) { DispatchQueue.main.async { note(text) } }

    static func note(_ text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              !Drafter.shared.settings.skip.contains(app.bundleIdentifier ?? ""), !IsSecureEventInputEnabled(), !passwordField(app) else { return }
        let p = PasteTrail.Paste(t: Date().timeIntervalSince1970, bundle: app.bundleIdentifier ?? "", app: app.localizedName ?? "", hash: PasteTrail.hash(text))
        queue.async {
            guard PasteTrail.add(p, to: url, recent: recent) else { return }
            recent.append(p); if recent.count > 20 { recent.removeFirst() }
            written += 1
            if written % 200 == 0 { PasteTrail.trim(url) }
        }
    }

    /// The focused element of `app` is a password field (asked with a short timeout).
    static func passwordField(_ app: NSRunningApplication) -> Bool {
        let a = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(a, 0.1)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXFocusedUIElementAttribute as CFString, &f) == .success, let el = f else { return false }
        let e = el as! AXUIElement
        var role: CFTypeRef?, sub: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &sub)
        return (sub as? String) == (kAXSecureTextFieldSubrole as String) || (role as? String) == "AXSecureTextField"
    }

    /// The trail since `since`, for the journal's build (off the main thread is fine: a read of one small file).
    static func read(since: Double) -> [PasteTrail.Paste] { PasteTrail.read(url, since: since) }
}
