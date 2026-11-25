// swift-runner: skip (built by its Python runner)
import Foundation

// Pure doubles: no Accessibility, key posting, clipboard, app or filesystem calls.
struct MockApp { var processIdentifier = 1; var web = false }
struct MockSpot { var app = MockApp(); var el = 1; var before = "old "; var value = "old "; var caret = 4; var rect: Int? = 1; var viaMarkers = false }
final class NSWorkspace { static let shared = NSWorkspace(); var frontmostApplication: MockApp? = MockApp() }
final class Keys { static let shared = Keys(); var inputRevision = 0; var spot: MockSpot? }
var secure = false
func IsSecureEventInputEnabled() -> Bool { secure }
func CFEqual(_ a: Int, _ b: Int) -> Bool { a == b }
typealias CFString = String
struct CFRange { var location: Int; var length: Int }
enum ValueType { case cfRange }
func AXValueCreate(_ type: ValueType, _ range: inout CFRange) -> Int? { 1 }
let kAXSelectedTextRangeAttribute = "range", kAXSelectedTextAttribute = "selection", kAXValueAttribute = "value"
enum Result { case success, failure }
enum VoiceMode { case enter, live }
func AXUIElementSetAttributeValue(_ el: Int, _ key: String, _ value: Any) -> Result {
    Focus.writes.append(key)
    if key == kAXSelectedTextRangeAttribute { Focus.selected = "old "; return .success }
    if Focus.failWrite { return .failure }
    Focus.value = value as! String
    return .success
}
enum Focus {
    static var current: MockSpot? = MockSpot(), selected: String? = nil, element: Int? = 1
    static var value = "", writes: [String] = [], pastes: [String] = [], reads: [String] = []
    static var failWrite = false, off = false   // off: an off-limits field (Drafter's own window, a password field)
    static func spot(skip: [String]) -> (MockSpot?, String) { reads.append(DispatchQueue.lane); return (current, "") }
    static func isWeb(_ app: MockApp) -> Bool { app.web }
    static func offLimits(_ el: Int) -> Bool { off }
    static func setSelectedText(_ el: Int, _ text: String) -> Result {
        if offLimits(el) { return .failure }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute, text)
    }
    static func focused() -> Int? { element }
    static func selection() -> String? { selected }
    static func paste(_ text: String) { pastes.append(text) }
    static func attr<T>(_ el: Int, _ key: String) -> T? { (key == kAXSelectedTextAttribute ? selected : value) as? T }
}
enum Fields {
    static var arrows: [Int] = []
    static var collapses = 0
    static func left(_ n: Int, shift: Bool) { precondition(shift); arrows.append(n) }
    static func right(_ n: Int) { precondition(n == 1); collapses += 1; Focus.selected = "" }
}
enum DispatchQueue {
    static var lane = "main"
    static let main = Queue("main"), worker = Queue("worker")
    enum QoS { case userInitiated }
    static func global(qos: QoS) -> Queue { worker }
    final class Queue {
        let name: String; var pending: [() -> Void] = []
        init(_ name: String) { self.name = name }
        func async(execute: @escaping () -> Void) { pending.append(execute) }
        func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { pending.append(execute) }
        func drain() { let jobs = pending; pending = []; let old = lane; lane = name; jobs.forEach { $0() }; lane = old }
    }
}
enum Tidy { static var calls = 0; static func clean(_ text: String) -> String { calls += 1; return text } }
final class Ghost {
    static let shared = Ghost(); var visible = false; var shows = 0
    func show(_ text: String, action: [String: Any], at: Int) { precondition(DispatchQueue.lane == "main"); shows += 1 }
}
func log(_ s: String) {}

