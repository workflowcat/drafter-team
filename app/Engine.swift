// The text engine process (engine/server.py) and the app's HTTP calls to it.
import AppKit

// MARK: engine process

final class Engine {
    static let shared = Engine()
    var proc: Process?
    var wanted = false
    var ready = false
    var info = "starting"
    var restarts: [Date] = []
    var clearedLeftovers = false

    func start() {
        wanted = true
        guard proc == nil else { return }
        if !clearedLeftovers {   // an engine left from an earlier app run holds the port; only once, at app start
            clearedLeftovers = true
            let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-f", Home.server.path]
            try? k.run(); k.waitUntilExit()
        }
        let p = Process()
        p.executableURL = Home.python
        p.arguments = [Home.server.path]
        var env = ProcessInfo.processInfo.environment
        env["DRAFTER_CAP_GB"] = env["DRAFTER_CAP_GB"] ?? "3.6"
        let st = Settings.load()
        if let m = st.model { env["DRAFTER_MODEL"] = m }
        if let a = st.adapter { env["DRAFTER_ADAPTER"] = a.hasPrefix("/") ? a : Home.root.appendingPathComponent(a).path }
        if let f = st.fmt { env["DRAFTER_FMT"] = f }
        p.environment = env
        if let h = appendHandle(Home.data.appendingPathComponent("engine.log")) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { [weak self] t in
            DispatchQueue.main.async {
                // only the engine running now counts: an old one ending after a model switch must not touch the new
                guard let self, self.proc === t else { return }
                self.proc = nil; self.ready = false
                log("engine exited \(t.terminationStatus)")
                guard self.wanted else { self.info = "stopped"; Menu.shared.refresh(); return }
                self.restarts = self.restarts.filter { $0.timeIntervalSinceNow > -300 } + [Date()]
                if self.restarts.count > 4 { self.info = "engine keeps stopping, see data/engine.log"; self.wanted = false; Menu.shared.refresh(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.wanted { self.start() } }
            }
        }
        do { try p.run(); proc = p; info = "loading model"; startedAt = Date() } catch { info = "cannot start engine: \(error)" }
        poll()
    }

    func stop() {
        wanted = false; ready = false
        cancelStreams()
        proc?.terminate(); proc = nil
        info = "stopped"
    }

    private var startedAt: Date?
    func poll(_ tries: Int = 0) {
        get("/health") { j in
            if let j, j["ok"] as? Bool == true {
                self.ready = true
                Connect.handOver()   // an API key from the Keychain into the engine's memory (never a file or argv)
                // launch to ready, for the efficiency notes (polled every 0.5 s, so up to 0.5 s late)
                if let t = self.startedAt { log(String(format: "engine: ready %.1f s after start", Date().timeIntervalSince(t))); self.startedAt = nil }
                let m = (j["model"] as? String ?? "").split(separator: "/").last.map(String.init) ?? ""
                self.info = "\(m) · \(String(format: "%.1f", j["rss_gb"] as? Double ?? 0)) GB · \(j["words"] as? Int ?? 0) words"
                Menu.shared.refresh()
            } else if self.proc != nil, tries < 120 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.poll(tries + 1) }
            }
        }
    }

    /// Dedicated local sessions: no disk/memory URLCache or cookie overhead on 127.0.0.1, higher connection cap for
    /// typing, and a separate session for long-lived /pending polls so they never occupy a typing connection slot.
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 12
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
    private let pollSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 2
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
    private var streamTasks: [(id: Int, keepOn: Bool, task: Task<Void, Never>)] = []
    private var streamSeq = 0

    /// Abort any in-flight /complete streams (Esc, click, shortcut, stop). Main thread safe.
    func cancelStreams() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.cancelStreams() }; return }
        streamTasks.forEach { $0.task.cancel() }
        streamTasks.removeAll()
    }

    private func finishStream(_ id: Int) {
        streamTasks.removeAll { $0.id == id }
    }

    /// Two-step ghost (round two, 2026-11-13): the engine answers one JSON object per line, the first words as soon as
    /// they exist, then the whole answer ("final": true). `each` gets every line before the last on the main thread,
    /// `done` the last one (nil on an error), as `post` does.
    func stream(_ path: String, _ body: [String: Any], timeout: Double = 3, each: @escaping ([String: Any]) -> Void,
                _ done: @escaping ([String: Any]?) -> Void) {
        Budget.request(path)
        let req = request(path, body.merging(["stream": true]) { _, b in b }, timeout: timeout)
        let keepOn = (body["keep_on"] as? Bool) == true
        let start: () -> Void = {
            let victims = Set(EngineTransportRules.idsToCancel(active: self.streamTasks.map { ($0.id, $0.keepOn) }, keepOn: keepOn))
            if !victims.isEmpty {
                for item in self.streamTasks where victims.contains(item.id) { item.task.cancel() }
                self.streamTasks.removeAll { victims.contains($0.id) }
            }
            self.streamSeq += 1
            let id = self.streamSeq
            let sess = self.session
            let task = Task.detached {
                var last: [String: Any]?
                var gotAny = false
                for attempt in 0..<2 {
                    if Task.isCancelled { break }
                    do {
                        let (bytes, _) = try await sess.bytes(for: req)
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                            gotAny = true
                            if j["final"] as? Bool == true { last = j; break }
                            DispatchQueue.main.async { each(j) }
                        }
                        break
                    } catch {
                        let ns = error as NSError
                        if !Task.isCancelled && EngineTransportRules.shouldRetry(method: "POST", path: path, errorDomain: ns.domain, errorCode: ns.code, attempt: attempt, receivedAnyData: gotAny) {
                            continue
                        }
                        break
                    }
                }
                let end = last
                DispatchQueue.main.async {
                    Engine.shared.finishStream(id)
                    done(end)
                }
            }
            self.streamTasks.append((id, keepOn, task))
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
    }

    func get(_ path: String, timeout: Double = 2, longPoll: Bool = false, _ done: @escaping ([String: Any]?) -> Void) {
        send(request(path, nil, timeout: timeout), via: longPoll ? pollSession : session, done)
    }

    func post(_ path: String, _ body: [String: Any], timeout: Double = 3, _ done: @escaping ([String: Any]?) -> Void = { _ in }) {
        Budget.request(path)
        send(request(path, body, timeout: timeout), via: session, done)
    }

    /// A GET without a body, else a JSON POST, to the engine on 127.0.0.1.
    private func request(_ path: String, _ body: [String: Any]?, timeout: Double) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(Home.port)\(path)")!)
        r.timeoutInterval = timeout
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// The answer as a JSON object (nil on any error), on the main thread. Retries once on -1005 for safe read-only paths.
    private func send(_ r: URLRequest, via sess: URLSession, attempt: Int = 0, _ done: @escaping ([String: Any]?) -> Void) {
        let method = r.httpMethod ?? "GET"
        let path = r.url?.path ?? ""
        sess.dataTask(with: r) { d, _, err in
            if d == nil, let ns = err as NSError?,
               EngineTransportRules.shouldRetry(method: method, path: path, errorDomain: ns.domain, errorCode: ns.code, attempt: attempt, receivedAnyData: false) {
                self.send(r, via: sess, attempt: attempt + 1, done)
                return
            }
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(j) }
        }.resume()
    }
}

