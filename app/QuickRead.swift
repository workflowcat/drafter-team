// Incremental reads of the history files (speed round, 15 November 2026; the user: "when I open it, it's a little slow
// when I'm trying to search the clipboard"). Foundation only: Quick.swift and the window call it, bench/quick_bench.swift
// and tests/quick_read.swift drive the same code.
//
// The history files only grow (the engine and History append a line per message, take or copy) until a trim or a
// removal writes them anew. So each file is followed: its inode, the bytes read so far (always up to the end of a
// line) and the last 64 of those bytes. Next time only the bytes after that are read and parsed; the file is read
// whole when it is another file (a rewrite through a temporary file), shorter than what was read, or its bytes before
// the mark changed (a rewrite in place). Rows stay in memory, the last `keep` of each file.
import Foundation

/// Where a followed file stood at the last read. Pure: `plan` decides, `cut` splits read bytes into whole lines.
struct FileMark: Equatable {
    var inode: UInt64 = 0
    var offset: UInt64 = 0          // bytes consumed, always just after a newline
    var tail = Data()               // the last (up to) `tailBytes` bytes before `offset`
    static let tailBytes = 64

    enum Plan: Equatable { case same, append(from: UInt64), full }

    /// What to read now. `tailNow`: the file's bytes at [offset - tail.count, offset) as they are now (nil: unread).
    static func plan(_ m: FileMark, inode: UInt64, size: UInt64, tailNow: Data?) -> Plan {
        if m.offset == 0 { return size == 0 && m.inode == inode && m.inode != 0 ? .same : .full }
        if inode != m.inode || size < m.offset { return .full }
        if tailNow != m.tail { return .full }
        return size == m.offset ? .same : .append(from: m.offset)
    }

    /// The whole lines in `chunk` (empty ones dropped) and how many bytes they used; a line still being written
    /// (no newline yet) is left for the next read.
    static func cut(_ chunk: Data) -> (lines: [Data], used: Int) {
        guard let lastNL = chunk.lastIndex(of: 0x0A) else { return ([], 0) }
        var lines: [Data] = [], start = chunk.startIndex
        var i = chunk.startIndex
        while i <= lastNL {
            if chunk[i] == 0x0A { if i > start { lines.append(chunk[start..<i]) }; start = i + 1 }
            i += 1
        }
        return (lines, lastNL - chunk.startIndex + 1)
    }
}

/// One JSONL file, followed: its last `keep` rows, oldest first.
final class JSONLFollow {
    let url: URL
    private(set) var keep: Int
    private(set) var rows: [[String: Any]] = []
    private(set) var mark = FileMark()
    /// false: every refresh reads the whole file (as before the speed round; the bench compares).
    var incremental = true
    /// The last refresh: read whole, bytes read, rows parsed.
    private(set) var last: (full: Bool, bytes: Int, parsed: Int) = (false, 0, 0)

    init(_ url: URL, keep: Int) { self.url = url; self.keep = keep }

    /// The newest `n` rows, newest first (History.read's order).
    func newest(_ n: Int) -> [[String: Any]] { Array(rows.suffix(n).reversed()) }

