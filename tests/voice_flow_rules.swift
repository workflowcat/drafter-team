// swiftc -parse-as-library app/VoiceFlowRules.swift tests/voice_flow_rules.swift -o app/build/voice-flow-test && app/build/voice-flow-test
// The voice note's way to the field (app/VoiceFlowRules.swift): every transition in both modes; Return closes a
// segment and keeps listening; inserts land in order; no Return is swallowed without a visible change, and an untaken
// Return reaches the app; stop, final and Return in every order; Return never swallowed for good; the target words;
// the key reading while Right Option is held; the press after an empty note; audio kept while the engine wakes.
import Foundation

@main
struct VoiceFlowTest {
    static var failed = 0, checks = 0
    static func check(_ ok: Bool, _ what: String) { checks += 1; if !ok { failed += 1; print("FAIL " + what) } }
    static func run(_ events: [(FlowEvent, Double)], mode: VoiceMode = .enter, from: VoiceFlow = VoiceFlow()) -> (VoiceFlow, [FlowAct], [Bool]) {
        var f = from, acts: [FlowAct] = [], sw: [Bool] = []
        for (e, t) in events {
            if let (n, s, a) = VoiceFlowRules.step(f, e, mode: mode, now: t) { f = n; acts.append(a); sw.append(s) } else { acts.append(.none); sw.append(false) }
        }
        return (f, acts, sw)
    }
    static func inserts(_ acts: [FlowAct]) -> [String] { acts.compactMap { if case .insert(let t) = $0 { return t }; return nil } }

