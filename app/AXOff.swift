// Accessibility reads off the main thread (17 November 2026, speed plan item 5, step 5). A busy app answers AX calls
// late (macOS waits up to 6 s by default); read on main, that froze Drafter: the voice press's field read took 177 ms
// on average and up to 919 ms in the slow presses of app.log. Here every AX call waits at most `timeout`, and reads that
// nothing draws from at once run on one serial queue per app. Drafter's own windows are never read off main (AGENTS.md
// "Never"; a deadlock on 2026-11-03): with Drafter in front the read runs on main, and Focus.offLimits refuses the rest.
import AppKit
import ApplicationServices

enum AXOff {
    /// The longest any Accessibility call waits for an app, in seconds.
    static let timeout: Float = 0.2

    /// Set on the system-wide element, the timeout is the default for every element (at launch, and wherever the
    /// system-wide element is used: one value, not 0.15 here and 0.25 there).
    static func setGlobal() { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout) }

    private static let lock = NSLock()
    private static var queues: [pid_t: DispatchQueue] = [:]

    /// One serial queue per app: a hung app holds only its own reads.
    static func queue(_ pid: pid_t) -> DispatchQueue {
        lock.lock(); defer { lock.unlock() }
        if let q = queues[pid] { return q }
        if queues.count > 64 { queues.removeAll() }   // old processes' queues go; the next read makes one again
        let q = DispatchQueue(label: "drafter.ax.\(pid)", qos: .userInitiated)
        queues[pid] = q
        return q
    }

    /// `read` on the front app's queue, then `then` with its result on main. Called on main. Drafter in front (or no
    /// front app): both run here, on main, at once.
    static func read<T>(_ read: @escaping () -> T, then: @escaping (T) -> Void) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? getpid()
        if pid == getpid() || !Thread.isMainThread { then(read()); return }
        queue(pid).async { let v = read(); DispatchQueue.main.async { then(v) } }
    }
}
