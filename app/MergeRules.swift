import Foundation

// Combining recordings and voice takes of the same talk into one recording (Andrii recorded one talk twice: a call or
// long note plus short voice takes). Pure core, Foundation only: which sources belong together, one timeline of their
// lines, and writing the combined folder (meta.json, lines.json, transcript.txt, me.wav, them.wav).
// Test: tests/merge_rules.swift.

/// One line. `track` is the file it was heard in ("me": his mic, "them": the Mac's sound, "" not known) and `end` its
/// end when known: engine/speakers.py places each line's voice from them (17 November 2026).
struct MergeRow: Equatable { var who: String; var start: Double; var text: String; var track = ""; var end: Double? = nil }

struct MergeSource: Equatable {
    enum Kind: String { case recording, take }
    var id: String            // a recording's folder path, or a take's id
    var kind: Kind
    var start: Double         // unix seconds
    var secs: Double
    var call = false
    var app = ""
    var rows: [MergeRow]      // start relative to this source's own start
    var me: URL?              // wav of his side (a take's wav goes here)
    var them: URL?
    var end: Double { start + secs }
}

enum MergeRules {
    static let gap: Double = 600
    static let rate = 16000
    static let header = 44
    /// Two rows from different sources repeat each other within this many seconds.
    static let echoWindow: Double = 20
    /// Share of the shorter row's words found in the other row.
    static let echoShare = 0.8
    /// A line no one could be placed on yet (a voice take recorded during a call: the mic hears the other side too).
    static let unknown = "unknown"

    /// The track a row was heard in, from its own track or its first label ("Я" mic, "Вони" the Mac's sound).
    static func track(_ r: MergeRow) -> String {
        if !r.track.isEmpty { return r.track }
        return r.who == "Я" ? "me" : r.who == "Вони" ? "them" : ""
    }

    /// lines.json rows -> MergeRows with their track and end (nil when it does not parse).
    static func rows(lines data: Data) -> [MergeRow]? {
        guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return a.map { MergeRow(who: $0["who"] as? String ?? "", start: ($0["start"] as? NSNumber)?.doubleValue ?? 0,
                                text: $0["text"] as? String ?? "", track: $0["track"] as? String ?? "",
                                end: ($0["end"] as? NSNumber)?.doubleValue) }
    }

    // MARK: grouping

    /// Seconds between two sources: 0 when they overlap.
    static func distance(_ a: MergeSource, _ b: MergeSource) -> Double {
        max(0, max(a.start, b.start) - min(a.end, b.end))
    }

    /// The sources that belong with `target`: overlapping it or within `gap` seconds of it, transitively (a chain of
    /// takes 5 min apart all join). Excludes target itself. Sorted by start.
    static func group(_ target: MergeSource, among: [MergeSource], gap: Double = gap) -> [MergeSource] {
        var inGroup = [target]
        var rest = among.filter { $0.id != target.id }
        var grew = true
        while grew {
            grew = false
            var keep: [MergeSource] = []
            for s in rest {
                if inGroup.contains(where: { distance($0, s) <= gap }) { inGroup.append(s); grew = true } else { keep.append(s) }
            }
            rest = keep
        }
        return inGroup.dropFirst().sorted { $0.start < $1.start }
    }

    // MARK: timeline

    /// Lowercased words without punctuation.
    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Two texts say the same words: at least `echoShare` of the shorter one's words are in the other
    /// (counted with repeats). One- and two-word rows only match when their words are equal.
    static func same(_ a: String, _ b: String) -> Bool {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let (short, long) = wa.count <= wb.count ? (wa, wb) : (wb, wa)
        if short.count < 3 { return short == long }
        var bag: [String: Int] = [:]
        for w in long { bag[w, default: 0] += 1 }
        var common = 0
        for w in short where (bag[w] ?? 0) > 0 { bag[w]! -= 1; common += 1 }
        return Double(common) >= echoShare * Double(short.count)
    }