    static func main() {
        let E = VoiceMode.enter, L = VoiceMode.live
        // Return while speaking: the segment closes, listening goes on, its text goes in when it exists
        var (f, a, s) = run([(.start, 0), (.words(true), 1), (.ret, 3)])
        check(s[2] && a[2] == .closeSegment("") && f.state == .listening(prefix: "") && f.queue == 1 && !f.said, "Return closes a segment, keeps listening")
        (f, a, s) = run([(.words(true), 4), (.segment("First part."), 4.1), (.ret, 6), (.segment("Second part."), 6.2)], from: f)
        check(inserts(a) == ["First part.", "Second part."] && f.queue == 0 && f.state == .listening(prefix: ""), "segments go in, in order, listening goes on")
        // nothing said since the last insert: Return is his (it sends), the recording goes on
        (f, a, s) = run([(.ret, 7)], from: f)
        check(!s[0] && f.state == .listening(prefix: ""), "an empty segment: Return goes to the app")
        check(VoiceFlowRules.step(f, .ret, mode: E, now: 7) == nil, "untaken: the flow has no say")
        // a segment whose final came back empty: nothing goes in
        (f, a, _) = run([(.start, 0), (.words(true), 1), (.ret, 2), (.segment(" "), 2.1)])
        check(inserts(a).isEmpty && f.queue == 0, "an empty final: nothing goes in")
        // stop is only Right Option: then Finishing, then Draft ready
        (f, a, s) = run([(.start, 0), (.words(true), 1), (.stop, 3), (.final("Made-up note for the strip."), 3.4)])
        check(f.state == .armed("Made-up note for the strip.") && a.last == .arm("Made-up note for the strip."), "stop then final arms the draft")
        (f, a, s) = run([(.ret, 10), (.inserted(true), 11), (.tick, 11), (.tick, 12.5)], from: f)
        check(s[0] && a[0] == .insert("Made-up note for the strip.") && f.state == .idle && a.last == .hide, "Return inserts the draft, then In the field, then gone")
        (f, _, s) = run([(.start, 0), (.words(true), 1), (.stop, 2), (.final("w"), 2.1), (.ret, 3), (.ret, 3.2)])
        check(s[4] && !s[5], "the Return after an insert is his at once (the check never holds it)")
        (f, _, _) = run([(.start, 0), (.words(true), 1), (.stop, 1), (.final("Note"), 1.2), (.ret, 2), (.inserted(false), 2.2)])
        check(f.state == .copied, "no field: on the clipboard")
        // Return during Finishing latches the insert; a second is held once (said), a third is his
        (f, a, s) = run([(.start, 0), (.words(true), 0.5), (.stop, 1), (.ret, 1.1), (.ret, 1.2), (.ret, 1.3), (.final("Words"), 1.5)])
        check(s[3] && a[3] == .willInsert && s[4] && a[4] == .holdReturn && !s[5] && a.last == .insert("Words") && f.state == .inserted, "latch, held once, then his; the latch inserts at the final")
        (f, _, s) = run([(.start, 0), (.stop, 1), (.ret, 1.1)])
        check(!s[2], "Finishing with nothing said: Return is his")
        (f, a, s) = run([(.start, 0), (.words(true), 0.5), (.stop, 1), (.ret, 1.1), (.typed, 1.2), (.final("Words"), 1.5)])
        check(f.state == .armed("Words"), "a key of his while finishing: no surprise insert")
        // disarm: a typed key, the time, but not a click or another app
        let armed = VoiceFlow(state: .armed("Draft"), at: 100)
        (f, _, s) = run([(.click, 101), (.appSwitch, 102), (.tick, 130)], from: armed)
        check(f.state == .armed("Draft") && s.allSatisfy { !$0 }, "a click or an app switch keeps it armed")
        (f, a, s) = run([(.typed, 103)], from: armed)
        check(f.state == .kept("Draft") && !s[0] && a[0] == .keep("Draft"), "a typed key disarms, the key is his")
        check(VoiceFlowRules.step(f, .ret, mode: E, now: 104) == nil, "Return after disarming goes to the app")
        (f, a, _) = run([(.tick, 144.9), (.tick, 145)], from: armed)
        check(a[0] == .none && a[1] == .keep("Draft"), "45 s without a key disarms")
        (f, a, _) = run([(.tick, 149.5)], from: f)
        check(f.state == .idle && a[0] == .hide, "kept shows a moment, then goes")
        // Esc
        (f, a, s) = run([(.esc, 101)], from: armed)
        check(f.state == .dropped && s[0] && a[0] == .drop, "Esc drops the draft")
        (f, a, s) = run([(.start, 0), (.esc, 1)])
        check(f.state == .dropped && s[1] && a[1] == .dropNote, "Esc while speaking drops the note")
        (f, a, s) = run([(.start, 0), (.words(true), 0.5), (.stop, 1), (.ret, 1.05), (.esc, 1.1), (.final("Words"), 1.3)])
        check(f.state == .dropped && s[4] && inserts(a).isEmpty, "Esc clears the latch and drops")
        (f, a, _) = run([(.start, 0), (.words(true), 0.5), (.ret, 1), (.esc, 1.1), (.segment("Kept part."), 1.3)])
        check(inserts(a) == ["Kept part."], "Esc after a Return: the closed segment still goes in")
        // speaking again while armed adds to the draft; Return then puts the draft and the new words in together
        (f, a, _) = run([(.start, 101), (.words(true), 102), (.stop, 103), (.final("and more words"), 103.5)], from: armed)
        check(f.state == .armed("Draft and more words"), "speaking again appends: \(f.state)")
        (f, a, s) = run([(.start, 101), (.ret, 101.5)], from: armed)
        check(s[1] && a[1] == .closeSegment("Draft"), "Return after speaking on a draft: the draft goes with the segment")
        (f, a, _) = run([(.start, 101), (.cancel, 101.2)], from: armed)
        check(f.state == .armed("Draft") && a.last == .arm("Draft"), "an empty note after a draft: the draft waits as it was")
        (f, _, _) = run([(.start, 0), (.stop, 1), (.final("  "), 1.1)])
        check(f.state == .idle, "nothing heard: nothing arms")
        // segments still in flight when the note ends: they go in, the strip waits for them
        (f, a, _) = run([(.start, 0), (.words(true), 1), (.ret, 2), (.stop, 2.1), (.final(""), 2.2), (.segment("Late."), 2.4)])
        check(inserts(a) == ["Late."] && f.queue == 0, "a segment answered after the note ended still goes in")
        (f, a, _) = run([(.start, 0), (.words(true), 1), (.ret, 2), (.stop, 2.1), (.cancel, 2.2), (.tick, 9), (.segment("Late."), 9.5)])
        check(inserts(a) == ["Late."], "even after the note closed with nothing")
        // live: the piece rule as before; Return held once while finishing
        check(VoiceFlowRules.step(VoiceFlow(state: .listening(prefix: ""), at: 0, said: true), .ret, mode: L, now: 1) == nil, "live: Return while speaking is the piece rule's")
        (f, a, s) = run([(.start, 0), (.piece, 1), (.ret, 1.1), (.ret, 1.2), (.pieceDone, 1.5)], mode: L)
        check(s[2] && a[2] == .holdReturn && !s[3] && f.state == .listening(prefix: ""), "live: Return held once while a piece finishes")
        (f, _, s) = run([(.start, 0), (.stop, 1), (.ret, 1.1), (.ret, 1.2), (.final("Words"), 1.5)], mode: L)
        check(s[2] && !s[3] && f.state == .idle, "live: Return held once while the note finishes")

        // THE PROPERTY: for every state, a swallowed Return changes what the strip shows (or latches an insert);
        // a Return the flow does not take reaches the app (nil or not swallowed)
        let states: [FlowState] = [.idle, .listening(prefix: ""), .listening(prefix: "x"),
                                   .finishing(prefix: "", insert: false, drop: false, held: false, piece: false),
                                   .finishing(prefix: "", insert: true, drop: false, held: false, piece: false),
                                   .finishing(prefix: "x", insert: true, drop: false, held: true, piece: false),
                                   .finishing(prefix: "", insert: false, drop: true, held: false, piece: false),
                                   .finishing(prefix: "", insert: false, drop: false, held: false, piece: true),
                                   .armed("x"), .kept("x"), .inserted, .copied, .dropped]
        var all: [VoiceFlow] = []
        for st in states { for said in [false, true] { for q in [0, 1, 3] { all.append(VoiceFlow(state: st, at: 0, said: said, queue: q)) } } }
        for mode in [E, L] {
            for f0 in all {
                guard let (n, sw, act) = VoiceFlowRules.step(f0, .ret, mode: mode, now: 1) else { continue }
                if sw {
                    let latched: Bool = { if case .finishing(_, true, _, _, _) = n.state { return true }; return false }()
                    check(VoiceFlowRules.visible(n) != VoiceFlowRules.visible(f0) || (latched && act != .none), "\(mode) \(f0): a swallowed Return shows a change")
                } else {
                    check(act == .none || act == .hide, "\(mode) \(f0): an untaken Return does nothing of Drafter's")
                }
            }
        }
        // Return is never swallowed for good: time passing gives it back (a missed release, a final that never comes)
        for mode in [E, L] {
            for f0 in all where f0.state != .idle {
                var g = f0
                for t in [30.0, 60, 90, 120, 200] { if let (n, _, _) = VoiceFlowRules.step(g, .tick, mode: mode, now: t) { g = n } }
                if case .listening = g.state {
                    // still speaking (no release ever seen): Return closes a segment at most, then is his again
                    if let (n, _, _) = VoiceFlowRules.step(g, .ret, mode: mode, now: 201) { g = n }
                    check(!VoiceFlowRules.swallowsReturn(g, mode: mode), "\(mode) \(f0): Return free again after one segment")
                    continue
                }
                check(!VoiceFlowRules.swallowsReturn(g, mode: mode), "\(mode) \(f0): Return free after time passes (\(g.state))")
            }
        }
        // the tap and the flow: stop, final and Return in every order the engine allows (a final comes after its stop,
        // a segment after its Return): the text goes in once, never lost, never twice
        func perms(_ a: [String]) -> [[String]] { a.count <= 1 ? [a] : a.indices.flatMap { i -> [[String]] in var r = a; let x = r.remove(at: i); return perms(r).map { [x] + $0 } } }
        for order in perms(["stop", "final", "ret"]) where order.firstIndex(of: "stop")! < order.firstIndex(of: "final")! {
            var evs: [(FlowEvent, Double)] = [(.start, 0), (.words(true), 0.5)]
            var segAsked = false
            for (i, k) in order.enumerated() {
                let t = 1 + Double(i) * 0.05
                switch k {
                case "stop": evs.append((.stop, t))
                case "final": evs.append((.final(segAsked ? "" : "Words"), t))
                default:
                    if !order.prefix(i).contains("stop") { segAsked = true }
                    evs.append((.ret, t))
                }
            }
            if segAsked { evs.append((.segment("Words"), 2)) }
            var (g, acts, _) = run(evs)
            var all = inserts(acts)
            if case .armed(let t) = g.state { check(t == "Words", "armed with the words"); (g, acts, _) = run([(.ret, 3)], from: g); all += inserts(acts) }
            check(all == ["Words"], "\(order): the words go in once, got \(all)")
        }
        // a Return while Right Option is held (push to talk) is still Return
        check(VoiceFlowRules.key(code: 36, flags: 0x80000 | 0x40) == .ret, "Return with Right Option held is Return")
        check(VoiceFlowRules.key(code: 36, flags: 0x80000 | 0x20) == .typed, "⌥Return with the left Option is his key")
        check(VoiceFlowRules.key(code: 36, flags: 0x100000) == .typed && VoiceFlowRules.key(code: 36, flags: 0x20000) == .typed, "⌘↩ and ⇧↩ are his keys")
        check(VoiceFlowRules.key(code: 76, flags: 0) == .ret && VoiceFlowRules.key(code: 53, flags: 0) == .esc && VoiceFlowRules.key(code: 0, flags: 0) == .typed, "keys")
        // a segment's words
        check(!VoiceFlowRules.said("", seconds: 3, noise: false) && !VoiceFlowRules.said("hm", seconds: 0.2, noise: false)
              && !VoiceFlowRules.said("Thank you.", seconds: 2, noise: true) && VoiceFlowRules.said("Let's go", seconds: 1, noise: false), "said: words, a floor, not noise")
        // a press right after a note: a bounce only after a note with words
        check(VoiceFlowRules.pressIgnored(sinceEnd: 0.3, lastHadWords: true) && !VoiceFlowRules.pressIgnored(sinceEnd: 0.3, lastHadWords: false)
              && !VoiceFlowRules.pressIgnored(sinceEnd: 1, lastHadWords: true), "a press after an empty note starts a new one")
        // audio kept while the engine wakes: in order, nothing lost, capped
        var w = WakeBuffer()
        check(w.add([1, 2], ready: false).isEmpty && w.add([3], ready: false).isEmpty && w.count == 3, "kept while waking")
        check(w.add([4, 5], ready: true) == [[1, 2], [3], [4, 5]] && w.count == 0, "handed over in order when ready")
        _ = w.add([6], ready: false); check(w.flush() == [[6]] && w.flush().isEmpty, "flush once")
        var big = WakeBuffer(); let sec = [Float](repeating: 0.1, count: 16000)
        for _ in 0..<40 { _ = big.add(sec, ready: false) }
        check(big.count <= WakeBuffer.cap && big.kept.count == 30, "capped at 30 s, the oldest goes")
        // where the draft goes
        check(VoiceFlowRules.target(.field, app: "Claude") == ("→ Claude", "Insert"), "a field: → app, Insert")
        check(VoiceFlowRules.target(.noField, app: "Finder") == ("No text field in Finder", "Copy"), "no field: Copy, said")
        check(VoiceFlowRules.target(spot: false, why: "mid-line", canPaste: true, ownApp: false) == .field, "a paste target is a field")
        check(VoiceFlowRules.target(spot: true, why: "secure input", canPaste: true, ownApp: false) == .secure, "secure input wins")
        check(VoiceFlowRules.target(spot: true, why: "", canPaste: true, ownApp: true) == .noField, "Drafter's own window is not the target")
        for st in states { let x = VoiceFlowRules.word(st); check(!x.hasSuffix("ed"), "present phrase: \(x)") }
        check(VoiceFlowRules.join(" a ", "b") == "a b" && VoiceFlowRules.join("", "b") == "b", "join")
        print(failed == 0 ? "voice flow: all \(checks) checks pass" : "voice flow: \(failed) of \(checks) checks failed")
        exit(failed == 0 ? 0 : 1)
    }
}
