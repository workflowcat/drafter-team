// swift-runner: skip (built by its Python runner)
// Compiled with the actual VoiceEngine class and a synthetic stdin/stdout worker by the runner.
import Foundation

enum Home {
    static let root = URL(fileURLWithPath: CommandLine.arguments[1])
    static let data = root.appendingPathComponent("data")
    static let python = URL(fileURLWithPath: CommandLine.arguments[2])
    static let words = data.appendingPathComponent("words.json")   // the dictionary the engine gets as DRAFTER_WORDS
}
func log(_ text: String) {}
// same as app/Main.swift: the voice log is opened for appending (log rotation, 2026-11-13)
func appendHandle(_ url: URL) -> FileHandle? {
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    return fd < 0 ? nil : FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}
final class Drafter {
    static let shared = Drafter()
    struct Settings { var voice = true; var voiceIdleMin = 30 }
    var settings = Settings()
}
final class Talk {
    static let shared = Talk()
    enum State { case idle, listening }
    var state = State.idle
    var failures = 0
    func engineFailed() { failures += 1; state = .idle }
    func engineAwake() {}
}
@main struct LifecycleChecks {
    static func spin(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    static func wait(_ label: String, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !condition(), Date() < end { spin(0.01) }
        precondition(condition(), label)
    }
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        let e = VoiceEngine.shared
        var drafts = [String]()
        e.onDraft = { drafts.append($0) }
        e.warm()
        wait("first worker starts") { drafts.count == 1 }
        e.feed([0]) // worker emits a partial JSON line
        spin(0.15)
        var ended = 0
        e.finish { text, _ in precondition(text.isEmpty); ended += 1 }
        e.stop() // cancels pending finish, then start before the old termination callback arrives
        precondition(ended == 1)
        e.warm()
        wait("replacement output is not corrupted by old partial line") { drafts.count == 2 }
        spin(0.25)
        precondition(e.running && Talk.shared.failures == 0, "old exit cannot clear replacement")
        var final = ""
        e.finish { text, _ in final = text }
        wait("replacement receives its own response") { final == "synthetic final" }
        e.drop() // fixture simulates memory-guard exit
        wait("crash reaches take recovery") { Talk.shared.failures == 1 }
        wait("one automatic restart") { drafts.count == 3 }
        precondition(e.running)
        e.drop()
        wait("second crash") { Talk.shared.failures == 2 }
        e.stop() // cancel the scheduled automatic restart even though the process has already exited
        spin(3.3)
        precondition(!e.running && drafts.count == 3, "stop must cancel queued restart")
        precondition(ended == 1, "pending completion delivered exactly once")
        print("PASS: old exits, partial output, pending callbacks, crash recovery and restart cancellation")
    }
}