/// How much memory the Mac has free, as macOS itself counts it (kern.memorystatus_level, %). Under `low` a long
/// reading puts the text model to sleep (2026-11-01, Andrii: "not to overload the Mac").
enum Budget {
    static let low = 35
    /// Readings that want the text model asleep, and one request at a time to the engine: what the engine should
    /// be is the only thing compared, so a fast reading, two readings at once or a sleep right after a wake always
    /// end in the right state (Codex round 4). Main thread only.
    private static var holds = 0, asleep = false, busy = false, secs = 120.0

    /// Idle sleep (2026-11-14): no typing request for `textIdleMin` minutes -> the text model sleeps (~2.2 GB back);
    /// focus arriving in a text field (/prefill, Keys.warmField) or any typing request wakes it, and the field is
    /// prefilled again once it is back, so the first ghost costs what it did before. One-off prompts load it on demand.
    private static var idle = false, lastTyping = Date(), wokeFor: Date?
    static var isAsleep: Bool { asleep || idle }
    static let typingPaths: Set<String> = ["/complete", "/prefill", "/chip"]

    /// Engine.post / stream: a typing request is a sign of life; while idle-asleep it wakes the model.
    static func request(_ path: String) {
        guard typingPaths.contains(path) else { return }
        guard Thread.isMainThread else { DispatchQueue.main.async { request(path) }; return }
        lastTyping = Date()
        guard idle else { return }
        idle = false; wokeFor = Date()
        log("memory: text model wakes (\(path))")
        sync()
    }