    /// Reads what is new. -> the rows changed. `keep` grows: read whole once.
    @discardableResult
    func refresh(keep k: Int? = nil) -> Bool {
        if let k, k > keep { keep = k; mark = FileMark() } else if let k { keep = k }
        guard let h = try? FileHandle(forReadingFrom: url) else {
            let had = !rows.isEmpty; rows = []; mark = FileMark(); last = (true, 0, 0); return had
        }
        defer { try? h.close() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        var tailNow: Data?
        if incremental, mark.offset > 0, size >= mark.offset, inode == mark.inode {
            let from = mark.offset - UInt64(mark.tail.count)
            try? h.seek(toOffset: from)
            tailNow = try? h.read(upToCount: mark.tail.count)
        }
        let plan = incremental ? FileMark.plan(mark, inode: inode, size: size, tailNow: tailNow) : .full
        switch plan {
        case .same:
            last = (false, 0, 0); return false
        case .append(let from):
            try? h.seek(toOffset: from)
            let chunk = (try? h.readToEnd()) ?? Data()
            let (lines, used) = FileMark.cut(chunk)
            guard used > 0 else { last = (false, chunk.count, 0); return false }
            let new = lines.compactMap(Self.parse)
            rows += new
            if rows.count > keep { rows.removeFirst(rows.count - keep) }
            advance(inode: inode, to: from + UInt64(used), consumed: chunk.prefix(used))
            last = (false, chunk.count, lines.count)
            return !new.isEmpty
        case .full:
            try? h.seek(toOffset: 0)
            let all = (try? h.readToEnd()) ?? Data()
            let (lines, used) = FileMark.cut(all)
            rows = lines.suffix(keep).compactMap(Self.parse)
            mark = FileMark()
            advance(inode: inode, to: UInt64(used), consumed: all.prefix(used))
            last = (true, all.count, min(lines.count, keep))
            return true
        }
    }

    private func advance(inode: UInt64, to offset: UInt64, consumed: Data) {
        let fresh = Data(consumed.suffix(FileMark.tailBytes))
        // a short read: the tail is what came before plus what was read now
        let tail = fresh.count >= FileMark.tailBytes || mark.offset == 0 ? fresh : Data((mark.tail + fresh).suffix(FileMark.tailBytes))
        mark = FileMark(inode: inode, offset: offset, tail: tail)
    }

    /// One row, its strings made native Swift strings once here: a bridged string is converted again on every read,
    /// hash and compare later (the bench: most of a clipboard refresh).
    static func parse(_ line: Data) -> [String: Any]? {
        guard let j = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return nil }
        var out = [String: Any](minimumCapacity: j.count)
        for (k, v) in j {
            if var s = v as? String { s.makeContiguousUTF8(); out[k] = s } else { out[k] = v }
        }
        return out
    }
}

/// The Quick panel's rows from the history files (moved out of Quick.swift in the speed round). Touched only on one
/// queue at a time (Quick's loading queue, or the bench).
final class QuickReader {
    struct Files { let clip, typed, drafts, takes, hidden: URL }
    let files: Files
    let clip, typed, drafts, takes: JSONLFollow
    /// A stored picture's read text (data/clips/<name>.txt).
    var clipText: (String) -> String
    /// A kept picture's Vision labels (nil until named; History.clipLabels).
    var clipLabels: (String) -> [String]? = { _ in nil }
    var incremental: Bool { didSet { for f in [clip, typed, drafts, takes] { f.incremental = incremental } } }

    private(set) var parts: [[QuickItem]] = [[], [], []]
    private(set) var folded: [String: [String]] = [:]
    private var built: [String: QuickItem] = [:]
    private var secretFor: [String] = [], secretMemo: [String: Bool] = [:]
    private var ocrMemo: [String: String] = [:]
    private var lookMemo: [String: [String]] = [:]

    init(_ files: Files, clipText: @escaping (String) -> String, clipLabels: @escaping (String) -> [String]? = { _ in nil }, incremental: Bool = true) {
        self.files = files; self.clipText = clipText; self.clipLabels = clipLabels; self.incremental = incremental
        clip = JSONLFollow(files.clip, keep: 1000); typed = JSONLFollow(files.typed, keep: 1000)
        drafts = JSONLFollow(files.drafts, keep: 500); takes = JSONLFollow(files.takes, keep: 1000)
        for f in [clip, typed, drafts, takes] { f.incremental = incremental }
    }

