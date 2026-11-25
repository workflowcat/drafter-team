// Talk, part: the voice pipeline's two ends in the app (17 November 2026, app/VoicePipeline.swift). `finish` makes a
// take's neutral text (clean-up, corrections, names, spoken snippets) and keeps what it removed for the strip;
// `render` shapes and styles it for the app it goes into, at the moment it goes in.
import AppKit

extension Talk {
    /// The final text of a take: clean-up, spoken corrections and lists, names on screen, spoken snippets. `mark`:
    /// keep its counts for the strip (the careful second reading does not).
    func finish(_ heard: String, mark: Bool = true) -> String {
        let st = Drafter.shared.settings
        // Raw: Parakeet's words as heard, nothing run on them (research item 3)
        if levelChoice().level == .raw { if mark { marks = CleanMarks() }; return heard.trimmingCharacters(in: .whitespacesAndNewlines) }
        var c = VoiceContext(names: screenNames, live: live)
        if st.voiceSnippets, !long {
            let all = Snippets.all
            c.snippets = all
            c.spoken = SpokenSnippetRules.cues(snippets: all, meta: Talk.snippetMeta())
            c.typingCues = Snippets.cues
        }
        let r = VoicePipeline.run(heard, c, tidy: Tidy.marked, fill: { Snippets.fill($0).text })
        if mark, !heard.isEmpty {
            marks = r.marks
            if !r.values.isEmpty { putValues = Array((putValues + r.values).suffix(20)) }
            if !r.marks.isEmpty { log("voice cleaned \(r.marks.log)") }                 // counts only, never words
        }
        return r.text
    }

    /// The neutral text shaped and styled for the app it goes into. `spot`: the field (its kind of field, whether it
    /// is empty); nil when it cannot be read. `live`: the words are already typed, only the final mark changes.
    /// `record`: this is what goes in (the careful read's chip replaces it the same way).
    func render(_ neutral: String, app: NSRunningApplication?, spot: Spot?, live: Bool = false, record: Bool = true) -> String {
        guard !neutral.isEmpty else { return neutral }
        let st = Drafter.shared.settings
        let id = spot?.app.bundleIdentifier ?? app?.bundleIdentifier ?? ""
        let kind = AppKind.of(id, title: spot?.title ?? "", ai: Keys.aiApps, chats: Keys.chatApps, browsers: Keys.browsers, aiTitle: Keys.aiTitle)
        if levelChoice(bundle: id, kind: kind).level == .raw { return neutral }   // Raw: no shape, no style
        var c = VoiceContext(kind: kind, bundle: id,
                             style: VoiceStyleRules.pick(kind: kind, bundle: id, byKind: st.voiceStyle, byApp: st.voiceStyleApps),
                             names: screenNames + NameBook.found(in: neutral.lowercased()), live: live,
                             emptyField: spot.map { $0.before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false,
                             singleLine: spot.map { ["AXTextField", "AXSearchField", "AXComboBox"].contains($0.role) } ?? false,
                             shape: st.voiceShape, chatLines: st.voiceChatLines)
        c.verbatim = putValues.filter { neutral.contains($0) }
        let out = VoicePipeline.render(neutral, c)
        if record {
            lastPut = (neutral, out, c)
            log("voice style: \(kind) \(c.style.rawValue)\(live ? " live" : ""), \(neutral.count) -> \(out.count) chars, \(out.filter { $0 == "\n" }.count) lines")
        }
        return out
    }

    /// The cleanup level and mode for an app (front app when nil): his pick this session, the app's, its kind's, Clean.
    func levelChoice(bundle: String? = nil, kind: String? = nil) -> VoiceChoice {
        let st = Drafter.shared.settings
        let front = NSWorkspace.shared.frontmostApplication
        let id = bundle ?? front?.bundleIdentifier ?? ""
        let k = kind ?? AppKind.of(id, title: "", ai: Keys.aiApps, chats: Keys.chatApps, browsers: Keys.browsers, aiTitle: Keys.aiTitle)
        return VoiceModeRules.pick(kind: k, bundle: id, byKind: st.voiceLevel, byApp: st.voiceLevelApps, modes: st.voiceModes, picked: levelPicked)
    }

    /// Polished: the clean text rewritten as written text by the local model (`/rewrite`, never Claude), with his mode's
    /// prompt and his writing note for the app. The clean text when the model fails, is slow (6 s) or answers badly.
    func polish(_ clean: String, _ c: VoiceChoice, bundle: String, done: @escaping (String) -> Void) {
        let st = Drafter.shared.settings, t0 = Date()
        let note = WritingNotes.forApp(bundle, global: st.writingNote, perApp: st.appNotes)
        Engine.shared.post("/rewrite", ["text": clean, "instruction": VoiceModeRules.instruction(c, note: note), "names": screenNames], timeout: 6) { j in
            let out = VoiceModeRules.accept(polished: j?["text"] as? String ?? "", clean: clean)
            log("voice polish: \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(clean.count) -> \(out.count) chars\(out == clean ? ", kept clean" : "")\(c.mode.isEmpty ? "" : ", a mode")")
            DispatchQueue.main.async { done(out) }
        }
    }

    /// Another reading of the same take, in the way the last one went in.
    func render(_ neutral: String, again c: VoiceContext) -> String {
        var c = c
        c.verbatim = putValues.filter { neutral.contains($0) }
        return VoicePipeline.render(neutral, c)
    }

    /// An armed draft in the strip: styled for the app in front now, and what the clean-up removed under it.
    func armedView(_ t: String) -> String {
        let shown = render(t, app: NSWorkspace.shared.frontmostApplication, spot: nil, record: false)
        guard Drafter.shared.settings.cleanNote, let note = marks.note() else { return shown }
        return shown + "\n" + note
    }

    /// Spoken cues he gave his snippets: data/snippet-meta.json {";key": {"say": ["my site", "мій сайт"]}}. Read when it
    /// changes; no file, no extra cues ("my <key>" works without it).
    static func snippetMeta() -> [String: [String]] {
        let url = Home.data.appendingPathComponent("snippet-meta.json")
        let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let c = metaCache, c.0 == m { return c.1 }
        var out: [String: [String]] = [:]
        if let d = try? Data(contentsOf: url), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            for (k, v) in j { if let say = (v as? [String: Any])?["say"] as? [String] { out[k] = say } }
        }
        metaCache = (m, out)
        return out
    }
    private static var metaCache: (Date?, [String: [String]])?
}
