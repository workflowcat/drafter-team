// A workspace built from value snapshots only. No disk, screen, network or UI access.
import Foundation

struct EntityWorkspaceIdentity: Equatable {
    var display = ""
    var latin = ""
    var kind = ""
    var names: [String] = []
    var aliases: [String] = []
    var phones: [String] = []
    var emails: [String] = []
}

struct EntityPicture: Identifiable, Equatable {
    let id: String
    let journalID: String
    var when: Double = 0
    var title = ""
    var shotID = ""
    var path = ""
}

/// The adapter supplies stored summaries and explicit related names, never live screen text or OCR.
struct EntityJournalInput: Identifiable, Equatable {
    let id: String
    var kind = "typed"
    var clip = "text"
    var when: Double = 0
    var text = ""
    var title = ""
    var app = ""
    var tags: [String] = []
    var related: [String] = []
    var filePaths: [String] = []
    var documentID: String?
    var duration: Double = 0
    var points: [String] = []
    var pictures: [EntityPicture] = []

    var glyph: String {
        if clip == "image" { return "image" }
        if clip == "file" { return "file" }
        if clip == "link" { return "globe" }
        switch kind {
        case "call", "calls": return "phone"
        case "voice", "spoken", "said": return "waves"
        case "copied", "clip": return "copy"
        default: return "keys"
        }
    }
}

struct EntityPromise: Identifiable, Equatable {
    let id: String
    let what: String
    let who: String
    let app: String
    let when: Double
    let due: Double?
}

enum EntityWorkspaceTab: String, CaseIterable {
    case overview, links, calls, pictures, promises
    var label: String {
        switch self {
        case .overview: return "Overview"
        case .links: return "Links & Files"
        case .calls: return "Calls"
        case .pictures: return "Pictures"
        case .promises: return "Promises"
        }
    }
    var glyph: String {
        switch self {
        case .overview: return "list"
        case .links: return "link"
        case .calls: return "phone"
        case .pictures: return "image"
        case .promises: return "check"
        }
    }
}

enum EntityContextLevel: Int, CaseIterable {
    case name = 1, oneLine, fullPack
    var label: String {
        switch self {
        case .name: return "L1 Name"
        case .oneLine: return "L2 One-line"
        case .fullPack: return "L3 Full pack"
        }
    }
}

struct EntityWorkspaceCounts: Equatable {
    // Total counts journal records once; links and embedded pictures can belong to those same records.
    var total = 0
    var calls = 0
    var links = 0
    var pictures = 0
    var promises = 0
    func count(_ tab: EntityWorkspaceTab) -> Int {
        switch tab {
        case .overview: return total
        case .links: return links
        case .calls: return calls
        case .pictures: return pictures
        case .promises: return promises
        }
    }
}

struct EntityWorkspaceContent: Equatable {
    var journal: [EntityJournalInput] = []
    var links: [LinkItem] = []
    var pictures: [EntityPicture] = []
    var promises: [EntityPromise] = []
    var isEmpty: Bool { journal.isEmpty && links.isEmpty && pictures.isEmpty && promises.isEmpty }
}

struct EntityWorkspaceModel: Equatable {
    var overview: [EntityJournalInput] = []
    var calls: [EntityJournalInput] = []
    var draftsAndVoice: [EntityJournalInput] = []
    var clips: [EntityJournalInput] = []
    var pictures: [EntityPicture] = []
    var links: [LinkItem] = []
    var promises: [EntityPromise] = []
    var counts: EntityWorkspaceCounts {
        EntityWorkspaceCounts(total: overview.count, calls: calls.count, links: links.count,
                              pictures: pictures.count, promises: promises.count)
    }
    func content(for tab: EntityWorkspaceTab) -> EntityWorkspaceContent {
        switch tab {
        case .overview: return EntityWorkspaceContent(journal: overview)
        case .links: return EntityWorkspaceContent(links: links)
        case .calls: return EntityWorkspaceContent(journal: calls)
        case .pictures: return EntityWorkspaceContent(pictures: pictures)
        case .promises: return EntityWorkspaceContent(promises: promises)
        }
    }
}

