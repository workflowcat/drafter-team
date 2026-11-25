// swiftc -parse-as-library app/PictureLookRules.swift tests/picture_look_rules.swift -o app/build/picture-look-rules-test && app/build/picture-look-rules-test
// Pictures round (24 November 2026): what a kept picture is, from its read text and Vision's labels. Made-up text only.
import Foundation

@main struct PictureLookRulesTest {
    static var failed = 0, ran = 0
    static func check(_ ok: Bool, _ what: String) { ran += 1; if !ok { failed += 1; print("FAIL:", what) } }
    static func main() {
        typealias R = PictureLookRules
        let code = "import Foundation\nfunc main() {\n    let x = load(\"a\")\n    return x\n}\nstruct Box {"
        check(R.kind(ocr: code, labels: ["document", "screenshot"]) == .code, "code")
        check(R.headline(code, kind: .code).hasPrefix("import Foundation"), "code headline: \(R.headline(code, kind: .code))")
        let term = "Last login: Mon on ttys001\nkit@mac ~ % git status\nOn branch main\nkit@mac ~ % ls"
        check(R.kind(ocr: term, labels: ["screenshot"]) == .terminal, "terminal")
        check(R.headline(term, kind: .terminal) == "git status", "terminal headline: \(R.headline(term, kind: .terminal))")
        let chat = "Sample Person\nare we still on for lunch\n12:41\nyes see you there soon\n12:43\ngreat"
        check(R.kind(ocr: chat, labels: ["screenshot"]) == .chat, "chat")
        let table = "Month Total\nJan 1,240\nFeb 1,310\nMar 1,505\nApr 1,620\nMay 1,880\nJun 2,040"
        check(R.kind(ocr: table, labels: ["document"]) == .table, "table")
        let prose = String(repeating: "This sample paragraph explains how the made up widget keeps its parts in order. ", count: 5)
            .replacingOccurrences(of: ". ", with: ".\n")
        check(R.kind(ocr: prose, labels: ["document"]) == .text, "text")
        check(R.kind(ocr: "", labels: ["people", "outdoor"]) == .photo, "photo")
        check(R.kind(ocr: "ok", labels: ["chart"]) == .chart, "chart")
        check(R.kind(ocr: "", labels: ["screenshot"]) == .screen, "blank screen")
        check(R.kind(ocr: "", labels: []) == .screen, "not named yet")
        let ui = "File Edit View\nInbox\nSettings\nThe weekly sample report is ready to read\nSend"
        check(R.kind(ocr: ui, labels: ["screenshot"]) == .screen, "screen")
        check(R.headline(ui, kind: .screen) == "The weekly sample report is ready to read", "screen headline")
        // lines
        check(R.line(kind: .photo, ocr: "", labels: ["people", "blue_sky", "screenshot"], size: "1200 × 1600") == "Photo · people, blue sky", "photo line")
        check(R.line(kind: .screen, ocr: "", labels: ["screenshot"], size: "900 × 703") == "Screen · 900 × 703", "size fallback")
        check(R.line(kind: .screen, ocr: ui, labels: [], size: "900 × 703") == "Screen · The weekly sample report is ready to read", "screen line")
        let long = String(repeating: "word ", count: 40)
        check(R.headline(long, kind: .screen).count <= 90, "cut at 90")
        check(!R.isTime("12:34 meeting") && R.isTime("9:05 PM"), "time")
        // search words and sidecar
        check(R.searchWords(kind: .code, labels: ["document"]).contains("code"), "search words")
        check(R.labels(sidecar: R.sidecar(labels: ["people", "outdoor"])) == ["people", "outdoor"], "sidecar round trip")
        check(R.labels(sidecar: R.sidecar(labels: [])) == [], "sidecar empty")
        check(R.labels(sidecar: "0\npeople\n") == nil, "old version made again")
        check(R.labels(sidecar: "") == nil, "missing")
        print("ran \(ran); failed: \(failed == 0 ? "" : String(failed))")
        if failed > 0 { exit(1) }
    }
}