@main struct VoiceAppGuard {
    static func reset() {
        Focus.current = MockSpot(); Focus.element = 1; Focus.selected = nil; Focus.value = ""
        Focus.writes = []; Focus.pastes = []; Focus.reads = []; Focus.failWrite = false; Focus.off = false
        Fields.arrows = []; Fields.collapses = 0; Keys.shared.inputRevision = 0; secure = false
        NSWorkspace.shared.frontmostApplication = MockApp()
        DispatchQueue.main.pending = []; DispatchQueue.worker.pending = []
        Ghost.shared.visible = false; Ghost.shared.shows = 0
    }
    static func main() {
        let talk = Talk()
        talk.draft("real words")
        let prepared = Tidy.calls
        for _ in 0..<100 { precondition(talk.canSend) }
        precondition(Tidy.calls == prepared, "Return must never clean the dictionary")
        talk.long = true
        for n in 1...100 {
            let growing = String(repeating: "long recording words ", count: n * 100)
            talk.draft(growing)
            talk.liveDraft(growing)
            precondition(!talk.canSend)
        }
        precondition(Tidy.calls == prepared, "Growing long notes/calls must never run cleanup")
        talk.long = false
        talk.draft("normal take again")
        precondition(Tidy.calls == prepared + 1 && talk.canSend, "Normal takes still prepare Return")
        talk.draft(""); precondition(!talk.canSend)
        for filler in ["ага", "ok", "так", "yes"] {
            talk.draft(filler); precondition(!talk.canSend, "Intended closing-only drop stays")
        }
        talk.draft("thank you"); talk.peak = 0.01; precondition(!talk.canSend)
        talk.peak = 0.1; precondition(talk.canSend, "Peak changes still count")
        talk.sending = true; precondition(!talk.canSend); talk.sending = false
        talk.insertMode = .enter; precondition(!talk.canSend, "Return sends only in live insert mode"); talk.insertMode = .live
        talk.samples = 100; precondition(!talk.canSend)

        // Off-limits fields and secure input: no AX write, no arrow, no paste on any path.
        for blocker in 0..<2 {
            for (web, markers) in [(false, false), (true, false), (false, true)] {
                reset(); Focus.current!.app.web = web; Focus.current!.viaMarkers = markers
                if blocker == 0 { Focus.off = true } else { secure = true }
                var result: Bool? = nil
                Focus.replace("old ", with: "new ") { result = $0 }
                DispatchQueue.main.drain(); DispatchQueue.worker.drain()
                precondition(result == false, "Blocked field must refuse the replace")
                precondition(Focus.writes.isEmpty && Focus.pastes.isEmpty && Fields.arrows.isEmpty,
                             "Nothing may reach an off-limits field or a secure-input field")
            }
        }

        // Each web/marker combination bypasses AX writes and checks actual selection.
        for (web, markers) in [(true, false), (false, true), (true, true)] {
            reset(); Focus.current!.app.web = web; Focus.current!.viaMarkers = markers
            var result: Bool? = nil
            Focus.replace("old ", with: "new ") { result = $0 }
            precondition(result == nil && Focus.pastes.isEmpty && Focus.writes.isEmpty)
            precondition(Fields.arrows == [4])
            Focus.selected = "old "; DispatchQueue.main.drain()
            precondition(result == true && Focus.pastes == ["new "] && Focus.writes.isEmpty)
        }
        // Drift during arrow delivery must never paste into the changed target.
        for change in 0..<7 {
            reset(); Focus.current!.viaMarkers = true
            var result: Bool? = nil
            Focus.replace("old ", with: "new ") { result = $0 }
            Focus.selected = "old "
            switch change {
            case 0: Focus.selected = "different"
            case 1: Focus.element = 2
            case 2: NSWorkspace.shared.frontmostApplication = MockApp(processIdentifier: 2)
            case 3: Keys.shared.inputRevision += 1
            case 4: secure = true
            case 5: Focus.selected = nil // AX could not read the arrow selection
            default: Focus.selected = "" // user already collapsed it
            }
            DispatchQueue.main.drain()
            precondition(result == false && Focus.pastes.isEmpty)
            let shouldCollapse = [0, 3, 4, 5].contains(change)
            precondition(Fields.collapses == (shouldCollapse ? 1 : 0), "Recover only in the original field")
            if shouldCollapse { precondition(Focus.selected == "", "Next key must not replace selected words") }
        }
        for fail in [false, true] {
            reset(); Focus.failWrite = fail
            var result = false
            Focus.replace("old ", with: "new ") { result = $0 }
            precondition(result && Fields.arrows.isEmpty)
            precondition(fail ? Focus.pastes == ["new "] : Focus.pastes.isEmpty)
        }
        reset(); Focus.current!.before = "changed"
        Focus.replace("old ", with: "new ") { precondition(!$0) }
        precondition(Focus.writes.isEmpty && Fields.arrows.isEmpty)

        // Run the actual careful callback with deterministic queues and no AX IPC.
        for change in 0..<4 {
            reset(); talk.state = .idle; talk.started = 1
            talk.offer("better", text: "old", mine: 1)
            precondition(Focus.reads.isEmpty)
            DispatchQueue.worker.drain()
            precondition(Focus.reads == ["worker"] && Ghost.shared.shows == 0)
            if change == 1 { Keys.shared.inputRevision += 1 }
            if change == 2 { talk.started = 2 }
            if change == 3 { Ghost.shared.visible = true }
            DispatchQueue.main.drain()
            precondition(Ghost.shared.shows == (change == 0 ? 1 : 0))
        }
        print("PASS Return cache, closing words, off-limits and secure fields, rich replacement, drift and background focus")
    }
}