    /// One timeline: every row at (source.start - first.start + row.start), sorted by time then by source order;
    /// a take's row with who "" becomes "unknown" on the mic track when any source is a call (17 November 2026: it was
    /// "Я", and takes made during a call hold the other side's voices too; engine/speakers.py places them by voice). Rows that repeat the same words (one source
    /// heard what another also heard, within 20 s and >= 80% the same words, case and punctuation ignored) are kept once,
    /// the longer text wins.
    static func timeline(_ sources: [MergeSource]) -> (start: Double, secs: Double, rows: [MergeRow]) {
        let ordered = order(sources)
        guard let first = ordered.first else { return (0, 0, []) }
        let start = first.start
        let secs = (ordered.map(\.end).max() ?? start) - start
        let call = ordered.contains { $0.call }
        struct Item { var row: MergeRow; var src: Int; var idx: Int; var gone = false }
        var items: [Item] = []
        for (si, s) in ordered.enumerated() {
            for (ri, r) in s.rows.enumerated() {
                let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var who = r.who, track = r.track
                if s.kind == .take { track = "me" }
                if s.kind == .take, who.isEmpty, call { who = unknown }
                let off = s.start - start
                let end = r.end.map { $0 + off } ?? (s.kind == .take && s.rows.count == 1 ? off + s.secs : nil)
                items.append(Item(row: MergeRow(who: who, start: off + r.start, text: text, track: track, end: end), src: si, idx: ri))
            }
        }
        items.sort { ($0.row.start, $0.src, $0.idx) < ($1.row.start, $1.src, $1.idx) }
        for i in items.indices where !items[i].gone {
            var j = i + 1
            while j < items.count, items[j].row.start - items[i].row.start <= echoWindow {
                if !items[j].gone, items[j].src != items[i].src, same(items[i].row.text, items[j].row.text) {
                    if items[j].row.text.count > items[i].row.text.count { items[i].gone = true; break }
                    items[j].gone = true
                }
                j += 1
            }
        }
        return (start, secs, items.filter { !$0.gone }.map(\.row))
    }

