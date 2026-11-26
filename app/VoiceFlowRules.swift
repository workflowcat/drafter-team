// How a voice note goes from the user's voice to a field (14 November 2026; the user: "two places where typing happens at
// the same time", "if I click around to another thing it loses the typing", "stick to Enter to input something",
// and in round three: "on send it should not stop the recording ... just send that message rather than closing").
// Pure (Foundation only), tested in tests/voice_flow_rules.swift; app/Voice.swift feeds it events and does what it says.
//
// Setting `voiceInsert`:
//   enter (default)  the field is not touched while the user speaks; the strip is the one place the words show.
//                    Return while the user speaks puts in what the user said so far: that SEGMENT closes, the microphone and the
//                    engine go on into a new one, and the closed segment goes in at the caret of the field focused when
//                    its final text exists (in order: a later segment never lands before an earlier one). Return with
//                    nothing said since the last insert is not Drafter's: it goes to the app (the user's send).
//                    Only Right Option (or Esc) stops. What is left then waits in the strip as a draft, armed: a bare
//                    Return puts it in; Return during Finishing latches that insert. Any other key disarms (Return is
//                    the app's again), so does 45 s; a click or another app does not. Speaking again adds to the
//                    draft. Esc drops it (it stays in the journal).
//   live             the words go into the field while the user speaks, as before. Return while a note is still finishing is
//                    held back once ("Finishing, press ↩ again"), so a message is never sent with half its text.
// Drafter never presses Return in another app and never sends. No Return is swallowed without a visible change.
import Foundation

enum VoiceMode: String { case enter, live }

enum FlowState: Equatable {
    case idle
    case listening(prefix: String)                     // a note being spoken; prefix: an armed draft it adds to
    case finishing(prefix: String, insert: Bool, drop: Bool, held: Bool, piece: Bool)
    case armed(String)                                 // the final text waits for Return
    case kept(String)                                  // disarmed: in the journal, a double tap of Right Option puts it in
    case inserted, copied, dropped                     // shown for a moment, then idle
}

enum FlowEvent: Equatable {
    case start            // a voice note starts (right ⌥)
    case stop             // the note ends (right ⌥ again, or let go after a hold)
    case words(Bool)      // the current segment has words (said) or not, from the engine's drafts
    case segment(String)  // the final text of a segment Return closed (empty: nothing to put in)
    case piece            // live mode: Return put in the words so far, the note goes on (Talk.send)
    case pieceDone        // live mode: that piece is in
    case final(String)    // the final text after a stop (empty: nothing to put in)
    case ret              // a bare Return
    case esc              // a bare Esc
    case typed            // any other key
    case click            // a click anywhere
    case appSwitch        // another app came to the front
    case inserted(Bool)   // an insert's check: true = in a field, false = it went to the clipboard
    case cancel           // the note ended with nothing (too short, timed out, a question to the user's notes, Esc)
    case tick             // time passes (the clock is `now`)
}

enum FlowAct: Equatable {
    case none
    case closeSegment(String) // Return while speaking: close the segment (with this armed prefix), keep listening
    case stopNote             // end the note now (unused by Return since round three; kept for the classic path)
    case dropNote             // Esc while speaking: the note goes
    case arm(String)          // show the draft with its keys
    case insert(String)       // put this text in at the caret now
    case keep(String)         // disarmed: say "In the journal · ⌥⌥ Insert again"
    case drop                 // the draft goes (it stays in the journal)
    case holdReturn           // say "Finishing, press ↩ again"
    case willInsert           // say that the text goes in once it is read
    case hide                 // a moment's state is over
}

struct VoiceFlow: Equatable {
    var state: FlowState = .idle
    var at: Double = 0                        // when the state began (seconds)
    var said = false                          // the current segment has words
    var queue = 0                             // segments closed by Return whose final text is not in yet
}

enum VoiceFlowRules {
    static let armedFor = 45.0                // an armed draft disarms after this long without a key
    static let finishingFor = 20.0            // a note still finishing after this long is given up (the app says why)
    static let keptFor = 4.0, shownFor = 2.0
    static let saidFloor = 0.4                // seconds of audio before a segment's words count (a breath is not text)

