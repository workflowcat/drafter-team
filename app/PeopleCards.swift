// Cached local pack, before engine readiness. No network or model call.
import AppKit
import Carbon

enum PeopleCards {
    private struct Pack: Decodable { let entries: [KnownPerson] }
    private static let cached = LocalSnapshot<[KnownPerson]>([Home.data.appendingPathComponent("know.json")]) { files in
        guard let data = files[0] else { return [] }
        return try JSONDecoder().decode(Pack.self, from: data).entries.filter { $0.kind == "person" && $0.scope != "private" }
    }
    private static var people: [KnownPerson] = []
    private static var choices: [PersonChoice] = [], person = 0, handle = 0
    static func refresh() { people = cached.read() ?? [] }
    static func offer(_ before: String) -> [String: Any]? {
        refresh()
        guard Snippets.ready else { return nil }
        let reserved = Set(Snippets.all.keys).union(Presets.all.flatMap { $0.keys })
        choices = PersonRules.matches(before, people: people, reserved: reserved)
        person = 0; handle = 0
        return PersonRules.action(choices, person: person, handle: handle)
    }
    static func clear() { choices = []; person = 0; handle = 0 }
    static func move(_ code: Int) {
        guard !IsSecureEventInputEnabled(), Ghost.shared.visible, Ghost.shared.action?["id"] as? String == "person",
              let expected = Keys.shared.spot, let s = Focus.spot(skip: Drafter.shared.settings.skip).0,
              CFEqual(expected.el, s.el), expected.app.processIdentifier == s.app.processIdentifier,
              expected.before == s.before, let rect = s.rect else { clear(); Ghost.shared.hide(); return }
        if code == 125 { person = PersonRules.wrap(person + 1, count: choices.count); handle = 0 }
        else { handle += code == 123 ? -1 : 1 }
        if let action = PersonRules.action(choices, person: person, handle: handle) {
            Ghost.shared.show("", action: action, at: rect)
        }
    }
}
