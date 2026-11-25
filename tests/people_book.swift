// swiftc -parse-as-library app/PeopleBook.swift tests/people_book.swift -o app/build/people-book-test && app/build/people-book-test
import Foundation

@main
struct PeopleBookChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }
    static func main() {
        check(PeopleBook.forms("Міла, Mila S., міла ; Mila Synthetic,,", name: "Mila Synthetic") == ["Міла", "Mila S."], "forms trimmed, own name and repeats out")
        var b = PeopleBook()
        b.set("Mila Synthetic", forms: "Міла, Mila S.")
        b.add("Sava"); b.add("  ")
        check(b.people.count == 2 && b.people["Sava"] == [], "an empty name is not added")
        check(b.expected(["mila synthetic", "Nobody"]) == ["Mila Synthetic", "Міла", "Mila S.", "Nobody"], "expected names with forms, any case")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pb-\(getpid())/speakers.json")
        try! b.save(url)
        check(PeopleBook.load(url).people == b.people, "saved and read back")
        check(PeopleBook.load(url.appendingPathExtension("missing")).people.isEmpty, "no file: an empty book")
        check(PeopleBook.suggestions(event: ["Sava", "alex"], named: ["Mila Synthetic", "sava"], known: ["Zed", "Ann"], me: ["alex"])
              == ["Sava", "Mila Synthetic", "Ann", "Zed"], "meeting first, then named, then known by name; me out; once each")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        print("people book: all passed")
    }
}