    /// One event. Returns the next flow, whether the key is swallowed (only for ret, esc, typed), and what to do.
    /// nil: the flow has no say (the key goes on to the tap's other rules, as before).
    static func step(_ f: VoiceFlow, _ e: FlowEvent, mode: VoiceMode, now: Double) -> (VoiceFlow, swallow: Bool, act: FlowAct)? {
        func go(_ s: FlowState, _ swallow: Bool = false, _ act: FlowAct = .none, said: Bool? = nil, queue: Int? = nil) -> (VoiceFlow, swallow: Bool, act: FlowAct) {
            (VoiceFlow(state: s, at: s == f.state ? f.at : now, said: said ?? f.said, queue: queue ?? f.queue), swallow, act)
        }
        let enter = mode == .enter
        // a closed segment's text goes in whatever the note does meanwhile (it was asked for before)
        if case .segment(let t) = e {
            let q = max(0, f.queue - 1)
            let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return go(f.state, false, text.isEmpty ? .none : .insert(text), queue: q)
        }
        switch (f.state, e) {
        // idle and the short states
        case (.idle, .start), (.inserted, .start), (.copied, .start), (.dropped, .start), (.kept, .start):
            return go(.listening(prefix: ""), said: false)
        case (.armed(let t), .start):
            return go(.listening(prefix: t), said: false)                  // speaking again adds to the draft
        case (.idle, _):
            return nil
        case (.inserted, .inserted(false)):
            return go(.copied)                                             // the check found it on the clipboard
        case (.kept, .tick) where now - f.at >= keptFor, (.inserted, .tick) where now - f.at >= shownFor,
             (.copied, .tick) where now - f.at >= shownFor, (.dropped, .tick) where now - f.at >= shownFor:
            return f.queue > 0 ? go(f.state) : go(.idle, false, .hide)
        case (.kept, .ret), (.inserted, .ret), (.copied, .ret), (.dropped, .ret), (.kept, .esc), (.inserted, .esc), (.copied, .esc), (.dropped, .esc):
            return nil                                                     // the user's keys are their again
        case (.kept, _), (.inserted, _), (.copied, _), (.dropped, _):
            return go(f.state)

        // speaking
        case (.listening, .words(let w)):
            return go(f.state, said: w)
        case (.listening(let p), .stop):
            return go(.finishing(prefix: p, insert: false, drop: false, held: false, piece: false))
        case (.listening(let p), .ret):
            guard enter else { return nil }                                // live: the piece rule (Keys.swift) as before
            guard f.said || !p.isEmpty else { return nil }                 // nothing said since the last insert: the user's send
            return go(.listening(prefix: ""), true, .closeSegment(p), said: false, queue: f.queue + 1)
        case (.listening, .esc):
            return go(.dropped, true, .dropNote)
        case (.listening(let p), .piece):
            return go(.finishing(prefix: p, insert: false, drop: false, held: false, piece: true))
        case (.listening(let p), .cancel):
            return p.isEmpty ? go(.idle) : go(.armed(p), false, .arm(p))   // nothing new: the draft waits as it was
        case (.listening(let p), .final(let t)):                           // a note that ended without a stop seen
            return step(VoiceFlow(state: .finishing(prefix: p, insert: false, drop: false, held: false, piece: false), at: now, said: f.said, queue: f.queue),
                        .final(t), mode: mode, now: now)
        case (.listening, _):
            return go(f.state)                                             // typed keys, clicks: the user's; the note goes on

        // the last audio being read
        case (.finishing, .words(let w)):
            return go(f.state, said: w)
        case (.finishing(let p, let ins, let dr, let held, let piece), .ret):
            if enter {
                guard f.said || !p.isEmpty else { return nil }             // nothing to put in: the Return is the user's
                if !ins { return go(.finishing(prefix: p, insert: true, drop: dr, held: held, piece: piece), true, .willInsert) }
                if !held { return go(.finishing(prefix: p, insert: true, drop: dr, held: true, piece: piece), true, .holdReturn) }
                return nil                                                 // a third Return is the user's
            }
            if held { return nil }                                         // the second Return is the user's
            return go(.finishing(prefix: p, insert: ins, drop: dr, held: true, piece: piece), true, .holdReturn)
        case (.finishing(let p, _, _, let held, let piece), .esc):
            guard enter else { return go(f.state) }
            return go(.finishing(prefix: p, insert: false, drop: true, held: held, piece: piece), true, .drop)
        case (.finishing(let p, _, let dr, let held, let piece), .typed):
            return go(.finishing(prefix: p, insert: false, drop: dr, held: held, piece: piece))   // a key of the user's: no surprise insert
        case (.finishing(let p, _, _, _, true), .pieceDone):
            return go(.listening(prefix: p))
        case (.finishing(let p, let ins, let dr, _, _), .final(let t)):
            let text = join(p, t)
            if dr { return go(.dropped, said: false) }
            if !enter { return go(.idle, false, .hide, said: false) }       // live: the words are in the field already
            if text.isEmpty { return go(.idle, false, .hide, said: false) }
            if ins { return go(.inserted, false, .insert(text), said: false) }
            return go(.armed(text), false, .arm(text), said: false)
        case (.finishing(let p, _, let dr, _, _), .cancel):
            if dr || p.isEmpty || !enter { return go(.idle, false, .hide, said: false) }
            return go(.armed(p), false, .arm(p), said: false)
        case (.finishing, .tick) where now - f.at >= finishingFor:
            return go(.idle, false, .hide, said: false)
        case (.finishing, _):
            return go(f.state)

        // the draft waits for Return
        case (.armed(let t), .ret):
            return go(.inserted, true, .insert(t))                         // the paste goes out before the next key
        case (.armed, .esc):
            return go(.dropped, true, .drop)
        case (.armed(let t), .typed):
            return go(.kept(t), false, .keep(t))
        case (.armed(let t), .tick) where now - f.at >= armedFor:
            return go(.kept(t), false, .keep(t))
        case (.armed, _):
            return go(f.state)                                             // a click or another app: still armed
        }
    }

