// Opt-in screen.mp4 beside a call's audio. Main owns capture state; the writer owns encoding and disk IO.
import AppKit
import Carbon
import os
import ScreenCaptureKit

final class ScreenVideoRecorder {
    private let recording: URL
    private let clock: () -> Double
    private let writer: ScreenVideoWriter
    private var timer: Timer?
    private var running = false, busy = false, didStop = false
    private var content: SCShareableContent?, contentAt = Date.distantPast
    private var backoff = Backoff(first: 15, most: 300)
    private var frames = 0, skipped = 0, failures = 0
    /// Monotonic token shared with the writer queue via a lock (encoder never blocks on the main queue).
    private let tokenLock = OSAllocatedUnfairLock(initialState: 0)
    private var appObserver: NSObjectProtocol?

    init(recording: URL, clock: @escaping () -> Double) {
        self.recording = recording
        writer = ScreenVideoWriter(recording: recording); self.clock = clock
    }

    private func bumpToken() -> Int {
        tokenLock.withLock { state in state += 1; return state }
    }

    private func currentToken() -> Int {
        tokenLock.withLock { $0 }
    }

    func start() {
        guard !running, !didStop else { return }
        running = true
        Self.sweepOrphans(in: recording.deletingLastPathComponent())
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in _ = self?.bumpToken() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    /// Invalidates an in-flight frame across a pause/resume, even if the callback arrives after resume.
    func pauseChanged() { _ = bumpToken() }

    func stop(completion: @escaping () -> Void = {}) {
        running = false; _ = bumpToken(); timer?.invalidate(); timer = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver); self.appObserver = nil }
        guard !didStop else { completion(); return }
        didStop = true
        writer.stop(at: clock()) { [self] ok in
            log("screen video: frames \(frames), skipped \(skipped), failures \(failures), saved \(ok ? 1 : 0)")
            completion()
        }
    }

    /// Remove stale `.screen-*.mp4` temp files older than 24 h left behind by a crash during finalization.
    private static func sweepOrphans(in callsDir: URL, maxAge: TimeInterval = 86400) {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let folders = try? fm.contentsOfDirectory(at: callsDir, includingPropertiesForKeys: nil) else { return }
            let cutoff = Date().addingTimeInterval(-maxAge)
            for folder in folders {
                guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for item in items where item.lastPathComponent.hasPrefix(".screen-") && item.pathExtension == "mp4" {
                    let mtime = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    if mtime < cutoff { try? fm.removeItem(at: item) }
                }
            }
        }
    }

    /// No titles or text are read. Shared privacy check used by both screen video and call screenshots.
    static func mayCaptureFrontApp(display: CGDirectDisplayID = CGMainDisplayID()) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return !ScreenVideoRules.shouldSkipFrame(frontApp: front.localizedName ?? "", bundleID: front.bundleIdentifier ?? "",
            skipList: Drafter.shared.settings.skip, screenLocked: Screen.locked,
            displayAsleep: CGDisplayIsAsleep(display) != 0, secureInput: IsSecureEventInputEnabled())
    }

    private func allowed(display: CGDirectDisplayID = CGMainDisplayID()) -> Bool {
        guard running, !Talk.shared.paused, Drafter.shared.settings.callScreenVideo else { return false }
        return Self.mayCaptureFrontApp(display: display)
    }

    private func tick() {
        guard running, !busy, backoff.allowed() else { return }
        guard ScreenVideoRules.canAppend(writtenBytes: 0, elapsed: clock()) else { stop(); return }
        guard allowed(), Screen.allowed || CGPreflightScreenCaptureAccess() else { skipped += 1; return }
        busy = true
        let token = currentToken()
        if let content, Date().timeIntervalSince(contentAt) < 5 { capture(content, token: token); return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.running, self.currentToken() == token else { self.busy = false; return }
                guard let content else { self.failed(); return }
                self.content = content; self.contentAt = Date()
                self.capture(content, token: token)
            }
        }
    }

    private func capture(_ content: SCShareableContent, token: Int) {
        guard running, currentToken() == token, allowed(), let (display, _) = Shots.target(content), allowed(display: display.displayID) else {
            skipped += 1; busy = false; return
        }
        // Application exclusions also hide windows created after shareable-content discovery (including our overlays).
        let skip = Drafter.shared.settings.skip
        let hidden = content.applications.filter { app in
            return app.processID == getpid() || ScreenVideoRules.shouldSkipFrame(frontApp: app.applicationName,
                bundleID: app.bundleIdentifier, skipList: skip, screenLocked: false, displayAsleep: false, secureInput: false)
        }
        let filter = OwnChrome.filter(display, excludingApplications: hidden)
        let size = ScreenVideoRules.clampedDimensions(width: display.width, height: display.height)
        let config = SCStreamConfiguration()
        config.width = size.width; config.height = size.height; config.showsCursor = true
        let t = clock(), pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.running, self.currentToken() == token, self.allowed(display: display.displayID),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    self.skipped += 1; self.busy = false; return
                }
                guard let image else { self.failed(); return }
                self.writer.append(image, at: t, allowed: { [weak self] in
                    guard let self else { return false }
                    return self.currentToken() == token
                }) { [self] answer in
                    self.busy = false
                    switch answer {
                    case .appended: self.frames += 1; _ = self.backoff.succeeded()
                    case .skipped: self.skipped += 1
                    case .stopped: if self.running { self.stop() }
                    case .failed: self.failures += 1; if self.running { self.stop() }
                    }
                }
            }
        }
    }

    private func failed() { busy = false; failures += 1; _ = backoff.failed() }
}

extension OwnChrome {
    /// Video hides all own windows, including future ones; still captures retain their existing window filter.
    static func filter(_ display: SCDisplay, excludingApplications apps: [SCRunningApplication]) -> SCContentFilter {
        SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
    }
}
