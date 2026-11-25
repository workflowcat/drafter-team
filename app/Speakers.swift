// Who said each line of a call (17 November 2026: a client demo call came out with every line his). After a call is
// read, or recordings are combined, engine/speakers.py places each line's voice locally: his (his voice print), a
// person of the other side ("Speaker 2", or their name when the match is clear), or "unknown". It rewrites
// lines.json and transcript.txt; here brief.md is written again from them, and the caller goes on with the new lines
// (the note, the board). Without the script, the model or in time, the lines stay as they were and it is logged.
import Foundation

enum Speakers {
    /// Runs engine/speakers.py on a call folder off the main thread; `done(true)` on main once lines.json was rewritten.
    static func run(_ dir: URL, timeout: Double = 600, done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = Home.python
            p.arguments = [Home.root.appendingPathComponent("engine/speakers.py").path, dir.path]
            let out = Pipe()
            p.standardOutput = out
            if let h = appendHandle(Home.data.appendingPathComponent("voice-engine.log")) { p.standardError = h }
            let started = Date()
            do { try p.run() } catch {
                log("speakers: did not start (\(error.localizedDescription)); lines keep their track labels")
                DispatchQueue.main.async { done(false) }
                return
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            let j = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
            let ok = p.terminationStatus == 0 && j?["lines"] != nil
            if ok, let j {
                // counts per label only, never the text (AGENTS.md "Privacy for agents")
                let counts = (j["counts"] as? [String: Any] ?? [:]).map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")
                log(String(format: "speakers: %@ in %@: %@; %@ placed by voice, %@ echo lines dropped, other side alive %@ min, %.0f s",
                           "\(j["lines"] ?? 0) lines", dir.lastPathComponent, counts, "\(j["by_voice"] ?? 0)",
                           "\(j["echo_dropped"] ?? 0)", "\(j["them_alive_min"] ?? 0)", Date().timeIntervalSince(started)))
            } else if j?["skipped"] != nil {
                log("speakers: \(dir.lastPathComponent) skipped (\(j?["skipped"] ?? ""))")
            } else {
                log("speakers: \(dir.lastPathComponent) failed, exit \(p.terminationStatus) (data/voice-engine.log); lines keep their track labels")
            }
            if ok { rewriteBrief(dir) }
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// The rows of lines.json as the brief takes them.
    static func rows(_ dir: URL) -> [Brief.Row] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("lines.json")), let r = MergeRules.rows(lines: d) else { return [] }
        return r.map { Brief.Row(who: $0.who, start: $0.start, text: $0.text) }
    }

    /// brief.md again from the new lines, when the folder has one.
    static func rewriteBrief(_ dir: URL) {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("brief.md").path) else { return }
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("me.wav").path)[.size] as? Int) ?? 0
        Brief.write(dir: dir, rows: rows(dir), shots: Shot.load(dir), meta: meta, minutes: Double(size) / 32000 / 60)
    }
}
