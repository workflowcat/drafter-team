// Background jobs on the team server, started from the app (17 November 2026): a careful re-transcribe of one
// recording on demand. The queue and the driver are bench/jobs.py; this only queues the job and runs what is due, in
// the background. Nothing waits for it: the recording page shows the careful text when careful.json comes back, and
// when the server cannot be reached the job stays queued for the next run (or the nightly).
import Foundation

enum Jobs {
    static var script: URL { Home.root.appendingPathComponent("bench/jobs.py") }

    /// `jobs.py add careful <dir>` then `jobs.py run`; `done` on the main thread with the run's exit status.
    static func careful(_ dir: URL, done: @escaping (Int32) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            func run(_ args: [String]) -> Int32 {
                let p = Process(); p.executableURL = Home.python
                p.arguments = ["-B", script.path] + args
                p.currentDirectoryURL = Home.root
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return -1 }
                p.waitUntilExit(); return p.terminationStatus
            }
            let added = run(["add", "careful", dir.path])
            let status = added == 0 ? run(["run", "--max", "3"]) : added
            DispatchQueue.main.async { done(status) }
        }
    }
}

extension WindowModel {
    func readCarefully(_ d: CallDoc) {
        status = "Sent to the team server for a careful reading"
        log("jobs: careful reading queued for \(d.dir.lastPathComponent)")
        Jobs.careful(d.dir) { [weak self] code in
            guard let self else { return }
            self.loadDocs()
            let back = FileManager.default.fileExists(atPath: d.dir.appendingPathComponent(CarefulTranscript.file).path)
            self.status = back ? "The careful transcript is here" : "The careful reading waits for the server; it runs again tonight"
            log("jobs: careful run for \(d.dir.lastPathComponent) exited \(code), back \(back)")
        }
    }
}