    /// What the strip shows for a flow, as one comparable line (the property: a swallowed Return changes it).
    static func visible(_ f: VoiceFlow) -> String {
        var v = word(f.state)
        if case .finishing(_, let ins, let dr, let held, _) = f.state { v += (ins ? " → field" : "") + (dr ? " · drop" : "") + (held ? " · ↩ again" : "") }
        if f.queue > 0 { v += " · inserting \(f.queue)" }
        return v
    }

    /// A segment's words count: the engine gave words, they are not room noise, and there is enough audio.
    static func said(_ words: String, seconds: Double, noise: Bool) -> Bool {
        !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seconds >= saidFloor && !noise
    }

    /// The tap's key as a flow event. `flags`: the event's raw flags. While the user holds Right Option (push to talk) its
    /// Option bit is not a modifier of Return: Return stays Return (round three).
    static func key(code: Int64, flags: UInt64) -> FlowEvent {
        let shift: UInt64 = 0x20000, ctrl: UInt64 = 0x40000, alt: UInt64 = 0x80000, cmd: UInt64 = 0x100000
        let rightAlt: UInt64 = 0x40, leftAlt: UInt64 = 0x20
        var mods = flags & (shift | ctrl | alt | cmd)
        if mods & alt != 0, flags & rightAlt != 0, flags & leftAlt == 0 { mods &= ~alt }
        guard mods == 0 else { return .typed }
        if code == 36 || code == 76 { return .ret }
        if code == 53 { return .esc }
        return .typed
    }

    /// A Right Option press right after a voice note ends is a bounce only after a note with words (2026-10-22). After
    /// an empty note (a dead microphone, nothing heard) it is the user trying again: it starts (23 of 23 ignored presses in
    /// the 7 days to 14 November followed an empty note).
    static func pressIgnored(sinceEnd: Double, lastHadWords: Bool) -> Bool { lastHadWords && sinceEnd < 0.8 }

    /// Where an armed draft goes if the user presses Return now, read from the focused element (Talk.watchTarget).
    enum Target: Equatable { case field, noField, password, skipped, secure }
    /// What the strip says about the target, and the draft's button: Insert into a field, else Copy (said before the user
    /// presses, so a click elsewhere never loses the text). `app`: the frontmost app's name.
    static func target(_ t: Target, app: String) -> (place: String, button: String) {
        let a = app.isEmpty ? "this app" : app
        switch t {
        case .field: return ("→ " + a, "Insert")
        case .noField: return ("No text field in " + a, "Copy")
        case .password: return ("A password field in " + a, "Copy")
        case .skipped: return ("Drafter is off in " + a, "Copy")
        case .secure: return ("Secure input is on in " + a, "Copy")
        }
    }
    /// The target from Focus.spot's answer: a spot, or why there is none (its words), and whether it can paste there.
    static func target(spot: Bool, why: String, canPaste: Bool, ownApp: Bool) -> Target {
        if why == "secure input" { return .secure }
        if why == "password field" { return .password }
        if why == "skipped app" { return .skipped }
        if ownApp { return .noField }
        return spot || canPaste ? .field : .noField
    }

    /// An armed draft and what the user said after it, as one text.
    static func join(_ prefix: String, _ text: String) -> String {
        let a = prefix.trimmingCharacters(in: .whitespacesAndNewlines), b = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Would a bare Return be swallowed now? (The tap asks before it lets a Return through.)
    static func swallowsReturn(_ f: VoiceFlow, mode: VoiceMode) -> Bool {
        step(f, .ret, mode: mode, now: f.at)?.swallow ?? false
    }

    /// What the strip says for a state, as a present phrase (never a past-tense label).
    static func word(_ s: FlowState) -> String {
        switch s {
        case .idle: return ""
        case .listening: return "Listening"
        case .finishing: return "Finishing"
        case .armed: return "Draft ready"
        case .inserted: return "In the field"
        case .copied: return "On the clipboard"
        case .kept: return "In the journal"
        case .dropped: return ""            // the strip goes
        }
    }
}

/// Audio heard while the voice engine is not there to take it (its process starting or starting again): kept in
/// order and handed over the moment it can take it, so the first words are never lost (round three). Capped, so a
/// process that never comes cannot grow memory: the oldest audio goes first (30 s at 16 kHz).
struct WakeBuffer {
    static let cap = 16000 * 30
    private(set) var kept: [[Float]] = []
    private(set) var count = 0
    /// New samples: what to send now, in order (the kept ones first). `ready`: the engine can take audio.
    mutating func add(_ s: [Float], ready: Bool) -> [[Float]] {
        guard ready else {
            kept.append(s); count += s.count
            while count > WakeBuffer.cap, !kept.isEmpty { count -= kept.removeFirst().count }
            return []
        }
        let out = kept + [s]
        kept = []; count = 0
        return out
    }
    /// The engine became ready with no new samples: what was kept goes now.
    mutating func flush() -> [[Float]] { let out = kept; kept = []; count = 0; return out }
}
