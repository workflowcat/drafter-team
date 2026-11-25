// swiftc -parse-as-library app/NotePreviewRules.swift tests/note_preview_rules.swift -o app/build/note-preview-test && app/build/note-preview-test
import Foundation

@main struct NotePreviewChecks {
    static var failures = 0
    static var checks = 0
    static func check(_ ok: Bool, _ message: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: " + message) }
    }
    static func main() {
        typealias R = NotePreviewRules
        func preview(_ points: [String] = [], _ mine: String = "", _ turns: [String] = [], limit: Int = 3) -> [String] {
            R.recordingPreviewLines(points: points, mine: mine, turns: turns.map { ("Speaker", $0) }, maxLines: limit)
        }
        check(preview([" First decision ", "- Next step", "", "Third point", "Fourth point"], "Own notes", ["A transcript line"]) ==
              ["First decision", "Next step", "Third point"], "summary wins, empty rows and markers removed, capped at three")
        check(preview(["\n\t"], "\n# Plan\n\n- Check the sample\n• Keep it local\n", ["Transcript backup"]) ==
              ["Plan", "Check the sample", "Keep it local"], "notes fallback handles markdown and blanks")
        check(preview([], "", [" ", "um", "Okay", "We agreed on a sample.", "Send the sample tomorrow."]) ==
              ["We agreed on a sample.", "Send the sample tomorrow."], "prefer meaningful transcript turns")
        check(preview([], "", ["um", "Yes"]) == ["um", "Yes"], "one-word-only takes remain visible")
        check(preview([], "", ["Um, uh.", "Okay, yeah.", "The sample is ready."]) == ["The sample is ready."], "filler phrases give way to content")
        check(preview([], "  hello  ") == ["hello"], "single word note remains visible")
        check(preview([], "", ["\n One meaningful line\nAnother useful line \n"]) ==
              ["One meaningful line", "Another useful line"], "split multiline turns")
        check(preview(["One", "Two"], limit: 1) == ["One"], "custom line limit")
        check(preview(["One"], limit: 0).isEmpty && preview(["One"], limit: -1).isEmpty, "nonpositive limit")
        check(preview().isEmpty && preview([" "], "\t", ["\n"]).isEmpty, "empty sources")
        for text in ["```", "```\n```", "-", "#", "•", "🙂", "こんにちは", "0"] {
            check(!preview([], text).isEmpty, "nonempty unusual note has preview")
            check(!preview([], "", [text]).isEmpty, "nonempty unusual transcript has preview")
        }
        check(R.recordingBadges(hasVideo: true, shotCount: 12, todoCount: 4, app: "Zoom") ==
              ["Video", "12 shots", "4 to-dos"], "video badges")
        check(R.recordingBadges(hasVideo: false, shotCount: 0, todoCount: 4, app: " Google  Meet ") ==
              ["Google Meet", "4 to-dos"], "app fallback normalized")
        check(R.recordingBadges(hasVideo: false, shotCount: 1, todoCount: 1, app: "") ==
              ["1 shot", "1 to-do"], "singular badges")
        check(R.recordingBadges(hasVideo: false, shotCount: -1, todoCount: -3, app: "\n").isEmpty, "no empty or negative badges")
        for n in [-1, 0, 1, 17, 30, 31, Int.max] {
            check(R.shouldAutoExpandSparse(totalItems: n) == (n > 0 && n <= 30), "sparse boundary \(n)")
        }
        check(R.shouldAutoExpandSparse(totalItems: 2, maxSparse: 2), "custom sparse threshold inclusive")
        check(!R.shouldAutoExpandSparse(totalItems: 1, maxSparse: 0), "zero sparse threshold")
        check(!R.shouldAutoExpandSparse(totalItems: 1, maxSparse: -1), "negative sparse threshold")

        let md = "# Title\n## Section\n### Detail\n\n- First\n• Second\n12. Third\n\nA paragraph\ncontinued here.\n\n```swift\nlet x = 1\n  # literal\n\n```\nAfter code."
        check(R.parseMarkdownBlocks(md) == [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Section"),
            .heading(level: 3, text: "Detail"), .bullet(text: "First"), .bullet(text: "Second"), .bullet(text: "Third"),
            .paragraph(text: "A paragraph\ncontinued here."), .code(text: "let x = 1\n  # literal\n"), .paragraph(text: "After code.")], "all block types and preserved code whitespace")
        check(R.parseMarkdownBlocks("\r\n # Title\r\n\r\n- One\r\n") == [.heading(level: 1, text: "Title"), .bullet(text: "One")], "CRLF and indentation")
        check(R.parseMarkdownBlocks("a\rb") == [.paragraph(text: "a\nb")], "CR newlines")
        check(R.parseMarkdownBlocks("```\n  unfinished\n- still code") == [.code(text: "  unfinished\n- still code")], "unclosed code fence")
        check(R.parseMarkdownBlocks("````text\n```\n````") == [.code(text: "```")], "long fence contains short fence")
        check(R.parseMarkdownBlocks("```\n```oops\n```") == [.code(text: "```oops")], "closing fence needs no trailing text")
        check(R.parseMarkdownBlocks("#hashtag\n#### Four\n1.2 decimal\n-\n•\n1.\n<script>literal</script>") ==
              [.paragraph(text: "#hashtag\n#### Four\n1.2 decimal\n-\n•\n1.\n<script>literal</script>")], "unsupported syntax stays literal")
        check(R.parseMarkdownBlocks(" \n\t").isEmpty, "empty markdown")
        check(R.parseMarkdownBlocks("```\n```") == [.code(text: "")], "empty fenced block")
        check(R.parseMarkdownBlocks("Text\n- Bullet\nTail") == [.paragraph(text: "Text"), .bullet(text: "Bullet"), .paragraph(text: "Tail")], "adjacent block transitions")
        let heading = R.noteHeadlineAndPreview("\n# Sample plan\n\nA body.\n\n- A step\n")
        check(heading.headline == "Sample plan" && heading.body == "A body.\n\nA step", "heading extracted without markers")
        let plain = R.noteHeadlineAndPreview("Sample plan\n\nA body.")
        check(plain.headline == "Sample plan" && plain.body == "A body.", "clear plain title")
        check(R.noteHeadlineAndPreview("# Title only").headline == "Title only" && R.noteHeadlineAndPreview("# Title only").body.isEmpty, "heading only")
        for text in ["One line", "First sentence.\nNext line", "- A bullet\n- A second", "https://example.org\nA link", "```\ncode\n```", "#### Not a heading\nBody"] {
            check(R.noteHeadlineAndPreview(text).headline == nil, "ordinary text must not invent a title")
        }
        check(R.noteHeadlineAndPreview("").body.isEmpty, "empty headline preview")
        let long = String(repeating: "word ", count: 40) + "\nBody"
        check(R.noteHeadlineAndPreview(long).headline == nil, "long first line remains body")
        let bulk = String(repeating: "# Heading\n\nParagraph text.\n- Bullet\n```\ncode\n```\n", count: 2000)
        check(R.parseMarkdownBlocks(bulk).count == 8000, "large local note parsed completely")
        print("note preview rules: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
