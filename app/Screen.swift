// Screen reading (Andrii, 2026-10-19; Cotypist does the same): a picture of the window above the field, read on this
// Mac with Vision (Ukrainian + English). The picture is never stored; only the text goes to the local engine. Needs
// Screen Recording for Drafter (asked once). Since 14 November 2026 the capture, the reading as a conversation and the
// cache live in app/ScreenContext.swift; this file keeps the permission state and the plain reading.
import AppKit
import ScreenCaptureKit
import Vision

enum Screen {
    /// false only after a capture was refused (the preflight call lags behind the switch in System Settings).
    /// Written in ScreenCaptureKit's callbacks, read on main: under `lock` (Argon 23).
    static var allowed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allowed }
        set { lock.lock(); _allowed = newValue; lock.unlock() }
    }
    private static var _allowed = true
    private static var asked = false
    private static let lock = NSLock()

    /// Screen Recording was refused: no capture until a later one works; the system asks once per run, never again.
    static func refused() {
        lock.lock(); let first = _allowed; _allowed = false; let ask = !asked; asked = true; lock.unlock()
        if first { log("screen context: Screen Recording not granted, no screen reading") }
        if ask { DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() } }
    }

    static func succeeded() {
        lock.lock(); let back = !_allowed; _allowed = true; let was = backoff.succeeded(); lock.unlock()
        if back { log("screen context: Screen Recording works again") }
        if was { log("screen capture: working again") }
    }

    /// The ⌃⌥S capture failed (app/Capture.swift): one log line per new wait. Screen context keeps its own per-app
    /// memory (ScreenContextRules.AppMemory): one app failing no longer stops reading in every other one.
    private static var backoff = Backoff(first: 30, most: 600)
    @discardableResult
    static func failed() -> Bool {
        lock.lock(); let (wait, tell) = backoff.failed(); let n = backoff.failures; lock.unlock()
        if tell { log("screen capture: failure \(n) in a row, next log after \(Int(wait)) s") }
        return tell
    }

    /// Plain text of the window part above the caret (the debug read in Focus), through the one capture path.
    /// Blocks the calling (background) thread up to `wait`.
    static func textAbove(pid: pid_t, caret: CGRect, wait: Double = 1.5) -> String {
        guard pid != getpid(), let el = Focus.focused() else { return "" }
        return ScreenContext.shared.read(el, pid: pid, caret: caret, wait: wait)
    }

    /// The login screen is up (screen locked).
    static var locked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Vision text reading, top to bottom.
    static func read(_ image: CGImage) -> String {
        ScreenContext.lines(image).sorted { $0.y < $1.y }.map { $0.text }.joined(separator: "\n")
    }
}
