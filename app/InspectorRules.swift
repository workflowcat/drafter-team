// Live Screen Context & Status Inspector rules (pure Foundation, no AppKit/SwiftUI): translates runtime state and
// quiet reasons into clear human-readable status summaries, menu-bar lines, age formatting, and redacted previews.
// Screen context text stays in memory only: nothing here logs or writes to disk.
import Foundation

enum InspectorTone: String, Equatable {
    case ok, warn, muted
}

struct CachedScreenInfo: Equatable, Identifiable {
    let id: String
    let title: String
    let chars: Int
    let ageSec: Double
    let source: String
}

struct ScreenSnapshot: Equatable {
    var appName: String
    var bundleID: String
    var windowTitle: String
    var fieldRole: String
    var contextSource: String          // "ax", "ocr", "none"
    var contextChars: Int
    var contextAgeSec: Double?
    var contextText: String            // in-memory only
    var quietReason: String            // "ok", "paused", "typo hold", "secure input", "skipped app", "password field", "no caret rect", "mid-line", "asleep", "no focus", ...
    var pausedGlobal: Bool
    var pausedInField: Bool
    var engineReady: Bool
    var engineInfo: String
    var modelAsleep: Bool
    var secureHolder: String?
    var screenRecordingAllowed: Bool
    var accessibilityAllowed: Bool
    var lastGhostSrc: String
    var lastGhostMs: Int?
    var lastGhostAgeSec: Double?
    var cachedScreens: [CachedScreenInfo]

    init(
        appName: String = "",
        bundleID: String = "",
        windowTitle: String = "",
        fieldRole: String = "",
        contextSource: String = "none",
        contextChars: Int = 0,
        contextAgeSec: Double? = nil,
        contextText: String = "",
        quietReason: String = "ok",
        pausedGlobal: Bool = false,
        pausedInField: Bool = false,
        engineReady: Bool = true,
        engineInfo: String = "",
        modelAsleep: Bool = false,
        secureHolder: String? = nil,
        screenRecordingAllowed: Bool = true,
        accessibilityAllowed: Bool = true,
        lastGhostSrc: String = "",
        lastGhostMs: Int? = nil,
        lastGhostAgeSec: Double? = nil,
        cachedScreens: [CachedScreenInfo] = []
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.fieldRole = fieldRole
        self.contextSource = contextSource
        self.contextChars = contextChars
        self.contextAgeSec = contextAgeSec
        self.contextText = contextText
        self.quietReason = quietReason
        self.pausedGlobal = pausedGlobal
        self.pausedInField = pausedInField
        self.engineReady = engineReady
        self.engineInfo = engineInfo
        self.modelAsleep = modelAsleep
        self.secureHolder = secureHolder
        self.screenRecordingAllowed = screenRecordingAllowed
        self.accessibilityAllowed = accessibilityAllowed
        self.lastGhostSrc = lastGhostSrc
        self.lastGhostMs = lastGhostMs
        self.lastGhostAgeSec = lastGhostAgeSec
        self.cachedScreens = cachedScreens
    }
}

struct StatusSummary: Equatable {
    let tone: InspectorTone
    let headline: String
    let detail: String
}