    /// A short ASCII stand-in for a long text, for dictionary and set keys: hashing or comparing a long non-ASCII
    /// Swift string normalises it every time (the bench: most of a refresh went there). Length + 64-bit FNV-1a of the
    /// UTF-8 bytes.
    static func digest(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325, n = 0
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3; n += 1 }
        return "\(n):\(String(h, radix: 36))"
    }
    /// `needle` in `s`, byte for byte (String.contains with a non-ASCII needle normalises the whole text).
    static func has(_ s: String, _ needle: String) -> Bool {
        var s = s, needle = needle
        return s.withUTF8 { h in needle.withUTF8 { n in n.isEmpty || (h.count >= n.count && memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil) } }
    }
    private static let testMark = "⟦drafter-test⟧"

    private func item(_ kind: QuickKind, _ text: String, _ app: String, _ at: Double, image: Bool = false) -> QuickItem {
        let k = "\(kind.rawValue)|\(at)|\(app)|\(Self.digest(text))"
        if let it = built[k] { return it }
        let it = QuickItem(kind: kind, text: text, app: app, at: at, image: image)
        built[k] = it
        return it
    }

    /// Clipboard (trimmed as History keeps it), typed messages (drafts folded in), voice takes with words.
    func read(_ i: Int, max: Int, days: Double, secrets: [NSRegularExpression], now: Double = Date().timeIntervalSince1970) {
        if built.count > 4 * max { built.removeAll() }
        if ocrMemo.count > 4 * max { ocrMemo.removeAll() }
        if lookMemo.count > 4 * max { lookMemo.removeAll() }
        switch i {
        case 0:
            clip.refresh(keep: max)
            let clipRows = clip.newest(max)
            let pats = secrets.map(\.pattern)
            if pats != secretFor || secretMemo.count > 8 * max { secretFor = pats; secretMemo = [:] }
            // keepClips sees each text by its digest (same text, same digest; cheap to hash); the secret rules see the text
            var textOf: [String: String] = [:]
            let pairs: [(t: Double, text: String)] = clipRows.reversed().map {
                let key = ClipRules.dedupeKey(text: $0["text"] as? String ?? "", clip: $0["clip"] as? String)
                let d = key.isEmpty ? "" : Self.digest(key)
                textOf[d] = key
                return ($0["t"] as? Double ?? 0, d)
            }
            let keep = QuickRules.keepClips(pairs, now: now, max: max, days: days) { d in
                if let v = secretMemo[d] { return v }
                let v = QuickRules.isSecret(textOf[d] ?? "", secrets); secretMemo[d] = v; return v
            }
            parts[0] = keep.map { k in clipItem(clipRows[clipRows.count - 1 - k]) }
        case 1:
            typed.refresh(keep: max); drafts.refresh(keep: max / 2)
            let hidden = DraftHide.load(files.hidden)
            let sent = DraftHide.drop(typed.newest(max), kind: "sent", hidden: hidden)
            let dr = DraftHide.drop(drafts.newest(max / 2), kind: "draft", hidden: hidden)
            var f: [String: [String]] = [:]
            parts[1] = TypedList.build(sent: sent, drafts: dr)
                .filter { !Self.has($0.text, Self.testMark) }
                .map { e in
                    if !e.drafts.isEmpty { f[e.text] = e.drafts }
                    return item(.typed, e.text, e.app, (e.touched ?? e.when).timeIntervalSince1970)
                }
            folded = f
        default:
            takes.refresh(keep: max)
            parts[2] = takes.newest(max).compactMap { r in
                guard let t = r["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return item(.voice, t, r["app"] as? String ?? "", r["t"] as? Double ?? 0)
            }
        }
    }

    /// One clipboard.jsonl row as a row on the tape (kind, title, size, the stored picture and its read text).
    /// A picture's read text is read once it is there (until then it is looked for on each read).
    private func clipItem(_ r: [String: Any]) -> QuickItem {
        let text = r["text"] as? String ?? "", app = r["app"] as? String ?? "", at = r["t"] as? Double ?? 0
        let pic = r["clip"] as? String ?? ""
        var ocr = ""
        if !pic.isEmpty {
            if let o = ocrMemo[pic] { ocr = o } else { ocr = clipText(pic); if !ocr.isEmpty { ocrMemo[pic] = ocr } }
        }
        var look: [String]?
        if !pic.isEmpty { if let l = lookMemo[pic] { look = l } else { look = clipLabels(pic); if let look { lookMemo[pic] = look } } }
        let k = "c|\(at)|\(app)|\(pic)|\(ocr.count)|\(look?.count ?? -1)|\(r["shape"] as? String ?? "")|\(Self.digest(text))"
        if let it = built[k] { return it }
        let it = QuickItem(kind: .copied, text: text, app: app, at: at, image: r["image"] != nil,
                           clip: (r["kind"] as? String).flatMap(ClipKind.init(rawValue:)), title: r["title"] as? String ?? "",
                           bytes: r["bytes"] as? Int ?? 0, picture: pic, ocr: ocr, rich: r["rich"] as? Bool ?? false,
                           shape: ClipRules.shape(r), data: r["data"] as? String ?? "", note: ClipRules.note(r), look: look)
        built[k] = it
        return it
    }
}
