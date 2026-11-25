// The voice pipeline (17 November 2026, plan docs/plans/2026-11-17-voice-snippets-fable.md): one pure way from what
// the engine heard to what goes into the field, so each stage knows the target app and says what it removed.
//   run     clean-up (Tidy: fillers, repeats) -> Rules (scratch, corrections, closing words, lists) -> names on screen
//           -> spoken snippets. The result is the neutral text: the journal keeps it, an armed draft carries it.
//   render  shape (mail lines, chat lines, spoken breaks) -> style (formal, casual, very casual), for the app the text
//           goes into, at the moment it goes in (a draft armed in one app and put into another takes the second's style).
// Snippet values put in by voice are spans that shape and style never touch. Pure (Tidy comes in as a function, it reads
// the dictionary file): tests/voice_pipeline.swift.
import Foundation

/// What the clean-up removed in one take, for the strip's "Cleaned: …" note. Counts only, never words.
struct CleanMarks: Equatable {
    var fillers = 0, repeats = 0, corrections = 0, scratched = 0, closing = 0, list = 0, snippets = 0

    var isEmpty: Bool { note() == nil }

    /// "Cleaned: 2 fillers · 1 correction", at most 3 parts, largest first; nil when nothing was removed. A list or a
    /// snippet alone says itself: "1 snippet", "Made a list".
    func note() -> String? {
        func n(_ k: Int, _ one: String, _ many: String) -> (Int, String)? { k > 0 ? (k, "\(k) " + (k == 1 ? one : many)) : nil }
        let removed = [n(fillers, "filler", "fillers"), n(repeats, "repeat", "repeats"), n(corrections + scratched, "correction", "corrections"),
                       n(closing, "closing word", "closing words")].compactMap { $0 }
        let added = [n(snippets, "snippet", "snippets"), list > 0 ? (1, "list") : nil].compactMap { $0 }
        guard !removed.isEmpty || !added.isEmpty else { return nil }
        let parts = (removed.sorted { $0.0 > $1.0 } + added).prefix(3).map(\.1)
        return removed.isEmpty ? parts.joined(separator: " · ") : "Cleaned: " + parts.joined(separator: " · ")
    }

    /// The log's form: "f=2 r=0 c=1 s=0 t=0 l=0 n=0".
    var log: String { "f=\(fillers) r=\(repeats) c=\(corrections) s=\(scratched) t=\(closing) l=\(list) n=\(snippets)" }
}

/// Where a take goes and what it may use. Built by Talk from the front app and Settings.
struct VoiceContext {
    var kind = "other"                    // AppKind: ai, chat, mail, other
    var bundle = ""
    var style = VoiceStyle.formal
    var names: [String] = []              // names on screen (Rules.names) and kept capitals (style)
    var live = false                      // live typing: only the final mark changes, no lines
    var emptyField = false                // nothing before the caret (a mail body gets its greeting and sign-off)
    var singleLine = false                // a one-line field (a subject, a search): no line breaks at all
    var shape = true                      // settings voiceShape
    var chatLines = false                 // settings voiceChatLines
    var spoken: [SpokenCue] = []          // spoken snippet cues; empty = off
    var snippets: [String: String] = [:]
    var typingCues: [SnippetCue] = []
    var verbatim: [String] = []           // snippet values in the text (render leaves them alone)
}

struct VoiceResult {
    var text: String
    var marks: CleanMarks
    var keys: [String]                    // snippets put in
    var values: [String]                  // their text as it went in
}

enum VoicePipeline {
    /// Heard -> neutral text. `tidy`: Tidy.marked in the app (fillers and repeats dropped, counted).
    static func run(_ heard: String, _ c: VoiceContext, tidy: (String) -> (text: String, fillers: Int, repeats: Int),
                    fill: (String) -> String = { $0 }) -> VoiceResult {
        let t = tidy(heard)
        let r = Rules.applyMarked(t.text)
        var marks = CleanMarks(fillers: t.fillers, repeats: t.repeats, corrections: r.corrected, scratched: r.scratched,
                               closing: r.closing, list: r.list)
        var text = Rules.names(r.text, c.names)
        var keys: [String] = [], values: [String] = []
        if !c.spoken.isEmpty || !c.typingCues.isEmpty, !c.live {
            let e = SpokenSnippetRules.expand(text, cues: c.spoken, snippets: c.snippets, typingCues: c.typingCues, fill: fill)
            text = e.text; keys = e.keys; values = e.values
            marks.snippets = keys.count
        }
        return VoiceResult(text: text, marks: marks, keys: keys, values: values)
    }

    /// Neutral text -> the text for this app: shape, then style.
    static func render(_ neutral: String, _ c: VoiceContext) -> String {
        guard !neutral.isEmpty else { return neutral }
        var s = neutral
        if c.shape, !c.live {
            s = VoiceShapeRules.shape(s, kind: c.kind, canBreak: !c.live && !c.singleLine, chatLines: c.chatLines, emptyField: c.emptyField)
        }
        return VoiceStyleRules.apply(s, c.style, keep: Set(c.names), verbatim: c.verbatim, endOnly: c.live)
    }
}
