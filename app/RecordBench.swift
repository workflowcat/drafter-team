// The recording window's CPU, measured without a recording (17 November 2026, "recording feels a little heavy").
// `--record-bench <seconds> [--hidden]`: the window on a spot off every screen, fed made-up levels at 100 per second (as audio
// buffers come), the time once a second and made-up words once a second; prints the process's CPU over the run.
// Never opens the microphone, never writes data/, never shows the notch. Run it from the preview copy
// (scripts/record-preview.sh builds one), never the installed app.
import AppKit
import SwiftUI

enum RecordBench {
    static func run(seconds: Double) {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let m = RecordLive.shared
        m.active = true; m.call = true; m.title = "Sample sync"
        let hidden = CommandLine.arguments.contains("--hidden")   // the window closed: what a recording costs then
        #if !OLDPACE
        RecordLive.shows = { !hidden }
        #endif
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 360, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: RecordView(m: m))
        if !hidden { w.orderFrontRegardless() }
        #if !OLDPACE
        m.flush()
        #endif
        let words = ["the", "sample", "window", "keeps", "notes", "while", "both", "sides", "talk", "about", "the", "plan"]
        var said = "", n = 0, k = 0
        let level = Timer(timeInterval: 0.01, repeats: true) { _ in
            k += 1
            m.level(Float(0.05 + 0.4 * abs(sin(Double(k) / 7))), them: Float(0.05 + 0.3 * abs(cos(Double(k) / 11))))
        }
        let tick = Timer(timeInterval: 1, repeats: true) { _ in
            n += 1; m.seconds = n
            said += (said.isEmpty ? "" : " ") + (0..<6).map { words[($0 + n) % words.count] }.joined(separator: " ")
            m.heard(said)
        }
        RunLoop.main.add(level, forMode: .common); RunLoop.main.add(tick, forMode: .common)
        func cpu() -> Double {
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2))      // first draw and warm-up, not counted
        let c0 = cpu(), t0 = Date()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let used = cpu() - c0, wall = Date().timeIntervalSince(t0)
        print(String(format: "record bench\(hidden ? " (hidden)" : ""): %.1f%% CPU over %.0f s (%.2f s CPU), %d level calls", used / wall * 100, wall, used, k))
        exit(0)
    }
}
