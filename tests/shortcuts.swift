import Foundation
// swiftc -parse-as-library app/SnippetRules.swift tests/shortcuts.swift -o app/build/shortcuts-test && app/build/shortcuts-test
@main struct Checks {
 static func main() throws {
    precondition(SnippetRules.initials(name: "Ada Umber", given: "") == "AU" && SnippetRules.initials(name: "Ada", given: "") == "" && SnippetRules.initials(name: "", given: "kd") == "KD")
    SnippetRules.initials = "AU"
    let snippets = [";mail": "au@example.com", ";cal": "https://example.com/calendar", ";m": "short"]
    let cues = try JSONDecoder().decode([SnippetCue].self, from: Data(contentsOf: URL(fileURLWithPath: "dictionary/snippet-cues.json")))
    let exact: [(String, String?)] = [("AU ", "au@example.com "), ("hello AU ", "au@example.com "), ("au ", nil), ("SAU ", nil), ("AU", nil), ("AU  ", nil), ("AU! ", nil), (";CAL ", "https://example.com/calendar "), (";calx ", nil), (";дякую ", "Дякую, отримав. ")]
    for (before, want) in exact { precondition(SnippetRules.exact(before, snippets: snippets, replacements: [";дякую": "Дякую, отримав."])?.new == want, "exact: \(before)") }
    let offers: [(String, String?)] = [("au", "au@example.com"), ("AU", "au@example.com"), ("au@ex", "au@example.com"), ("au@example.com", nil), ("author", nil), ("hello au", "au@example.com"), ("other@au", nil), (";ca", "https://example.com/calendar"), (";m", "short"), ("my email is", " au@example.com"), ("моя пошта: ", "au@example.com"), ("лінк на календар", " https://example.com/calendar"), ("my calendar link ", "https://example.com/calendar"), ("my calendar link disappeared", nil), ("AU ", nil)]
    for (before, want) in offers { precondition(SnippetRules.offer(before, snippets: snippets, cues: cues)?.new == want, "offer: \(before)") }
    precondition(SnippetRules.offer("AU", snippets: [:], cues: cues) == nil)
    var endings = UkrainianEndings()
    endings.add("повідомлення повідомлення повідомлення зустріч зустріч зустріч")
    precondition(endings.suffix("повід") == "омлення")
    precondition(endings.suffix("ПОВІД") == "ОМЛЕННЯ")
    precondition(endings.suffix("повідомлення") == nil)
    precondition(endings.suffix("повід ") == nil)
    precondition(endings.suffix("пов") == nil)
    precondition(endings.suffix("повід,") == nil)
    endings.add("повідомлений повідомлений повідомлений")
    precondition(endings.suffix("повід") == nil)
    print("PASS: 33 shortcut and Ukrainian completion checks")
 }
}
