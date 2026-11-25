// Markdown exports and safe local file writes. Foundation only; tests use temporary vaults.
import Foundation

enum ObsidianExportRules {
    enum ExportError: Error, LocalizedError {
        case unsafePath, collision, writeFailed
        var errorDescription: String? {
            switch self {
            case .unsafePath: return "Choose a vault folder without symlinks."
            case .collision: return "A note already exists. Try again."
            case .writeFailed: return "Could not save the note. Check folder access."
            }
        }
    }

    static func safeSlug(_ title: String) -> String {
        var out = "", separator = false
        for scalar in title.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                let part = (separator && !out.isEmpty ? "-" : "") + String(scalar)
                if out.utf8.count + part.utf8.count > 120 { break }
                out += part; separator = false
            } else { separator = true }
        }
        return out.isEmpty ? "note" : out
    }

    private static func components(_ path: String) -> [String]? {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts
    }

    /// Walk each component with O_NOFOLLOW. A renamed directory cannot redirect the held descriptor.
    private static func directory(_ parts: [String], createLast: Bool = false) -> Int32? {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        for (i, part) in parts.enumerated() {
            if createLast && i == parts.count - 1 {
                if mkdirat(fd, part, 0o700) != 0 && errno != EEXIST { close(fd); return nil }
            }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        return fd
    }

    static func targetURL(vaultPath: String, subfolder: String = "Drafter", date: Date, title: String) -> URL? {
        guard let parts = components(vaultPath), !subfolder.isEmpty, subfolder != ".", !subfolder.contains(".."),
              !subfolder.contains("/"), !subfolder.contains("\\"),
              !subfolder.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let vault = directory(parts) else { return nil }
        defer { close(vault) }
        let child = openat(vault, subfolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if child < 0 && errno != ENOENT { return nil }
        defer { if child >= 0 { close(child) } }
        let folder = URL(fileURLWithPath: vaultPath, isDirectory: true).appendingPathComponent(subfolder, isDirectory: true)
        let base = day(date) + "-" + safeSlug(title)
        for n in 1...10_000 {
            let name = base + (n == 1 ? "" : "-\(n)") + ".md"
            if child >= 0 {
                var st = stat()
                if fstatat(child, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { continue }
                if errno != ENOENT { return nil }
            }
            return folder.appendingPathComponent(name)
        }
        return nil
    }

    /// Publish a fully written file by linking it within the held directory, never overwriting a collision.
    /// The parent is the export subfolder. Its parent must already be a real directory.
    static func writeAtomically(content: String, to target: URL) -> Result<URL, Error> {
        guard target.isFileURL, let parts = components(target.path), parts.count >= 3,
              target.pathExtension == "md", let fd = directory(Array(parts.dropLast()), createLast: true) else {
            return .failure(ExportError.unsafePath)
        }
        defer { close(fd) }
        let temp = ".drafter-" + UUID().uuidString
        let file = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { return .failure(ExportError.writeFailed) }
        defer { close(file); unlinkat(fd, temp, 0) }
        let bytes = Array(content.utf8)
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return fsync(file) == 0
        }
        guard ok else { return .failure(ExportError.writeFailed) }
        if linkat(fd, temp, fd, parts.last!, 0) != 0 {
            return .failure(errno == EEXIST ? ExportError.collision : ExportError.writeFailed)
        }
        return .success(target)
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    private static func line(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func quoted(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [line(text)], options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8)!.dropFirst().dropLast().description
    }
    private static func wiki(_ name: String) -> String {
        let clean = line(name).filter { !"[]|#\\".contains($0) }
        return clean.isEmpty ? "" : "[[\(clean)]]"
    }
    private static func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.map(line).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private static func note(title: String, date: Date, type: String, people: [String], entities: [String],
                             summary: String, todos: [String], notes: String, tags: [String]) -> String {
        let people = unique(people), tags = unique(tags)
        let links = unique(people + entities).map(wiki).filter { !$0.isEmpty }
        return "---\ndate: \(day(date))\ntype: \(type)\npeople: [\(people.map(quoted).joined(separator: ", "))]\nsource: drafter\ntags: [\(tags.map(quoted).joined(separator: ", "))]\n---\n\n# \(line(title))\n\n"
            + (links.isEmpty ? "" : links.joined(separator: " · ") + "\n\n")
            + "## Summary\n\n\(summary.trimmingCharacters(in: .whitespacesAndNewlines))\n\n## To-dos\n\n"
            + unique(todos).map { "- [ ] " + $0 }.joined(separator: "\n")
            + "\n\n## Notes\n\n\(notes.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }
    static func formatCallNote(title: String, date: Date, people: [String] = [], entities: [String] = [],
                               summary: String, todos: [String] = [], notes: String = "", tags: [String] = ["drafter", "call"]) -> String {
        note(title: title, date: date, type: "call", people: people, entities: entities, summary: summary, todos: todos, notes: notes, tags: tags)
    }
    static func formatTopicNote(title: String, date: Date, people: [String] = [], entities: [String] = [],
                                summary: String, todos: [String] = [], notes: String = "", tags: [String] = ["drafter", "topic"]) -> String {
        note(title: title, date: date, type: "topic", people: people, entities: entities, summary: summary, todos: todos, notes: notes, tags: tags)
    }
    static func formatShareBrief(title: String, subtitle: String = "", summary: String, todos: [String] = [], links: [String] = []) -> String {
        var sections = [line(title), line(subtitle), summary.trimmingCharacters(in: .whitespacesAndNewlines)]
        let tasks = unique(todos)
        if !tasks.isEmpty { sections.append("Open items\n" + tasks.map { "- " + $0 }.joined(separator: "\n")) }
        // Local vault/file links are useful in notes, but not in a recipient's brief.
        let urls = unique(links).filter {
            guard let u = URLComponents(string: $0), ["https", "http"].contains(u.scheme?.lowercased() ?? ""),
                  let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return false }
            return true
        }
        if !urls.isEmpty { sections.append("Links\n" + urls.joined(separator: "\n")) }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }
}