    /// Sources by start; equal starts keep their given order.
    static func order(_ sources: [MergeSource]) -> [MergeSource] {
        sources.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    // MARK: writing

    enum MergeError: Error { case empty }

    /// Folder name for a combined recording: ISO-8601 of the first start with ":" -> "-", plus "-merged".
    static func folderName(_ start: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: start)).replacingOccurrences(of: ":", with: "-") + "-merged"
    }

    /// Writes the combined recording into `root/<name>/`: meta.json {call, app (the first call's app, else first app), started,
    /// merged: [ids], kinds}, lines.json, transcript.txt (call: "Я: …"/"Вони: …" lines; note: one running text),
    /// me.wav (every source's `me` placed at its offset and mixed, clipped), them.wav only when a source has one.
    /// Marks each recording source's meta.json with "mergedInto": <new folder path> (other keys kept). Takes are not changed.
    /// name: ISO-8601 of the first start with ":" -> "-", plus "-merged". -> the new folder.
    /// An existing folder of that name is never overwritten: "-2", "-3"… is added.
    static func build(_ sources: [MergeSource], root: URL, extraMeta: [String: Any] = [:]) throws -> URL {
        let ordered = order(sources)
        guard !ordered.isEmpty else { throw MergeError.empty }
        let line = timeline(ordered)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = folderName(line.start)
        var dir = root.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: dir.path) { dir = root.appendingPathComponent("\(base)-\(n)"); n += 1 }
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)

        let call = ordered.contains { $0.call }
        let app = ordered.first { $0.call && !$0.app.isEmpty }?.app ?? ordered.first { !$0.app.isEmpty }?.app ?? ""
        var meta: [String: Any] = extraMeta
        meta["call"] = call
        meta["app"] = app
        meta["started"] = line.start
        meta["merged"] = ordered.map(\.id)
        meta["kinds"] = ordered.map(\.kind.rawValue)
        try json(meta).write(to: dir.appendingPathComponent("meta.json"))

        let rows: [[String: Any]] = line.rows.map { r in
            var row: [String: Any] = ["who": r.who, "start": (r.start * 100).rounded() / 100, "text": r.text]
            let t = track(r)
            if !t.isEmpty { row["track"] = t }
            if let e = r.end { row["end"] = (e * 100).rounded() / 100 }
            return row
        }
        try json(rows).write(to: dir.appendingPathComponent("lines.json"))
        try transcript(line.rows, call: call).write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)

        let samples = Int((line.secs * Double(rate)).rounded())
        func placed(_ pick: (MergeSource) -> URL?) -> [(URL, Int)] {
            ordered.compactMap { s in pick(s).map { ($0, Int(((s.start - line.start) * Double(rate)).rounded())) } }
        }
        try mix(placed { $0.me }, samples: samples, to: dir.appendingPathComponent("me.wav"))
        let them = placed { $0.them }
        if !them.isEmpty { try mix(them, samples: samples, to: dir.appendingPathComponent("them.wav")) }

        for s in ordered where s.kind == .recording { mark(URL(fileURLWithPath: s.id), into: dir.path) }
        return dir
    }

    /// transcript.txt: a call gets "who: text" lines (a row without a speaker as plain text); a note one running text.
    static func transcript(_ rows: [MergeRow], call: Bool) -> String {
        if call { return rows.map { $0.who.isEmpty ? $0.text : "\($0.who): \($0.text)" }.joined(separator: "\n") + "\n" }
        return rows.map(\.text).joined(separator: " ") + "\n"
    }

    static func json(_ v: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Sets "mergedInto" in a recording folder's meta.json, keeping its other keys.
    static func mark(_ dir: URL, into: String) {
        let f = dir.appendingPathComponent("meta.json")
        var meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any] ?? [:]
        meta["mergedInto"] = into
        if let d = try? json(meta) { try? d.write(to: f, options: .atomic) }
    }

    /// A recording folder already combined into another: its meta.json "mergedInto", or nil.
    static func mergedInto(_ dir: URL) -> String? {
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [String: Any]
        guard let s = meta?["mergedInto"] as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Reads a take row (as History writes it) into a source: start = t - secs, one row at 0 with who "" and its text.
    static func take(_ row: [String: Any]) -> MergeSource? {
        guard let id = row["id"] as? String, !id.isEmpty, let t = (row["t"] as? NSNumber)?.doubleValue else { return nil }
        let secs = max(0, (row["secs"] as? NSNumber)?.doubleValue ?? 0)
        let text = (row["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let audio = row["audio"] as? String ?? ""
        return MergeSource(id: id, kind: .take, start: t - secs, secs: secs, app: row["app"] as? String ?? "",
                           rows: text.isEmpty ? [] : [MergeRow(who: "", start: 0, text: text)],
                           me: audio.isEmpty ? nil : URL(fileURLWithPath: audio))
    }

    // MARK: WAV

    /// Byte offset and length of the PCM data in a 16 kHz mono Int16 WAV (the "data" chunk; 44 when the header is
    /// the plain one). nil for another format or an unreadable file.
    static func pcmRange(_ h: FileHandle, size: Int) -> (offset: Int, bytes: Int)? {
        guard let head = try? h.read(upToCount: 4096), head.count >= 12,
              head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) else { return nil }
        func u32(_ i: Int) -> Int { Int(head[i]) | Int(head[i + 1]) << 8 | Int(head[i + 2]) << 16 | Int(head[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(head[i]) | Int(head[i + 1]) << 8 }
        var i = 12
        var fmtOK = false
        while i + 8 <= head.count {
            let id = head[i..<i + 4], len = u32(i + 4)
            if id == Data("fmt ".utf8), i + 24 <= head.count {
                fmtOK = u16(i + 8) == 1 && u16(i + 10) == 1 && u32(i + 12) == rate && u16(i + 22) == 16
            } else if id == Data("data".utf8) {
                guard fmtOK else { return nil }
                return (i + 8, min(len, size - i - 8) & ~1)
            }
            i += 8 + len + (len & 1)
        }
        return nil
    }

    /// Mixes 16 kHz mono Int16 WAVs, each starting at its sample offset, into one WAV of `samples` samples, clipped.
    /// Streams in chunks of about a minute: memory stays small for an hour-long call. Unreadable inputs are skipped.
    static func mix(_ inputs: [(URL, Int)], samples: Int, to out: URL, chunk: Int = 1 << 20) throws {
        struct Input { let h: FileHandle; let data: Int; let count: Int; let at: Int }
        var open: [Input] = []
        defer { for i in open { try? i.h.close() } }
        for (url, at) in inputs {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard let r = pcmRange(h, size: size) else { try? h.close(); continue }
            open.append(Input(h: h, data: r.offset, count: r.bytes / 2, at: at))
        }
        let total = max(0, samples)
        FileManager.default.createFile(atPath: out.path, contents: wavHeader(samples: total))
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        try w.seekToEnd()
        var acc = [Int32](repeating: 0, count: min(chunk, max(total, 1)))
        var pos = 0
        while pos < total {
            let n = min(chunk, total - pos)
            for k in 0..<n { acc[k] = 0 }
            for i in open {
                // the part of this input inside [pos, pos + n)
                let from = max(pos, i.at), to = min(pos + n, i.at + i.count)
                guard from < to else { continue }
                try i.h.seek(toOffset: UInt64(i.data + (from - i.at) * 2))
                guard let d = try i.h.read(upToCount: (to - from) * 2) else { continue }
                d.withUnsafeBytes { raw in
                    let m = raw.count / 2
                    for k in 0..<m {
                        let s = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: k * 2, as: Int16.self))
                        acc[from - pos + k] += Int32(s)
                    }
                }
            }
            var buf = Data(count: n * 2)
            buf.withUnsafeMutableBytes { raw in
                for k in 0..<n {
                    let v = Int16(clamping: acc[k]).littleEndian
                    raw.storeBytes(of: v, toByteOffset: k * 2, as: Int16.self)
                }
            }
            try w.write(contentsOf: buf)
            pos += n
        }
    }

    /// The 44-byte header of a 16 kHz mono Int16 WAV holding `samples` samples (as History.writeWav writes it).
    static func wavHeader(samples: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples * 2)
        d.append(Data("RIFF".utf8)); u32(36 + bytes); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(bytes)
        return d
    }
}
