import Foundation

// swiftc -parse-as-library app/ClipKindRules.swift app/ClipRules.swift tests/clip_kind_rules.swift -o app/build/clip-kind-rules-test && app/build/clip-kind-rules-test
// Clip kinds round (17 November 2026): picture types kept as given, several files, PDFs, tables, code languages,
// colour values and link titles from the copy itself. Made-up values only.
@main
struct ClipKindChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        kinds(); pictures(); files(); tables(); code(); colors(); notes(); links()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("clip kind rules: all passed")
    }

    static func kinds() {
        let k = ClipRules.kind
        check(k(["com.compuserve.gif"], nil) == .image, "a GIF is a picture")
        check(k(["org.webmproject.webp"], "") == .image, "a WebP is a picture")
        check(k(["com.adobe.pdf"], nil) == .image, "PDF data without text is a picture row")
        check(k(["com.adobe.pdf", "public.utf8-plain-text"], "page text") == .text, "PDF text selection stays text")
        check(k(["public.file-url", "com.adobe.pdf"], nil) == .file, "a PDF file is a file")
        let t = ClipKindRules.textShape
        check(t(["public.utf8-plain-text"], "#1E90FF", nil) == .color, "hex is a colour")
        check(t(["public.utf8-plain-text"], "a\tb\nc\td", nil) == .table, "cells by tab are a table")
        check(t(["public.utf8-plain-text"], "let x = 1\nfunc go() -> Int { x }", nil) == .code, "Swift is code")
        check(t(["public.rtf", "public.utf8-plain-text"], "Room 4.12, second floor", nil) == .rich, "RTF is formatted text")
        check(t(["public.utf8-plain-text"], "Room 4.12, second floor", nil) == nil, "plain text has no shape")
    }

    static func pictures() {
        let it = ClipKindRules.imageType
        check(it(["public.jpeg", "public.tiff"]) == "public.jpeg", "JPEG kept as JPEG")
        check(it(["public.tiff", "public.png"]) == "public.png", "TIFF added by AppKit loses to PNG")
        check(it(["public.tiff"]) == "public.tiff", "a TIFF alone stays TIFF")
        check(it(["public.html", "com.compuserve.gif", "public.png"]) == "com.compuserve.gif", "a GIF from a browser stays GIF")
        check(it(["public.utf8-plain-text"]) == nil, "no picture")
        check(ClipKindRules.ext(forType: "public.heic") == "heic" && ClipKindRules.ext(forType: "org.webmproject.webp") == "webp", "extensions")
        check(ClipKindRules.type(forName: "c-1f.jpg") == "public.jpeg", "jpg back to JPEG")
        check(ClipKindRules.type(forName: "c-1f.png") == "public.png", "old rows: png")
        check(ClipKindRules.type(forName: "c-1f.pboard") == nil, "a formatted copy is not a picture")
        check(ClipRules.clipName(Data([1, 2, 3]), ext: "gif").hasSuffix(".gif"), "the stored name keeps the type")
    }

    static func files() {
        check(ClipKindRules.fileShape(["/tmp/a.txt", "/tmp/b.txt"]) == .files, "two files")
        check(ClipKindRules.fileShape(["/tmp/Plan.PDF"]) == .pdf, "one PDF")
        check(ClipKindRules.fileShape(["/tmp/a.txt"]) == nil, "one file as before")
        check(ClipKindRules.filesLine(count: 3, bytes: 12_400_000) == "3 files · 12.4 MB", "summary with size")
        check(ClipKindRules.filesLine(count: 2, bytes: 0) == "2 files", "summary of folders")
        check(ClipKindRules.names(["/a/one.pdf", "/a/two.png", "/b/three.txt"], max: 2) == "one.pdf, two.png + 1 more", "names cut")
        check(ClipRules.searchExtra(.file, text: "/x/alpha.txt\n/x/beta.txt", title: "", ocr: "").contains("beta.txt"), "search finds every file's name")
    }

    static func tables() {
        let tsv = "Name\tCity\tAmount\nAnna\tLviv\t12\nBohdan\tKyiv\t7\nOlena\tDnipro\t30"
        check(ClipKindRules.tsvTable(tsv)! == (3, 4), "3 × 4 from tabs")
        check(ClipKindRules.tsvTable("one line\twith a tab") == nil, "one line is not a table")
        check(ClipKindRules.tsvTable("\tlet a = 1\n\tlet b = 2") == nil, "indented code is not a table")
        check(ClipKindRules.tsvTable("a sentence\nanother sentence") == nil, "lines without tabs")
        let html = "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr><tr><td>3</td><td>4</td></tr></table>"
        check(ClipKindRules.htmlTable(html)! == (2, 3), "2 × 3 from HTML")
        check(ClipKindRules.table(text: "A B 1 2 3 4", html: html)! == (2, 3), "HTML wins over the flat text")
        check(ClipKindRules.htmlTable("<p>no table</p>") == nil, "no table")
        check(ClipKindRules.tableLine(cols: 4, rows: 12) == "Table · 4 × 12", "table line")
        let c = ClipKindRules.cells(tsv, rows: 2, cols: 2, chars: 4)
        check(c == [["Name", "City"], ["Anna", "Lviv"]], "grid cells")
        check(ClipKindRules.cells("Averyveryverylongcell\tb", chars: 6)[0][0] == "Avery…", "a long cell is cut")
    }

    static func code() {
        let l = ClipKindRules.language
        let cases: [(String, String?)] = [
            ("import Foundation\nstruct Point { var x: Double }\nfunc len(_ p: Point) -> Double { p.x }", "Swift"),
            ("guard let u = url else { return }\nlet name = u.lastPathComponent", "Swift"),
            ("def total(rows):\n    return sum(r.amount for r in rows)\n\nprint(total([]))", "Python"),
            ("from pathlib import Path\nif __name__ == \"__main__\":\n    print(Path.cwd())", "Python"),
            ("const rows = items.map((x) => x.id);\nconsole.log(rows);", "JavaScript"),
            ("interface Row { id: number; name: string }\nconst rows: Row[] = [];", "TypeScript"),
            ("{\"name\": \"station\", \"floors\": [1, 2]}", "JSON"),
            ("SELECT name, city FROM people WHERE city = 'Lviv' ORDER BY name;", "SQL"),
            ("git commit -m \"plan\" && git push", "Shell"),
            ("#!/bin/zsh\ncd ~/work\nls -la", "Shell"),
            ("<div class=\"card\"><p>Hello</p></div>", "HTML"),
            (".card {\n  padding: 12px;\n  color: #333;\n}", "CSS"),
            ("package main\nimport \"fmt\"\nfunc main() {\n  x := 1\n  fmt.Println(x)\n}", "Go"),
            ("use std::fs;\nfn main() {\n    let mut n = 0;\n    println!(\"{}\", n);\n}", "Rust"),
            // prose with code words stays text
            ("Let me know if you can select a time from the list for the meeting.", nil),
            ("See you at the station at nine, I will bring the drawings.", nil),
            ("Room 4.12, second floor, the door on the left", nil),
            ("Go to the station and print the plan.", nil),
            ("1 250,50 EUR", nil),
        ]
        for (s, want) in cases {
            let got = l(s)
            check(got == want, "language of \"\(s.prefix(40))\": \(got ?? "nil"), want \(want ?? "nil")")
        }
        // a long text guessed in reasonable time
        let big = String(repeating: "let value = compute(input) ?? 0\n", count: 400)
        let t0 = Date(); _ = l(big)
        check(Date().timeIntervalSince(t0) < 0.2, "language guess under 200 ms on 4,000 characters")
    }

    static func colors() {
        let c = ClipKindRules.color
        check(c("#fff") == .init(r: 1, g: 1, b: 1, a: 1), "#fff")
        check(ClipKindRules.hex(c("#1e90ff")!) == "#1E90FF", "#1e90ff")
        check(ClipKindRules.hex(c("#1e90ff80")!) == "#1E90FF80", "hex with alpha")
        check(ClipKindRules.hex(c("rgb(255, 128, 0)")!) == "#FF8000", "rgb()")
        check(ClipKindRules.hex(c("rgba(0,0,0,0.5)")!) == "#00000080", "rgba()")
        check(ClipKindRules.hex(c("rgb(100% 0% 0%)")!) == "#FF0000", "rgb() in %")
        check(ClipKindRules.hex(c("hsl(120, 100%, 50%)")!) == "#00FF00", "hsl()")
        check(ClipKindRules.hex(c("hsl(240deg 100% 25%)")!) == "#000080", "hsl() with deg")
        check(c("#12345") == nil, "5 hex digits")
        check(c("#ghijkl") == nil, "not hex")
        check(c("rgb(300, 0, 0)") == nil, "out of range")
        check(c("the colour is #fff") == nil, "a sentence is not a colour")
        check(c("#4512") != nil, "#rgba short form")
    }

    static func notes() {
        check(ClipRules.note(["lang": "Swift"]) == "Swift", "note: language")
        check(ClipRules.note(["color": "#FF8000"]) == "#FF8000", "note: colour")
        check(ClipRules.note(["table": [4, 12]]) == "4 × 12", "note: table")
        check(ClipRules.note(["page": [595, 842, 3]]) == "3 pages", "note: PDF pages")
        check(ClipRules.note(["page": [595, 842, 1]]) == "", "note: one page says nothing")
        check(ClipRules.note(["text": "old row"]) == "" && ClipRules.shape(["text": "old row"]) == nil, "an old row: no note, no shape")
        check(ClipRules.shape(["shape": "table"]) == .table && ClipRules.shape(["shape": "later"]) == nil, "shape read; unknown ignored")
    }

    static func links() {
        let a = ClipKindRules.anchorTitle
        check(a("<meta charset='utf-8'><a href=\"https://example.com/plan\">Station &amp; plan</a>", "https://example.com/plan") == "Station & plan", "anchor text")
        check(a("<a href='https://example.com/plan/'><b>Plan</b> v2</a>", "https://example.com/plan") == "Plan v2", "tags inside, trailing slash")
        check(a("<a href=\"https://example.com/other\">Other</a>", "https://example.com/plan") == nil, "another address")
        check(a("<a href=\"https://example.com/plan\">https://example.com/plan</a>", "https://example.com/plan") == nil, "the address as its own title")
        check(a("<a href=\"https://e.com/a\">A</a><a href=\"https://e.com/a\">B</a>", "https://e.com/a") == nil, "two links: no title")
    }
}