enum EntityWorkspaceRules {
    static func fold(_ value: String) -> String {
        value.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// NameRules.Entry is a JSON dictionary. Accept its underlying type so this file builds independently.
    static func identity(_ entry: [String: Any]) -> EntityWorkspaceIdentity {
        func string(_ key: String) -> String { trim(entry[key] as? String ?? "") }
        func list(_ key: String) -> [String] { unique(entry[key] as? [String] ?? []) }
        let display = [string("display"), string("uk"), string("latin")].first { !$0.isEmpty } ?? ""
        let names = unique([display, string("uk"), string("latin")] + list("short") + list("forms"))
        let emails = list("emails")
        return EntityWorkspaceIdentity(display: display, latin: string("latin"), kind: string("kind"),
                                       names: names, aliases: unique(names + emails).map(fold),
                                       phones: list("phones"), emails: emails)
    }

    static func aliases(_ entry: [String: Any]) -> [String] { identity(entry).aliases }

    /// Unicode word boundaries prevent a short name from matching inside another name or an unrelated word.
    private struct Matcher {
        let expressions: [NSRegularExpression]
        init(_ aliases: [String]) {
            expressions = unique(aliases).compactMap { alias in
                let word = alias.contains("@") ? #"[\p{L}\p{M}\p{N}_@.+-]"# : #"[\p{L}\p{M}\p{N}_]"#
                return try? NSRegularExpression(pattern: "(?<!" + word + ")" + NSRegularExpression.escapedPattern(for: fold(alias)) + "(?!" + word + ")")
            }
        }
        func matches(_ texts: [String]) -> Bool {
            texts.contains { text in
                let text = fold(text), range = NSRange(text.startIndex..., in: text)
                return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
            }
        }
    }

    static func matches(_ text: String, aliases: [String]) -> Bool { Matcher(aliases).matches([text]) }

    static func build(entity: EntityWorkspaceIdentity, journal: [EntityJournalInput],
                      promises: [[String: Any]] = [], remoteLinks: [LinkItem] = []) -> EntityWorkspaceModel {
        guard !entity.aliases.isEmpty else { return EntityWorkspaceModel() }
        let matcher = Matcher(entity.aliases)
        var seen = Set<String>()
        let rows = journal.sorted { stamp($0.when) == stamp($1.when) ? $0.id < $1.id : stamp($0.when) > stamp($1.when) }
            .filter { row in
                let supported = ["call", "calls", "typed", "draft", "drafts", "voice", "spoken", "said", "text", "copied", "clip", "picture", "shot"].contains(row.kind)
                return supported && matcher.matches([row.title, row.text] + row.tags + row.related + row.points)
                    && seen.insert(row.id).inserted
            }
        var model = EntityWorkspaceModel(overview: rows)
        for row in rows {
            if ["call", "calls"].contains(row.kind) { model.calls.append(row) }
            else if row.clip == "image" || ["picture", "shot"].contains(row.kind) { /* pictures below */ }
            else if ["copied", "clip"].contains(row.kind) { model.clips.append(row) }
            else { model.draftsAndVoice.append(row) }
        }
        var pictureIDs = Set<String>()
        model.pictures = rows.flatMap { row -> [EntityPicture] in
            if !row.pictures.isEmpty { return row.pictures }
            guard row.clip == "image" || ["picture", "shot"].contains(row.kind) else { return [] }
            return [EntityPicture(id: row.id, journalID: row.id, when: row.when,
                                  title: row.title.isEmpty ? "Picture" : row.title)]
        }.filter { pictureIDs.insert($0.id).inserted }
            .sorted { stamp($0.when) == stamp($1.when) ? $0.id < $1.id : stamp($0.when) > stamp($1.when) }
        let links = rows.flatMap { row -> [LinkRowInput] in
            let paths = row.clip == "file" ? (row.filePaths.isEmpty ? row.text.components(separatedBy: .newlines) : row.filePaths) : [""]
            return paths.map { path in
                LinkRowInput(id: row.id, kind: row.kind == "clip" ? "copied" : row.kind, clip: row.clip,
                             text: ([row.title, row.text] + row.points).joined(separator: "\n"),
                             title: paths.count > 1 ? (path as NSString).lastPathComponent : row.title,
                             app: row.app, when: stamp(row.when), tags: row.tags, filePath: trim(path))
            }
        }
        model.links = LinksRules.merge(local: LinksRules.extract(from: links), remote: remoteLinks)
        model.promises = filterPromises(promises, aliases: entity.aliases)
        return model
    }

    static func filterPromises(_ rows: [[String: Any]], aliases: [String]) -> [EntityPromise] {
        let matcher = Matcher(aliases)
        var seen = Set<String>()
        return rows.compactMap { row -> EntityPromise? in
            func string(_ key: String) -> String { trim(row[key] as? String ?? "") }
            // The endpoint uses null for open and a completion timestamp for done.
            let completed = ((row["done"] as? NSNumber)?.doubleValue ?? 0) != 0
            let state = string("status").lowercased()
            guard !completed, !["done", "closed", "dropped"].contains(state),
                  !string("id").isEmpty,
                  matcher.matches([string("who"), string("person"), string("what"), string("phrase")]) else { return nil }
            let what = string("what").isEmpty ? string("phrase") : string("what")
            guard !what.isEmpty else { return nil }
            let due = number(row["due"])
            return EntityPromise(id: string("id"), what: what, who: string("who"), app: string("app"),
                                 when: stamp(number(row["t"]) ?? 0), due: due.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        }.sorted { $0.when == $1.when ? $0.id < $1.id : $0.when > $1.when }
            .filter { seen.insert($0.id).inserted }
    }

    /// Preserve the full pack's paragraphs; collapse the one-line pack only. Never invent missing context.
    static func contextCopyText(_ response: [String: Any], entity: EntityWorkspaceIdentity, level: EntityContextLevel) -> String {
        guard response["error"] == nil else { return "" }
        if level == .name { return trim(response["name"] as? String ?? entity.display) }
        guard (response["found"] as? Int) != 0 else { return "" }
        let text = trim(response["text"] as? String ?? "")
        return level == .oneLine ? text.split(whereSeparator: \.isWhitespace).joined(separator: " ") : text
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }
    private static func stamp(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    private static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map(trim).filter { !$0.isEmpty && seen.insert(fold($0)).inserted }
    }
}
