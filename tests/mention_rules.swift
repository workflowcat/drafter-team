// swiftc -O -parse-as-library app/MentionRules.swift app/EntityRules.swift app/RefRules.swift tests/mention_rules.swift -o app/build/mention-rules-test && app/build/mention-rules-test
// Made-up people only.
import Foundation

@main
struct MentionRulesTest {
    static func main() {
        // --- the `;` trigger
        func p(_ s: String, _ reserved: Set<String> = []) -> MentionTyped? { MentionRules.parse(s, reserved: reserved) }
        precondition(p("hi ;ana") == MentionTyped(old: ";ana", query: "ana", pick: nil))
        precondition(p(";ana") == MentionTyped(old: ";ana", query: "ana", pick: nil), "line start")
        precondition(p("write to ;ana ") == MentionTyped(old: ";ana ", query: "ana", pick: nil), "a space waits for a number")
        precondition(p("write to ;ana 2") == MentionTyped(old: ";ana 2", query: "ana", pick: 2))
        precondition(p("write to ;ana 7") == nil, "only 1-6")
        precondition(p("write to ;ana x") == nil, "a word after it: done")
        precondition(p(";an") == nil, "three letters at least (;en ;uk stay translate)")
        precondition(p("a;ana") == nil, "the ; starts a word")
        precondition(p("(;Ганна") == MentionTyped(old: ";Ганна", query: "Ганна", pick: nil), "after a bracket, Cyrillic")
        precondition(p("first line ;ana\nsecond") == nil, "only the line with the caret")
        // reserved words win: ;ctx, snippets and quick starts, and any key the typed word begins
        for r in [";ctx", ";ct", ";ctx 2"] { precondition(p(r) == nil, r) }
        precondition(p(";docs") != nil, "the old Google words are names again")
        precondition(p(";sig", [";sign"]) == nil && p(";sign 2", [";sign"]) == nil, "a snippet key")
        precondition(p(";meet", [";meet"]) == nil, "a quick start")
        precondition(p(";fred") != nil, "a name that only starts like nothing reserved")
        precondition(MentionRules.cardFirst("ai") && MentionRules.cardFirst("agent") && !MentionRules.cardFirst("chat") && !MentionRules.cardFirst("mail"))

        // --- the fields
        var ana = Entity(id: "p:ana", kind: "person", name: "Ana Example")
        ana.who = "designer, at Sample Studio"
        ana.handles = ["phone": ["+380 44 555 0100"], "email": ["ana@example.test"], "address": ["Sample st 1\nKyiv"]]
        let s = MentionRules.slots(ana)
        precondition(s.map(\.key) == [1, 2, 3, 4, 5, 6] && s.map(\.label) == MentionRules.labels)
        precondition(MentionRules.text(ana, key: 1) == "Ana Example")
        precondition(MentionRules.text(ana, key: 2) == "+380 44 555 0100", "2 is always the phone")
        precondition(MentionRules.text(ana, key: 3) == "ana@example.test")
        precondition(MentionRules.text(ana, key: 4) == "Sample st 1, Kyiv", "an address goes in as one line")
        precondition(MentionRules.text(ana, key: 5) == "Sample Studio", "company from the who line")
        precondition(MentionRules.text(ana, key: 6) == "Ana Example · designer, at Sample Studio · +380 44 555 0100 · ana@example.test")
        precondition(MentionRules.text(ana, key: 7) == nil && MentionRules.text(ana, key: 0) == nil)
        ana.org = "Sample Studio LLC"
        precondition(MentionRules.text(ana, key: 5) == "Sample Studio LLC", "the contact's company wins")
        let bare = Entity(id: "p:b", kind: "person", name: "Bo Sample")
        precondition(MentionRules.text(bare, key: 2) == nil && MentionRules.text(bare, key: 5) == nil)
        precondition(MentionRules.text(bare, key: 6) == "Bo Sample", "a card with nothing else is the name")

        // --- who is listed: people only, never private, warmest first, at most 5
        func ent(_ id: String, _ kind: String, _ name: String, heat: Double = 1, priv: Bool = false) -> Entity {
            var e = Entity(id: id, kind: kind, name: name); e.heat = heat; e.private = priv; return e
        }
        let store = EntityStore(records: [
            ent("p:1", "person", "Ana Example", heat: 2),
            ent("p:2", "person", "Anatoliy Sample", heat: 5),
            ent("o:1", "org", "Anaconda Org", heat: 9),
            ent("p:3", "person", "Anna Hidden", heat: 9, priv: true),
            ent("p:4", "person", "Bo Sample"),
        ] + (5..<12).map { ent("p:\($0)", "person", "Anx\($0) Filler") })
        let found = MentionRules.people("ana", in: store)
        precondition(found.prefix(2) == [1, 0], "warmest first: \(found)")
        precondition(!found.contains(2) && !found.contains(3), "no org, no private")
        let many = MentionRules.people("an", in: store)
        precondition(many.count == MentionRules.most, "at most 5: \(many)")
        precondition(MentionRules.people("sample", in: store) == [1, 4], "a last name finds them too")

        // --- no trigger: "Ana's number"
        var a2 = ent("p:a", "person", "Ana Example", heat: 3); a2.handles = ["phone": ["+380 44 555 0100"], "email": ["ana@example.test"]]
        var a3 = ent("p:o", "person", "Ana Other", heat: 1); a3.handles = ["phone": ["+380 00 000 0000"]]
        var hid = ent("p:h", "person", "Hidden Person", heat: 9, priv: true); hid.handles = ["phone": ["+1"]]
        let mark = ent("p:m", "person", "Mark Sample"); var org = ent("o:a", "org", "Ana Org"); org.handles = ["phone": ["+2"]]
        var st2 = EntityStore(records: [a2, a3, hid, mark, org])
        st2.surfaces = ["ana example": [EntityHit(index: 0, how: "name")], "ana": [EntityHit(index: 0, how: "first"), EntityHit(index: 1, how: "first"), EntityHit(index: 4, how: "part")],
                        "ані": [EntityHit(index: 0, how: "form")], "hidden person": [EntityHit(index: 2, how: "name")], "mark": [EntityHit(index: 3, how: "first")]]
        st2.surfaceFlags = ["mark": EntitySurfaceFlags(ordinary: true)]
        func ask(_ s: String) -> String? { MentionRules.ask(s, in: st2)?.text }
        precondition(ask("here is Ana's number") == "+380 44 555 0100", "possessive, the warmest Ana")
        precondition(ask("Ana Example phone:") == "+380 44 555 0100", "full name, a colon")
        precondition(ask("send me the email of Ana Example") == "ana@example.test", "field of name")
        precondition(ask("ось номер Ані") == "+380 44 555 0100", "a case form")
        precondition(ask("Ана пошта") == nil, "an unknown form: nothing")
        precondition(ask("Ana's address") == nil, "no address: no chip")
        precondition(ask("Hidden Person number") == nil, "never a private person")
        precondition(ask("check the mark number") == nil, "a name that is an ordinary word")
        precondition(ask("call me at this number") == nil, "no name: nothing")
        precondition(ask("Ana's number is") == nil, "the field word must end the line")
        precondition(MentionRules.asked("Ana's number")?.key == 2 && MentionRules.asked("адреса Ані")?.key == 4)
        print("mention rules: ok")
    }
}
