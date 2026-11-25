// swiftc -parse-as-library app/InspectorRules.swift tests/inspector_rules.swift -o app/build/inspector-rules-test && app/build/inspector-rules-test
import Foundation

@main
struct InspectorRulesChecks {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        if !ok {
            print("FAIL: " + what)
            failures += 1
        }
    }

    static func base() -> ScreenSnapshot {
        ScreenSnapshot(
            appName: "Beeper",
            bundleID: "com.automattic.beeper.desktop",
            windowTitle: "Team Chat",
            fieldRole: "AXTextArea",
            contextSource: "ocr",
            contextChars: 240,
            contextAgeSec: 8,
            contextText: "Synthetic line one\nSynthetic line two",
            quietReason: "ok",
            pausedGlobal: false,
            pausedInField: false,
            engineReady: true,
            engineInfo: "qwen · 2.1 GB · 420 words",
            modelAsleep: false,
            secureHolder: nil,
            screenRecordingAllowed: true,
            accessibilityAllowed: true,
            lastGhostSrc: "model",
            lastGhostMs: 38,
            lastGhostAgeSec: 12,
            cachedScreens: []
        )
    }

    static func main() {
        testSummarizePriority()
        testSummarizeQuietReasons()
        testMenuLine()
        testSourceLabel()
        testFormatAge()
        testMaskText()
        testPrivacySelectContextAndRedact()
        if failures > 0 {
            print("\(failures) failed")
            exit(1)
        }
        print("inspector rules: all passed")
    }

    static func testSummarizePriority() {
        // 1. Accessibility off beats everything else (secure input, paused, engine down)
        var s = base()
        s.accessibilityAllowed = false
        s.secureHolder = "1Password"
        s.pausedGlobal = true
        s.engineReady = false
        let r1 = InspectorRules.summarize(s)
        check(r1.tone == .warn && r1.headline.contains("Accessibility"), "accessibility off is highest priority -> \(r1)")

        // 2. Secure input held beats globally paused and engine loading
        s = base()
        s.secureHolder = "Safari"
        s.pausedGlobal = true
        s.engineReady = false
        let r2 = InspectorRules.summarize(s)
        check(r2.tone == .warn && r2.headline.contains("Safari"), "secure holder beats paused/engine -> \(r2)")

        // 2b. Secure input via quietReason without holder name
        s = base()
        s.quietReason = "secure input"
        s.pausedGlobal = true
        let r2b = InspectorRules.summarize(s)
        check(r2b.tone == .warn && r2b.headline.lowercased().contains("secure input"), "secure input reason beats paused -> \(r2b)")

        // 3. Globally paused beats engine loading / asleep / field pause
        s = base()
        s.pausedGlobal = true
        s.engineReady = false
        s.modelAsleep = true
        s.pausedInField = true
        let r3 = InspectorRules.summarize(s)
        check(r3.tone == .muted && r3.headline.lowercased().contains("paused"), "global pause beats engine/asleep/field pause -> \(r3)")

        // 4a. Engine loading beats model asleep and field pause
        s = base()
        s.engineReady = false
        s.engineInfo = "loading model"
        s.modelAsleep = true
        s.pausedInField = true
        let r4a = InspectorRules.summarize(s)
        check(r4a.tone == .muted && r4a.headline == "Engine loading" && r4a.detail == "loading model", "engine loading -> \(r4a)")

        // 4b. Engine error / stopped shows warn
        s = base()
        s.engineReady = false
        s.engineInfo = "engine keeps stopping, see data/engine.log"
        let r4b = InspectorRules.summarize(s)
        check(r4b.tone == .warn && r4b.headline == "Engine not running", "engine error is warn -> \(r4b)")

        // 4c. Model asleep beats paused in field and skipped app
        s = base()
        s.modelAsleep = true
        s.pausedInField = true
        s.quietReason = "skipped app"
        let r4c = InspectorRules.summarize(s)
        check(r4c.tone == .muted && r4c.headline.lowercased().contains("asleep"), "model asleep beats field pause -> \(r4c)")

        // 5. Paused in field (Esc Esc) beats skipped app / password / typo hold
        s = base()
        s.pausedInField = true
        s.quietReason = "typo hold"
        let r5 = InspectorRules.summarize(s)
        check(r5.tone == .muted && r5.headline.contains("Paused in this field"), "paused in field beats quiet reasons -> \(r5)")
    }

    static func testSummarizeQuietReasons() {
        // 6. Skipped app
        var s = base()
        s.quietReason = "skipped app"
        let r6 = InspectorRules.summarize(s)
        check(r6.tone == .muted && r6.headline == "Skipped app" && r6.detail.contains("Beeper"), "skipped app -> \(r6)")

        // 7. Password field
        s = base()
        s.quietReason = "password field"
        let r7 = InspectorRules.summarize(s)
        check(r7.tone == .muted && r7.headline == "Password field", "password field -> \(r7)")

        // 8. Typo hold
        s = base()
        s.quietReason = "typo hold"
        let r8 = InspectorRules.summarize(s)
        check(r8.tone == .muted && r8.headline.lowercased().contains("typo hold"), "typo hold -> \(r8)")

        // 9. No caret rect
        s = base()
        s.quietReason = "no caret rect"
        let r9 = InspectorRules.summarize(s)
        check(r9.tone == .warn && r9.headline.lowercased().contains("caret"), "no caret rect -> \(r9)")

        // 10a. Mid-line
        s = base()
        s.quietReason = "mid-line"
        let r10a = InspectorRules.summarize(s)
        check(r10a.tone == .muted && r10a.headline.lowercased().contains("mid-line"), "mid-line -> \(r10a)")

        // 10b. Selection
        s = base()
        s.quietReason = "selection"
        let r10b = InspectorRules.summarize(s)
        check(r10b.tone == .muted && r10b.headline.lowercased().contains("selected"), "selection -> \(r10b)")

        // 10c. No focus & not text
        for why in ["no focus", "no app", "own app", "not text: AXButton"] {
            s = base()
            s.quietReason = why
            let r = InspectorRules.summarize(s)
            check(r.tone == .muted && r.headline == "No active text field", "\(why) -> \(r)")
        }

        // 11. Active & ready (with context and without context)
        s = base()
        let r11 = InspectorRules.summarize(s)
        check(r11.tone == .ok && r11.headline == "Active & ready" && r11.detail.contains("Beeper") && r11.detail.contains("Screen OCR"), "active with ocr -> \(r11)")

        s = base()
        s.contextSource = "none"
        s.contextChars = 0
        let r11b = InspectorRules.summarize(s)
        check(r11b.tone == .ok && r11b.headline == "Active & ready" && r11b.detail.contains("ready for typing"), "active without context -> \(r11b)")
    }

    static func testMenuLine() {
        var s = base()
        check(InspectorRules.menuLine(s) == "Beeper · Screen OCR (240 ch)", "active menuLine -> \(InspectorRules.menuLine(s))")

        s = base(); s.accessibilityAllowed = false
        check(InspectorRules.menuLine(s) == "Needs Accessibility", "accessibility menuLine")

        s = base(); s.secureHolder = "Chrome"
        check(InspectorRules.menuLine(s) == "Secure input (Chrome)", "secure menuLine")

        s = base(); s.pausedGlobal = true
        check(InspectorRules.menuLine(s) == "Paused", "paused menuLine")

        s = base(); s.engineReady = false; s.engineInfo = "loading model"
        check(InspectorRules.menuLine(s) == "Engine: loading model", "engine menuLine")

        s = base(); s.modelAsleep = true
        check(InspectorRules.menuLine(s) == "Model asleep · wakes on typing", "asleep menuLine")

        s = base(); s.pausedInField = true
        check(InspectorRules.menuLine(s) == "Paused in field (Esc Esc)", "field pause menuLine")

        s = base(); s.quietReason = "skipped app"
        check(InspectorRules.menuLine(s) == "Skipped · Beeper", "skipped menuLine")

        s = base(); s.quietReason = "password field"
        check(InspectorRules.menuLine(s) == "Quiet · password field", "password menuLine")

        s = base(); s.quietReason = "typo hold"
        check(InspectorRules.menuLine(s) == "Quiet · typo hold", "typo menuLine")

        s = base(); s.quietReason = "no caret rect"
        check(InspectorRules.menuLine(s) == "Beeper · no caret rect", "caret menuLine")

        s = base(); s.quietReason = "no focus"
        check(InspectorRules.menuLine(s) == "Quiet · no text field", "no focus menuLine")

        s = base(); s.appName = ""; s.contextSource = "ax"; s.contextChars = 0
        check(InspectorRules.menuLine(s) == "Active · Accessibility", "fallback active menuLine")
    }

    static func testSourceLabel() {
        check(InspectorRules.sourceLabel("ax") == "Accessibility", "ax label")
        check(InspectorRules.sourceLabel("AX") == "Accessibility", "AX case-insensitive")
        check(InspectorRules.sourceLabel("ocr") == "Screen OCR", "ocr label")
        check(InspectorRules.sourceLabel("none") == "None", "none label")
        check(InspectorRules.sourceLabel("") == "None", "empty label")
        check(InspectorRules.sourceLabel("unknown") == "None", "unknown label")
    }

    static func testFormatAge() {
        check(InspectorRules.formatAge(nil) == "-", "nil age")
        check(InspectorRules.formatAge(.nan) == "-", "nan age")
        check(InspectorRules.formatAge(-3) == "just now", "negative clock skew")
        check(InspectorRules.formatAge(0) == "just now", "0s age")
        check(InspectorRules.formatAge(4.4) == "just now", "4s age")
        check(InspectorRules.formatAge(5.0) == "5 s ago", "5s age")
        check(InspectorRules.formatAge(12.2) == "12 s ago", "12s age")
        check(InspectorRules.formatAge(59.0) == "59 s ago", "59s age")
        check(InspectorRules.formatAge(60.0) == "1 min ago", "60s age")
        check(InspectorRules.formatAge(180.0) == "3 min ago", "180s age")
        check(InspectorRules.formatAge(3600.0) == "1 h ago", "1h age")
        check(InspectorRules.formatAge(7500.0) == "2 h ago", "2h age")
    }

    static func testMaskText() {
        let empty = InspectorRules.maskText("")
        check(empty.contains("0 lines") && empty.contains("0 chars"), "empty mask -> \(empty)")

        let secret = "Alpha bravo charlie\nDelta echo foxtrot\nGolf hotel india\nJuliet kilo lima"
        let masked = InspectorRules.maskText(secret, lines: 6)
        check(masked.contains("4 lines"), "line count -> \(masked)")
        check(masked.contains("\(secret.count) chars"), "char count -> \(masked)")
        check(masked.contains("12 words"), "word count -> \(masked)")
        check(masked.contains("hidden — click Show to inspect in memory"), "hint present")
        for token in ["Alpha", "bravo", "Delta", "Golf", "Juliet", "lima"] {
            check(!masked.localizedCaseInsensitiveContains(token), "must not leak token \(token)")
        }

        let many = (1...10).map { "Synthetic line number \($0) here" }.joined(separator: "\n")
        let truncated = InspectorRules.maskText(many, lines: 3)
        check(truncated.contains("10 lines") && truncated.contains("+7 more"), "line limit truncates bars -> \(truncated)")
        check(!truncated.contains("Synthetic"), "truncated mask never leaks words")

        let headerOnly = InspectorRules.maskText(secret, lines: 0)
        check(!headerOnly.contains("\n") && headerOnly.contains("4 lines"), "lines=0 returns single summary line -> \(headerOnly)")
    }

    static func testPrivacySelectContextAndRedact() {
        // Other-app OCR must never bleed into the active app's context
        let otherOCR = InspectorRules.selectContext(
            bundleID: "com.apple.Notes",
            ocrBundle: "com.other.secret",
            ocrText: "Synthetic other-app text",
            ocrAgeSec: 2,
            axMatchesSpot: false,
            axText: "Stale AX text",
            axAgeSec: 1,
            cachedAXText: "Stale cached AX",
            cachedAXAgeSec: 1
        )
        check(otherOCR.source == "none" && otherOCR.text.isEmpty && otherOCR.ageSec == nil, "other-app OCR and unmatched AX must not bleed -> \(otherOCR)")

        // Empty active bundleID must not grab arbitrary OCR
        let emptyBundle = InspectorRules.selectContext(
            bundleID: "",
            ocrBundle: "com.other.app",
            ocrText: "Synthetic OCR",
            ocrAgeSec: 1,
            axMatchesSpot: false,
            axText: "",
            axAgeSec: nil,
            cachedAXText: "",
            cachedAXAgeSec: nil
        )
        check(emptyBundle.source == "none" && emptyBundle.text.isEmpty, "empty bundleID never grabs OCR -> \(emptyBundle)")

        // Matching bundle OCR works, and fresher matching AX wins over older OCR
        let matchingOCR = InspectorRules.selectContext(
            bundleID: "com.example.chat",
            ocrBundle: "com.example.chat",
            ocrText: "Synthetic OCR",
            ocrAgeSec: 5,
            axMatchesSpot: true,
            axText: "Older AX",
            axAgeSec: 10,
            cachedAXText: "",
            cachedAXAgeSec: nil
        )
        check(matchingOCR.source == "ocr" && matchingOCR.text == "Synthetic OCR", "matching OCR selected -> \(matchingOCR)")

        let fresherAX = InspectorRules.selectContext(
            bundleID: "com.example.chat",
            ocrBundle: "com.example.chat",
            ocrText: "Synthetic OCR",
            ocrAgeSec: 10,
            axMatchesSpot: true,
            axText: "Fresher AX",
            axAgeSec: 2,
            cachedAXText: "",
            cachedAXAgeSec: nil
        )
        check(fresherAX.source == "ax" && fresherAX.text == "Fresher AX", "fresher AX wins -> \(fresherAX)")

        // Redact skipped app, secure input, password field, and global pause
        let warmList = [
            CachedScreenInfo(id: "com.example.chat · Room", title: "com.example.chat · Room", chars: 120, ageSec: 3, source: "ocr"),
            CachedScreenInfo(id: "com.skipped.bank · Vault", title: "com.skipped.bank · Vault", chars: 80, ageSec: 5, source: "ocr"),
            CachedScreenInfo(id: "ax::com.skipped.bank · Note", title: "com.skipped.bank · Note", chars: 40, ageSec: 7, source: "ax"),
        ]

        var skippedSnap = base()
        skippedSnap.bundleID = "com.skipped.bank"
        skippedSnap.quietReason = "skipped app"
        skippedSnap.cachedScreens = warmList
        let rSkipped = InspectorRules.redact(skippedSnap, skippedBundles: ["com.skipped.bank"])
        check(rSkipped.contextText.isEmpty && rSkipped.contextChars == 0 && rSkipped.contextSource == "none", "skipped app clears context")
        check(rSkipped.windowTitle.isEmpty && rSkipped.cachedScreens.isEmpty, "skipped app clears title and warm screens")

        var secureSnap = base()
        secureSnap.secureHolder = "1Password"
        secureSnap.quietReason = "secure input"
        secureSnap.cachedScreens = warmList
        let rSecure = InspectorRules.redact(secureSnap, skippedBundles: [])
        check(rSecure.contextText.isEmpty && rSecure.windowTitle.isEmpty && rSecure.cachedScreens.isEmpty, "secure input clears context, title, and warm screens")

        var pwdSnap = base()
        pwdSnap.fieldRole = "AXSecureTextField"
        pwdSnap.quietReason = "password field"
        pwdSnap.cachedScreens = warmList
        let rPwd = InspectorRules.redact(pwdSnap, skippedBundles: [])
        check(rPwd.contextText.isEmpty && rPwd.windowTitle.isEmpty && rPwd.cachedScreens.isEmpty, "password field clears context, title, and warm screens")

        var pausedSnap = base()
        pausedSnap.pausedGlobal = true
        pausedSnap.quietReason = "paused"
        pausedSnap.cachedScreens = warmList
        let rPaused = InspectorRules.redact(pausedSnap, skippedBundles: [])
        check(rPaused.contextText.isEmpty && rPaused.contextChars == 0 && rPaused.cachedScreens.isEmpty, "global pause clears context and warm screens")

        // Active non-skipped app keeps its own context but filters skipped bundles from warm screens
        var activeSnap = base()
        activeSnap.cachedScreens = warmList
        let rActive = InspectorRules.redact(activeSnap, skippedBundles: ["com.skipped.bank"])
        check(rActive.contextText == activeSnap.contextText, "active app retains its own in-memory context")
        check(rActive.cachedScreens.count == 1 && rActive.cachedScreens[0].title == "com.example.chat · Room", "skipped bundles filtered from warm screens -> \(rActive.cachedScreens)")
    }
}