    /// Every second (the app's 1 s timer): asleep after `textIdleMin` minutes without typing, never mid-take.
    static func idleCheck() {
        let mins = Drafter.shared.settings.textIdleMin
        guard mins > 0, !idle, Talk.shared.state == .idle, Date().timeIntervalSince(lastTyping) > Double(mins) * 60 else { return }
        idle = true
        log("memory: text model idle \(mins) min, sleeps")
        sync()
    }

    /// Memory pressure (app/PressureRules.swift): the idle text model sleeps first so voice keeps Parakeet's pages;
    /// a typing request wakes it as after an idle sleep. Started once at launch.
    private static var pressureSource: DispatchSourceMemoryPressure?
    static func watchPressure() {
        guard pressureSource == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler {
            let e = src.data
            let level: PressureRules.Level = e.contains(.critical) ? .critical : e.contains(.warning) ? .warning : .normal
            let quiet = Date().timeIntervalSince(lastTyping)
            guard PressureRules.yieldText(level, typingQuiet: quiet, asleep: idle || asleep) else {
                log("memory: pressure \(level.rawValue), text model stays (typed \(Int(quiet)) s ago\(idle || asleep ? ", asleep" : ""))"); return
            }
            idle = true
            log("memory: pressure \(level.rawValue), text model sleeps so voice keeps its memory (typed \(Int(quiet)) s ago)")
            sync()
        }
        src.resume()
        pressureSource = src
    }

    static func rest(secs s: Double, why: String) {
        holds += 1; secs = max(secs, s)
        log("memory: text model steps aside (\(why))")
        sync()
    }

    static func wake() { holds = max(0, holds - 1); sync() }

    private static func sync() {
        let want = holds > 0 || idle
        guard !busy, want != asleep else { return }
        busy = true
        // a reading's sleep has a timer in the engine; an idle one has none (only a wake ends it)
        let body: [String: Any] = holds > 0 ? ["secs": secs] : ["idle": true]
        Engine.shared.post(want ? "/sleep" : "/wake", want ? body : [:], timeout: 30) { j in
            busy = false
            if want {
                asleep = j?["slept"] != nil
                log("memory: text model asleep, \(j?["claude_stopped"] as? Int ?? 0) idle Claude helpers stopped")
            } else {
                asleep = false; secs = 120
                let ms = wokeFor.map { Int(Date().timeIntervalSince($0) * 1000) }
                log("memory: text model back (\(j?["woke"] as? Bool == true ? "ok" : "later"))" + (ms.map { ", \($0) ms after the wake sign, load \(j?["load_s"] as? Double ?? 0) s" } ?? ""))
                if wokeFor != nil { wokeFor = nil; Keys.shared.warmField() }   // the field's prefill hit a sleeping model
            }
            if j != nil { sync() }   // the engine down: nothing to put to sleep; its own timer wakes it anyway
        }
    }

    static func free() -> Int {
        var v: Int32 = 0
        var n = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &v, &n, nil, 0) == 0 ? Int(v) : -1
    }
}