enum InspectorRules {
    /// Translates technical states and quiet reasons into a single status summary, in strict priority order:
    /// Accessibility off -> Secure input held -> Globally paused -> Engine loading/asleep ->
    /// Paused in field (Esc Esc) -> Skipped app -> Password field -> Typo hold -> No caret rect ->
    /// No focus / mid-line / selection -> Active & ready.
    static func summarize(_ s: ScreenSnapshot) -> StatusSummary {
        let why = s.quietReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Accessibility off
        if !s.accessibilityAllowed {
            return StatusSummary(
                tone: .warn,
                headline: "Accessibility permission needed",
                detail: "Allow Drafter in System Settings › Privacy & Security › Accessibility to read fields and show suggestions."
            )
        }

        // 2. Secure input held
        if let holder = s.secureHolder, !holder.isEmpty {
            return StatusSummary(
                tone: .warn,
                headline: "Secure input held by \(holder)",
                detail: "macOS hides keystrokes while secure input is active. Click out of the password field or reload \(holder)."
            )
        }
        if why == "secure input" {
            return StatusSummary(
                tone: .warn,
                headline: "Secure input is active",
                detail: "macOS hides keystrokes while a password field or secure prompt holds secure input."
            )
        }

        // 3. Globally paused
        if s.pausedGlobal || why == "paused" {
            return StatusSummary(
                tone: .muted,
                headline: "Drafter is paused",
                detail: "Typing suggestions are paused globally. Click Resume or use the menu bar to turn them back on."
            )
        }

        // 4. Engine loading / stopped / asleep
        if !s.engineReady {
            let info = s.engineInfo.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = info.lowercased()
            let failed = lower.contains("cannot") || lower.contains("stopping") || lower.contains("stopped")
            return StatusSummary(
                tone: failed ? .warn : .muted,
                headline: failed ? "Engine not running" : "Engine loading",
                detail: info.isEmpty ? "Starting the local text model on this Mac." : info
            )
        }
        if s.modelAsleep || why == "asleep" {
            return StatusSummary(
                tone: .muted,
                headline: "Text model asleep",
                detail: "Idle sleep keeps memory free. Typing in any field wakes the model automatically."
            )
        }

        // 5. Paused in field via Esc Esc
        if s.pausedInField || why == "paused in field" {
            return StatusSummary(
                tone: .muted,
                headline: "Paused in this field",
                detail: "Suggestions were paused here with Esc Esc. Press Esc twice again in this field to resume."
            )
        }

        // 6. Skipped app
        if why == "skipped app" {
            let who = s.appName.isEmpty ? (s.bundleID.isEmpty ? "this app" : s.bundleID) : s.appName
            return StatusSummary(
                tone: .muted,
                headline: "Skipped app",
                detail: "Drafter is set to stay quiet in \(who)."
            )
        }

        // 7. Password field
        if why == "password field" {
            return StatusSummary(
                tone: .muted,
                headline: "Password field",
                detail: "Drafter never reads or suggests inside password fields."
            )
        }

        // 8. Typo hold
        if why == "typo hold" {
            return StatusSummary(
                tone: .muted,
                headline: "Quiet · typo hold",
                detail: "Holding suggestions while the word being typed looks like a typo."
            )
        }

        // 9. No caret rect
        if why == "no caret rect" {
            let who = s.appName.isEmpty ? "This app" : s.appName
            return StatusSummary(
                tone: .warn,
                headline: "No caret position",
                detail: "\(who) did not report the cursor rectangle for this field, so grey text cannot anchor cleanly."
            )
        }

        // 10. Mid-line, selection, no focus / non-text field
        if why == "mid-line" {
            return StatusSummary(
                tone: .muted,
                headline: "Quiet · mid-line",
                detail: "Caret is in the middle of a line with text after it."
            )
        }
        if why == "selection" {
            return StatusSummary(
                tone: .muted,
                headline: "Quiet · text selected",
                detail: "Suggestions pause while text is selected."
            )
        }
        if why == "no focus" || why == "no app" || why == "own app" || why.hasPrefix("not text") {
            return StatusSummary(
                tone: .muted,
                headline: "No active text field",
                detail: "Focus an editable text field in another app to see live suggestions and screen context."
            )
        }

        // 11. Active & ready
        let src = sourceLabel(s.contextSource)
        let target = s.appName.isEmpty ? "any app" : s.appName
        let detail: String
        if s.contextChars > 0 {
            detail = "Watching \(target) · \(src) context (\(s.contextChars) chars, \(formatAge(s.contextAgeSec)))."
        } else {
            detail = "Watching \(target) · ready for typing suggestions."
        }
        return StatusSummary(tone: .ok, headline: "Active & ready", detail: detail)
    }

    /// Compact 1-line summary for the menu bar when Drafter is quiet or active.
    static func menuLine(_ s: ScreenSnapshot) -> String {
        let why = s.quietReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !s.accessibilityAllowed { return "Needs Accessibility" }
        if let holder = s.secureHolder, !holder.isEmpty { return "Secure input (\(holder))" }
        if why == "secure input" { return "Secure input active" }
        if s.pausedGlobal || why == "paused" { return "Paused" }
        if !s.engineReady {
            let info = s.engineInfo.trimmingCharacters(in: .whitespacesAndNewlines)
            return info.isEmpty ? "Engine loading" : "Engine: \(info)"
        }
        if s.modelAsleep || why == "asleep" { return "Model asleep · wakes on typing" }
        if s.pausedInField || why == "paused in field" { return "Paused in field (Esc Esc)" }
        if why == "skipped app" { return s.appName.isEmpty ? "Quiet · skipped app" : "Skipped · \(s.appName)" }
        if why == "password field" { return "Quiet · password field" }
        if why == "typo hold" { return "Quiet · typo hold" }
        if why == "no caret rect" { return s.appName.isEmpty ? "Quiet · no caret rect" : "\(s.appName) · no caret rect" }
        if why == "mid-line" { return "Quiet · mid-line" }
        if why == "selection" { return "Quiet · selection" }
        if why == "no focus" || why == "no app" || why == "own app" || why.hasPrefix("not text") { return "Quiet · no text field" }

        let src = sourceLabel(s.contextSource)
        if !s.appName.isEmpty {
            return s.contextChars > 0 ? "\(s.appName) · \(src) (\(s.contextChars) ch)" : "\(s.appName) · \(src)"
        }
        return "Active · \(src)"
    }

