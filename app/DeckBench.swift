// The capture deck's open time, measured without a capture (17 November 2026, speed plan item 5, step 2).
// `--deck-bench <n> [--cold] [--fade]`: a made-up 3024×1964 picture opened in the deck n times on a spot off every screen, each
// timed from the call to Core Animation's commit (Speed.afterCommit), then closed. Without --cold the deck is warmed
// first, as the app now does at launch and when the capture overlay opens; --fade puts AppKit's window fade back (before). Never takes a picture, never writes data/,
// never opens the microphone. Run it from the preview copy (scripts/record-preview.sh builds one), never the installed app.
import AppKit

enum DeckBench {
    static func picture() -> Data {
        let w = 3024, h = 1964
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for i in 0..<200 {
            NSColor(hue: Double(i % 17) / 17, saturation: 0.3, brightness: 0.9, alpha: 1).setFill()
            NSRect(x: 0, y: i * 10, width: w, height: 10).fill()
            ("Made-up line \(i) of a sample screen" as NSString).draw(at: NSPoint(x: 20 + (i % 7) * 40, y: i * 10), withAttributes: [.font: NSFont.systemFont(ofSize: 9)])
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func run(count: Int, cold: Bool) {
        NSApplication.shared.setActivationPolicy(.accessory)
        CaptureNote.benchAt = NSPoint(x: -9000, y: -9000)
        let png = picture()
        let deck = CaptureNote.shared
        if !cold { deck.prewarm() }
        if CommandLine.arguments.contains("--fade") { deck.panel.animationBehavior = .default }   // as before step 2
        var times: [Double] = [], closes: [Double] = []
        var i = 0
        func next() {
            guard i < count else {
                let rest = Array(times.dropFirst()).sorted(), cs = closes.sorted()
                func q(_ a: [Double], _ p: Double) -> Int { a.isEmpty ? 0 : Int(a[min(a.count - 1, Int(Double(a.count) * p))] * 1000) }
                print("deck bench\(cold ? " (cold)" : "")\(CommandLine.arguments.contains("--fade") ? " (fade)" : ""): first open \(Int(times[0] * 1000)) ms; then p50 \(q(rest, 0.5)) p90 \(q(rest, 0.9)) ms over \(rest.count); close p50 \(q(cs, 0.5)) p90 \(q(cs, 0.9)) ms")
                exit(0)
            }
            i += 1
            let t0 = Date()
            deck.open(png: png, row: [:], origin: nil, t0: t0)
            Speed.afterCommit {
                times.append(Date().timeIntervalSince(t0))
                let c0 = Date()
                deck.close()
                Speed.afterCommit {
                    closes.append(Date().timeIntervalSince(c0))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { next() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
        NSApplication.shared.run()
    }
}
