import AppKit
import ApplicationServices

// swiftc -parse-as-library app/Focus.swift app/AXOff.swift app/GhostRules.swift app/AnchorRules.swift app/PutRules.swift app/InsertRules.swift app/PutCheckRules.swift tests/focus_own_pid.swift -o app/build/focus-own-pid-test && app/build/focus-own-pid-test
// 3 November 2026: a background Accessibility read of Drafter's own window waited for the main thread while main
// waited in another AX call, and his side of a 53-minute call was lost. Off the main thread, Focus must never ask its
// own process, and must answer at once even while main is blocked. (No Accessibility grant is needed: the guard
// answers before any AX message is sent.)

// stand-ins for the app parts Focus.swift touches
// skipChange: Focus.paste calls it since 4e6e76c (Quick panel, 2026-11-14); the stand-in lacked it and this test
// stopped compiling
enum History { static let ownType = NSPasteboard.PasteboardType("drafter.test.own"); static func skipChange(_ count: Int) {} }
enum Screen { static var allowed = true; static func textAbove(pid: pid_t, caret: CGRect) -> String { "" } }
// Keys, Fields: Focus.replace (moved from Voice.swift, 2026-11-16) reads the input revision and selects with arrows
final class Keys { static let shared = Keys(); var inputRevision = 0 }
enum Fields { static func left(_ n: Int, shift: Bool) {}; static func right(_ n: Int) {} }
// PutBack: Focus skips accessibility asks while a capture is up (2026-11-17, lost shots)
enum PutBack { static var captureUp = false }
var logged: [String] = []
let logLock = NSLock()
func log(_ s: String, file: String = "app.log") { logLock.lock(); logged.append(s); logLock.unlock() }

@main
struct FocusOwnPid {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        let me = AXUIElementCreateApplication(getpid())
        let other = AXUIElementCreateApplication(1)   // launchd: some other process
        check(!Focus.offLimits(me), "on the main thread its own elements may be read")
        check(!Focus.offLimits(pid: getpid()), "on the main thread its own pid may be asked")

        // main blocked in a wait, as it was inside Shots.tick -> windowTitle
        let done = DispatchSemaphore(value: 0)
        var results: [String: Bool] = [:]
        var elapsed = 0.0
        DispatchQueue.global().async {
            let t0 = Date()
            results["offLimits own"] = Focus.offLimits(me)
            results["offLimits own pid"] = Focus.offLimits(pid: getpid())
            results["offLimits other"] = !Focus.offLimits(other)
            results["offLimits other pid"] = !Focus.offLimits(pid: 1)
            results["attr own is nil"] = (Focus.attr(me, kAXTitleAttribute) as String?) == nil
            results["windowTitle own is empty"] = Focus.windowTitle(NSRunningApplication.current) == ""
            results["screenContext own is empty"] = Focus.screenContext(me) == ""
            results["markers own is nil"] = Focus.markers(me) == nil
            results["selectionRect own is nil"] = Focus.selectionRect(me) == nil
            results["bounds own is nil"] = Focus.bounds(me, 0, 1) == nil
            results["font own is nil"] = Focus.font(me, caret: 3) == nil
            elapsed = Date().timeIntervalSince(t0)
            done.signal()
        }
        let ok = done.wait(timeout: .now() + 5) == .success
        check(ok, "background reads of its own window return while main is blocked (no deadlock)")
        for (k, v) in results.sorted(by: { $0.key < $1.key }) { check(v, k) }
        check(elapsed < 0.5, "they answer at once (\(elapsed) s)")
        // Argon 4: the system-wide element has no pid; off main it is off limits exactly while Drafter is in front
        var sysOff: Bool?
        let sysDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { sysOff = Focus.offLimits(Focus.system); sysDone.signal() }
        sysDone.wait()
        check(sysOff == Focus.ownInFront, "system-wide element follows ownInFront off main")
        // Argon 3: spot() runs on main and off it; the app it saw and the per-process caches take a lock
        // (run with -sanitize=thread to see a race; without the lock this can also crash outright)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() }.prefix(8)
        DispatchQueue.concurrentPerform(iterations: 4000) { i in
            let a = apps[apps.startIndex + i % apps.count]
            Focus.lastApp = a
            _ = Focus.isWeb(a)
            _ = Focus.lastApp
        }
        check(true, "concurrent lastApp / isWeb survive (a smoke check: the old code passed it too in three runs)")
        check(logged.contains { $0.contains("skipped off the main thread") }, "a skipped read is logged")
        check(logged.filter { $0.contains("skipped off the main thread") }.count == 1, "logged once, not per read")
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("focus own pid: all passed")
    }
}
