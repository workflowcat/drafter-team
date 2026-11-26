// The hook for PutRules: every place that remembers an app and later pastes into it or raises it calls these.
// remember() when it opens, raise() instead of activate(), check() after a paste.
import AppKit

enum PutBack {
    /// The app to come back to: the one with the keys, never Drafter (nil then).
    static func remember() -> NSRunningApplication? {
        guard let a = Capture.keyApp(), a.processIdentifier != getpid() else { return nil }
        return a
    }
    /// The capture overlay, the deck, a scrolling capture or the markup panel is up: no accessibility asks (PutRules).
    static var captureUp: Bool {
        Capture.shared.isOpen || CaptureNote.shared.isOpen || ScrollShot.shared.isOn || MarkupEditor.shared.isOpen
    }
    static func alive(_ t: NSRunningApplication?) -> Bool { t.map { !$0.isTerminated && $0.processIdentifier != getpid() } ?? false }
    static func front(_ t: NSRunningApplication?) -> PutRules.Front {
        PutRules.front(keyPid: Capture.keyApp()?.processIdentifier, targetPid: t?.processIdentifier, ownPid: getpid())
    }

    /// Instead of `t.activate()`: true when the target holds the keys or was raised (only over Drafter itself);
    /// false when the user moved to another app (or it is gone), then nothing is raised.
    @discardableResult
    static func raise(_ t: NSRunningApplication?, _ who: String) -> Bool {
        let f = front(t), ok = alive(t)
        if f == .target, ok { return true }
        guard PutRules.mayRaise(front: f, targetAlive: ok), let t else {
            log("\(who): \(t?.bundleIdentifier ?? "no app") not raised, front \(Capture.keyApp()?.bundleIdentifier ?? "?")")
            return false
        }
        t.activate()
        return true
    }

    /// The pill when the target is not in front: names both apps.
    static func movedPill(_ t: NSRunningApplication?, what: String = "On the clipboard") -> String {
        PutRules.movedPill(front: Capture.keyApp()?.localizedName, target: t?.localizedName, what: what)
    }

    /// Before a paste into `t`: what check() compares with.
    static func before(_ t: NSRunningApplication?) -> Int { Capture.windowCount(t?.processIdentifier ?? 0) }

    /// After a paste into `t`, once the app had time to take it (and the clipboard came back): still the same app with
    /// the keys, no window lost, a field still there. Unsure: clip() puts it on the clipboard, the pill says so.
    /// `after` nil: Focus.restoreDelay + 0.15 (a paste's clipboard is back by then).
    static func check(_ t: NSRunningApplication?, windowsBefore: Int, who: String, after: Double? = nil,
                      field: (() -> Bool)? = nil, clip: @escaping () -> Void, failed: (() -> Void)? = nil, ok: (() -> Void)? = nil) {
        let pid = t?.processIdentifier ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + (after ?? Focus.restoreDelay + 0.15)) {
            let hasField = field?() ?? (Capture.targetWhyNot(t) == nil)
            if let why = PutRules.landed(target: pid, keyApp: Capture.keyApp()?.processIdentifier, windowsBefore: windowsBefore,
                                         windowsAfter: Capture.windowCount(pid), field: hasField) {
                clip()
                Pill.shared.flash(PutRules.unsurePill)
                log("\(who): put in unsure (\(why)), \(t?.bundleIdentifier ?? "?"), on the clipboard")
                failed?()
                return
            }
            ok?()
        }
    }
}

/// While a capture is up: each front-app switch, and whether the user's input (a click into another app, a key or a modifier
/// that reached another app) came just before it (PutRules.moved). Clicks and keys on Drafter's own panels are not
/// seen here (global monitors only see other apps' events; the deck's keys are taken by the tap).
final class SwitchWatch {
    static let shared = SwitchWatch()
    private var monitor: Any?
    private var token: NSObjectProtocol?
    private var lastInput: Double?
    private var last: PutRules.Moved = .unknown   // decided when the switch happens: later input does not change it
    private var stopAt: DispatchWorkItem?

    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged]) { [weak self] _ in
            self?.lastInput = Date().timeIntervalSince1970
        }
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != getpid() else { return }
            self.last = PutRules.moved(switchAt: Date().timeIntervalSince1970, lastInputAt: self.lastInput)
            log("put: front moved to \(app.bundleIdentifier ?? "?") during the capture, by \(self.last)")
        }
        let w = DispatchWorkItem { [weak self] in self?.stop() }   // never left on: 10 min at most
        stopAt = w; DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: w)
    }
    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        monitor = nil; token = nil; stopAt?.cancel(); stopAt = nil
        lastInput = nil; last = .unknown
    }
    /// How the front app last moved since start().
    var moved: PutRules.Moved { last }
}

