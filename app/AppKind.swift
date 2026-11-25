// What kind of app a field is in (13 November 2026), for features that only make sense where a person will read the
// text. Proofread: a week of the live log (6-13 November) had 393 runs, 91% of them in the Claude app, where he writes a
// prompt to an AI that does not need clean spelling; 32 found a fix and 2 fixes were used. Pure: the app lists come
// from Keys (aiApps, chatApps, browsers, aiTitle), so this file compiles alone in tests.
import Foundation

enum AppKind {
    static let kinds = ["ai", "chat", "mail", "other"]
    static let mailApps = ["com.apple.mail", "com.superhuman.electron", "com.readdle.SparkDesktop", "com.readdle.smartemail-Mac",
                           "com.microsoft.Outlook", "com.mimestream.Mimestream", "com.google.Gmail"]
    static let mailTitle = try! NSRegularExpression(pattern: #"(?i)\b(gmail|inbox|outlook|superhuman|fastmail|proton mail)\b"#)

    /// "ai" (an assistant's box: its own app, or a browser tab titled ChatGPT, Claude…), "chat", "mail" or "other".
    static func of(_ id: String, title: String, ai: [String], chats: [String], browsers: [String], aiTitle: NSRegularExpression) -> String {
        if ai.contains(id) { return "ai" }
        if chats.contains(id) { return "chat" }
        if mailApps.contains(id) { return "mail" }
        if browsers.contains(id) {
            let all = NSRange(title.startIndex..., in: title)
            if aiTitle.firstMatch(in: title, range: all) != nil { return "ai" }
            if mailTitle.firstMatch(in: title, range: all) != nil { return "mail" }
        }
        return "other"
    }
}
