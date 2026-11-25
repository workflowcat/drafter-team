import Foundation
// swiftc -parse-as-library app/PersonRules.swift tests/people_cards.swift -o app/build/people_cards-test && app/build/people_cards-test
@main struct Checks {
    static func main() throws {
        let data = Data(#"""
        [
          {"name":"Hanna Onyshchenko","kind":"person","aliases":["Ганна Онищенко"],"tokens":["Hanna","Onyshchenko","Ганна","Онищенко"],"forms":["Ганни","Ганні","Ганною"],"heat":20,"handles":{"email":["hanna@example.test"],"phone":["+380445550100"],"tg":["hanna_demo"]}},
          {"name":"Hannah Sample","kind":"person","aliases":[],"tokens":["Hannah","Sample"],"forms":[],"heat":5,"handles":{"email":["other@example.test"]}},
          {"name":"Hanna Private","kind":"person","aliases":[],"tokens":["Hanna"],"forms":[],"heat":100,"scope":"private","handles":{"email":["private@example.test"]}},
          {"name":"Hanna Tool","kind":"tool","aliases":[],"tokens":["Hanna"],"forms":[],"heat":100,"handles":{}}
        ]
        """#.utf8)
        let people = try JSONDecoder().decode([KnownPerson].self, from:data)
        let choices = PersonRules.matches("please ;han", people:people)
        precondition(choices.count == 2 && choices[0].person.name == "Hanna Onyshchenko")
        precondition(PersonRules.matches(";HAN", people:people).count == 2)
        precondition(PersonRules.matches(";онищ", people:people).count == 1)
        precondition(PersonRules.matches(";h", people:people).isEmpty)
        precondition(PersonRules.matches("x;han", people:people).isEmpty)
        precondition(PersonRules.matches(";han ", people:people).isEmpty)
        precondition(PersonRules.matches(";han", people:people, reserved:[";Han"]).isEmpty)
        for reserved in [";Hanna", ";Handbook"] {
            precondition(PersonRules.matches(";han", people: people, reserved: [reserved]).isEmpty)
        }
        for cue in ["Petro Onyshchenko's email", "unknown Hanna's email", "Petro Hanna's email"] {
            precondition(PersonRules.matches(cue, people: people).isEmpty, cue)
        }
        precondition(PersonRules.matches("send Hanna Onyshchenko's email", people: people).count == 1)
        func run(_ c:[PersonChoice], _ p:Int=0, _ h:Int=0) -> [String:String] {
            PersonRules.action(c, person:p, handle:h)!["run"] as! [String:String]
        }
        precondition(run(choices)["old"] == ";han")
        precondition(run(choices)["new"] == "hanna@example.test")
        precondition(run(choices,0,1)["new"] == "+380445550100")
        precondition(run(choices,0,-1)["new"] == "hanna_demo")
        precondition(run(choices,1,0)["new"] == "other@example.test")
        precondition(run(choices,2,0)["new"] == "hanna@example.test")
        for cue in ["Hanna's email", "send Hanna's email", "email of Hanna", "email of Hanna Onyshchenko", "пошта Ганни", "пошта Ганною"] {
            let matches = PersonRules.matches(cue, people:people)
            precondition(matches.count == 1, cue)
            precondition(run(matches)["old"] == "")
            precondition(run(matches)["new"] == " hanna@example.test")
        }
        for cue in ["телефон Ганні", "номер Ганни"] {
            precondition(run(PersonRules.matches(cue, people:people))["new"] == " +380445550100")
        }
        precondition(PersonRules.matches("email of unknown", people:people).isEmpty)
        precondition(PersonRules.matches("email of unknown Hanna", people:people).isEmpty)
        precondition(PersonRules.matches("Hanna's email is missing", people:people).isEmpty)
        print("PASS: person card matching, priorities, cues and cycling")
    }
}