    /// Human-readable label for a context source tag.
    static func sourceLabel(_ src: String) -> String {
        switch src.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ax": return "Accessibility"
        case "ocr": return "Screen OCR"
        default: return "None"
        }
    }

    /// Compact relative age label: "just now", "12 s ago", "3 min ago", "2 h ago", or "-".
    static func formatAge(_ sec: Double?) -> String {
        guard let sec, sec.isFinite else { return "-" }
        let s = max(0, Int(sec.rounded()))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        let m = s / 60
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        return "\(h) h ago"
    }

    /// Chooses the active in-memory context for `bundleID` without leaking OCR or AX text from a different app.
    static func selectContext(
        bundleID: String,
        ocrBundle: String,
        ocrText: String,
        ocrAgeSec: Double?,
        axMatchesSpot: Bool,
        axText: String,
        axAgeSec: Double?,
        cachedAXText: String,
        cachedAXAgeSec: Double?
    ) -> (source: String, text: String, ageSec: Double?) {
        let hasMatchingOCR = !bundleID.isEmpty && !ocrText.isEmpty && ocrBundle == bundleID
        let hasMatchingAX = axMatchesSpot && !axText.isEmpty
        if hasMatchingOCR {
            if hasMatchingAX, axText != ocrText, (axAgeSec ?? .infinity) < (ocrAgeSec ?? .infinity) {
                return ("ax", axText, axAgeSec)
            }
            return ("ocr", ocrText, ocrAgeSec)
        }
        if hasMatchingAX {
            return ("ax", axText, axAgeSec)
        }
        if axMatchesSpot && !cachedAXText.isEmpty {
            return ("ax", cachedAXText, cachedAXAgeSec)
        }
        return ("none", "", nil)
    }

    /// Enforces privacy invariants on a live snapshot:
    /// - Under secure input, skipped app, password field, or global pause: clears screen text, context metadata,
    ///   and warm screens (plus window title on skipped/secure/password targets).
    /// - Filters any warm screen belonging to a skipped bundle even while active in another app.
    static func redact(_ s: ScreenSnapshot, skippedBundles: Set<String> = []) -> ScreenSnapshot {
        var out = s
        let why = s.quietReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isSkipped = why == "skipped app" || (!s.bundleID.isEmpty && skippedBundles.contains(s.bundleID))
        let isSecure = why == "secure input" || !(s.secureHolder ?? "").isEmpty
        let isPassword = why == "password field" || s.fieldRole == "AXSecureTextField"
        let isPaused = s.pausedGlobal || why == "paused"

        if isSkipped || isSecure || isPassword || isPaused {
            out.contextSource = "none"
            out.contextChars = 0
            out.contextAgeSec = nil
            out.contextText = ""
            out.cachedScreens = []
            if isSkipped || isSecure || isPassword {
                out.windowTitle = ""
            }
            return out
        }

        if !skippedBundles.isEmpty {
            out.cachedScreens = s.cachedScreens.filter { item in
                !skippedBundles.contains { bundle in
                    !bundle.isEmpty && (
                        item.title == bundle ||
                        item.title.hasPrefix(bundle + " · ") ||
                        item.title.hasPrefix(bundle + "|") ||
                        item.id == bundle ||
                        item.id.hasPrefix(bundle + " · ") ||
                        item.id.hasPrefix("ax::" + bundle)
                    )
                }
            }
        }
        return out
    }

    /// Redacted character/word-count preview when screen context is masked (never leaks characters of `text`).
    static func maskText(_ text: String, lines: Int = 6) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "0 lines · 0 chars (no screen context in memory)" }
        let rawLines = trimmed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let lineCount = max(1, rawLines.count)
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        let lineWord = lineCount == 1 ? "1 line" : "\(lineCount) lines"
        let wordsLabel = wordCount == 1 ? "1 word" : "\(wordCount) words"
        let header = "\(lineWord) · \(trimmed.count) chars · \(wordsLabel) (hidden — click Show to inspect in memory)"
        guard lines > 0 else { return header }
        let bars = rawLines.prefix(lines).map { line -> String in
            let width = min(24, max(4, line.count / 3))
            return String(repeating: "•", count: width)
        }
        let extra = rawLines.count > lines ? ["… +\(rawLines.count - lines) more"] : []
        return ([header] + bars + extra).joined(separator: "\n")
    }
}
