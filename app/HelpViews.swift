// Help, ideas and the Shortcuts page (split out of Window.swift on 25 November 2026, review item 11).
import AppKit
import SwiftUI
import AVFoundation
import EventKit

/// What each part of Drafter does, its keys, and what it did today.
struct HelpView: View {
    @EnvironmentObject var m: WindowModel

    private func keyGrid(_ items: [(String, String)]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(items, id: \.0) { k, v in
                GridRow {
                    KeyChip(k)
                    Text(v)
                        .font(NativeFont.text(12))
                        .foregroundStyle(UIInk.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    func part(_ title: String, glyph: String, _ what: String, keys: [(String, String)], stat: String = "", twoColumns: Bool = false) -> some View {
        PageCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    PageSectionHead(title: title, glyph: glyph)
                    Spacer()
                    if !stat.isEmpty {
                        Text(stat)
                            .font(NativeFont.mono(11))
                            .foregroundStyle(UIInk.muted)
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(Capsule().fill(UIInk.well))
                    }
                }
                if !what.isEmpty {
                    Text(what)
                        .font(NativeFont.text(13))
                        .foregroundStyle(UIInk.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !keys.isEmpty {
                    if twoColumns && keys.count >= 6 {
                        let mid = (keys.count + 1) / 2
                        HStack(alignment: .top, spacing: 24) {
                            keyGrid(Array(keys[..<mid])).frame(maxWidth: .infinity, alignment: .leading)
                            keyGrid(Array(keys[mid...])).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 2)
                    } else {
                        keyGrid(keys).padding(.top, 2)
                    }
                }
            }
        }
    }

    var body: some View {
        let t = m.today
        let wide = m.width >= 820
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader("Help", subtitle: "Drafter helps you write in any app: suggestions, dictation, notes, calls and small actions. History stays on this Mac. Parts that send text to a connected model say so.")
                if wide {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 14) {
                            part("Typing suggestions", glyph: "keys", "Words and endings from your own writing, then the model on this Mac. Ukrainian and English stay in the language you type. A suggestion never changes a word by itself.",
                                 keys: KeyMap.help("typing"))
                            part("Names", glyph: "user", "Every person, project, company and place you write or say, with its forms, phone, email and how often it comes up. Typing finishes a name after 2-3 letters; voice reads the ones you use most. A fix here counts for both.",
                                 keys: KeyMap.help("names"))
                            part("Dictionary", glyph: "text", "Every word voice and typing should spell your way, with what voice heard for it. Words to learn on top: words you changed after dictating. Learn one and voice writes it right next time.",
                                 keys: KeyMap.help("dictionary"))
                            part("Shortcuts and replacements", glyph: "bookmark", "Your email, calendar link and your own replacements work without the model. Your initials + Space puts in your email; ;cal + Space your calendar link. Edit them in Shortcuts.", keys: [])
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 14) {
                            part("Voice", glyph: "microphone", "Words show in the strip first. Ukrainian and English, your dictionary, spoken corrections and lists.",
                                 keys: KeyMap.help("voice"),
                                 stat: m.stats.map { "today: \($0["takes"]?.shown ?? 0) takes" } ?? "")
                            part("Calls and long notes", glyph: "phone", "Audio goes to disk while it records, with screenshots when the screen changes. At the end: a transcript of both sides, a title from your calendar, people, a summary and to-dos. Calls & notes shows them as notes you can search; For agent hands one to Claude or Codex. A call is recorded only when you say so.",
                                 keys: KeyMap.help("calls"))
                            part("Actions", glyph: "sparkle", "Press ⌘K in the window: book 30 minutes tomorrow, find a free slot, remind me …, ;snippet. The connected model handles requests; the model on this Mac is the fallback. Nothing runs until you click.",
                                 keys: KeyMap.help("actions"))
                            part("Elsewhere", glyph: "globe", "", keys: KeyMap.help("elsewhere"))
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    part("Typing suggestions", glyph: "keys", "Words and endings from your own writing, then the model on this Mac. Ukrainian and English stay in the language you type. A suggestion never changes a word by itself.",
                         keys: KeyMap.help("typing"))
                    part("Names", glyph: "user", "Every person, project, company and place you write or say, with its forms, phone, email and how often it comes up. Typing finishes a name after 2-3 letters; voice reads the ones you use most. A fix here counts for both.",
                         keys: KeyMap.help("names"))
                    part("Dictionary", glyph: "text", "Every word voice and typing should spell your way, with what voice heard for it. Words to learn on top: words you changed after dictating. Learn one and voice writes it right next time.",
                         keys: KeyMap.help("dictionary"))
                    part("Shortcuts and replacements", glyph: "bookmark", "Your email, calendar link and your own replacements work without the model. Your initials + Space puts in your email; ;cal + Space your calendar link. Edit them in Shortcuts.", keys: [])
                    part("Voice", glyph: "microphone", "Words show in the strip first. Ukrainian and English, your dictionary, spoken corrections and lists.",
                         keys: KeyMap.help("voice"),
                         stat: m.stats.map { "today: \($0["takes"]?.shown ?? 0) takes" } ?? "")
                    part("Calls and long notes", glyph: "phone", "Audio goes to disk while it records, with screenshots when the screen changes. At the end: a transcript of both sides, a title from your calendar, people, a summary and to-dos. Calls & notes shows them as notes you can search; For agent hands one to Claude or Codex. A call is recorded only when you say so.",
                         keys: KeyMap.help("calls"))
                    part("Actions", glyph: "sparkle", "Press ⌘K in the window: book 30 minutes tomorrow, find a free slot, remind me …, ;snippet. The connected model handles requests; the model on this Mac is the fallback. Nothing runs until you click.",
                         keys: KeyMap.help("actions"))
                    part("Elsewhere", glyph: "globe", "", keys: KeyMap.help("elsewhere"))
                }
                part("The journal", glyph: "list", "Everything Drafter kept, newest first, in chunks of time that grow coarser with age: Today and Yesterday by part of the day, this week and last week by day, this month by week, earlier months and years. Under them, sessions: a stretch in one app with gaps under 10 minutes. Kinds: Clips, Drafts, Voice notes, Recordings, Pictures, Links, Files. The sidebar names each place with its count; the reader on the right shows the chosen item in full. Your changes are kept beside the original; Revert brings the original back. Voice audio is kept for 14 days. Password fields and protected clipboard items are never kept.",
                     keys: JournalKeys.all, stat: "drafts today: \(t["typed"] ?? 0)", twoColumns: wide)
            }
            .padding(.horizontal, PageLayout.margin)
            .padding(.bottom, 22)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One saved value: it saves on ⏎ or when the field is left, and the last change can be undone (no Save button).
/// One phrase the user types often: its text, how often, a key to make it a shortcut, and Hide.
struct IdeaRow: View {
    let idea: Snippets.Idea
    let add: (String) -> Void
    let hide: () -> Void
    @State private var key = ""
    var body: some View {
        let valid = key.trimmingCharacters(in: .whitespaces).count >= 2 && !key.contains(" ")
        VStack(alignment: .leading, spacing: 6) {
            Text(idea.text).font(NativeFont.text(13)).foregroundStyle(UIInk.ink).lineLimit(2).textSelection(.enabled)
            HStack(spacing: 8) {
                Text("\(idea.count) times")
                    .font(NativeFont.mono(11)).foregroundStyle(UIInk.muted)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(UIInk.well))
                Spacer()
                PageField(placeholder: "Shortcut", text: $key, mono: true)
                    .frame(width: 120)
                PagePillButton(title: "Add", glyph: "plus", primary: true, enabled: valid) {
                    let k = key.trimmingCharacters(in: .whitespaces)
                    add(k.hasPrefix(";") ? k : ";" + k)
                }
                Button("Hide", action: hide)
                    .buttonStyle(.plain)
                    .font(NativeFont.text(12))
                    .foregroundStyle(UIInk.muted)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 6)
        .onAppear { if key.isEmpty { key = Snippets.keyFor(idea.text) } }
    }
}

struct ShortcutEditor: View {
    let label: String
    let hint: String
    let key: String
    let file: String
    let initial: String
    var preview = false
    @State private var value = ""
    @State private var saved = ""
    @State private var before: String?
    @State private var status = ""
    @FocusState private var focused: Bool
    func save() {
        guard !preview, value != saved else { return }
        do { try Snippets.save(key, value, file: file); before = saved; saved = value; status = "Saved" }
        catch { status = "Could not save: \(error.localizedDescription)" }
    }
    func undo() {
        guard let b = before else { return }
        do { try Snippets.save(key, b, file: file); value = b; saved = b; before = nil; status = "Undone" }
        catch { status = "Could not undo: \(error.localizedDescription)" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label).font(NativeFont.text(13, .semibold)).foregroundStyle(UIInk.ink)
                Spacer()
                if !status.isEmpty { Text(status).font(NativeFont.mono(11)).foregroundStyle(UIInk.muted) }
                if before != nil { Button("Undo", action: undo).buttonStyle(.plain).font(NativeFont.text(11, .medium)).foregroundStyle(UIInk.blue) }
            }
            PageField(placeholder: label, text: $value, focus: $focused, onSubmit: save)
                .onChange(of: focused) { _, now in if !now { save() } }
            if !hint.isEmpty { Text(hint).font(NativeFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 6)
        .onAppear { value = initial; saved = initial }
    }
}

struct ShortcutsView: View {
    @EnvironmentObject var m: WindowModel
    @State private var rows: [String: String] = [:]
    @State private var snippets: [String: String] = [:]
    @State private var trigger = ""
    @State private var replacement = ""
    @State private var status = ""
    @State private var ideas: [Snippets.Idea] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader("Shortcuts", subtitle: "Space expands an exact shortcut · Tab accepts a suggestion · Replacements stay local; searches use your connected account")

                // 1. Email & Calendar Link
                PageCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            PageSectionHead(title: "Email & Calendar Link", glyph: "mail")
                            Spacer()
                            if !m.preview, !Fields.summary().isEmpty {
                                Text(Fields.summary())
                                    .font(NativeFont.mono(11)).foregroundStyle(UIInk.muted)
                                    .padding(.horizontal, 8).frame(height: 20)
                                    .background(Capsule().fill(UIInk.well))
                            }
                        }
                        ShortcutEditor(label: "Email", hint: (SnippetRules.initials.isEmpty ? "" : SnippetRules.initials + " + Space or ") + ";mail + Space. Type the first letters of your address, then Tab, to complete it.", key: ";mail", file: "snippets.json", initial: snippets[";mail"] ?? "", preview: m.preview)
                            .id("email-" + (snippets[";mail"] ?? ""))
                        Rectangle().fill(UIInk.line).frame(height: 0.5)
                        ShortcutEditor(label: "Calendar link", hint: ";cal + Space. “My calendar link” or “лінк на календар” offers the link with Tab.", key: ";cal", file: "snippets.json", initial: snippets[";cal"] ?? "", preview: m.preview)
                            .id("calendar-" + (snippets[";cal"] ?? ""))
                        Text("In a shortcut's text: {name} a place to fill (Tab goes to the next) · {day:Mon|Tue} a choice (↑↓) · {name=Ira} with a default · {cursor} · {date+2d} · {time} · {clipboard} · {;other} another shortcut. ;Mail starts with a capital.")
                            .font(NativeFont.text(11)).foregroundStyle(UIInk.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Native.corner(2)).fill(UIInk.well))
                    }
                }

                // 2. Open Promises
                PromisesSection(preview: m.preview)

                // 3. Custom Replacements
                PageCard {
                    VStack(alignment: .leading, spacing: 10) {
                        PageSectionHead(title: "Custom Replacements", glyph: "bookmark")
                        Text("Exact, case-sensitive words in Ukrainian or English. Use a rare trigger such as ;дякую. Ordinary word endings remain suggestions; they are never changed automatically. An empty value disables a replacement.")
                            .font(NativeFont.text(12)).foregroundStyle(UIInk.muted).fixedSize(horizontal: false, vertical: true)
                        let sortedRows = rows.keys.sorted()
                        ForEach(Array(sortedRows.enumerated()), id: \.element) { idx, key in
                            if idx > 0 { Rectangle().fill(UIInk.line).frame(height: 0.5) }
                            ShortcutEditor(label: key + " + Space", hint: "", key: key, file: "replacements.json", initial: rows[key] ?? "", preview: m.preview)
                        }
                        let extraSnippets = snippets.keys.filter { ![";mail", ";cal"].contains($0) }.sorted()
                        if !extraSnippets.isEmpty {
                            Rectangle().fill(UIInk.line).frame(height: 0.5)
                            ForEach(Array(extraSnippets.enumerated()), id: \.element) { idx, key in
                                if idx > 0 { Rectangle().fill(UIInk.line).frame(height: 0.5) }
                                ShortcutEditor(label: key + " + Space", hint: "Tab also completes a partial shortcut." + (m.preview || Fields.uses(key) == 0 ? "" : " Used \(Fields.uses(key)) times."), key: key, file: "snippets.json", initial: snippets[key] ?? "", preview: m.preview)
                            }
                        }
                        Rectangle().fill(UIInk.line).frame(height: 0.5)
                        HStack(spacing: 8) {
                            PageField(placeholder: "Shortcut", text: $trigger, mono: true)
                                .frame(width: 130)
                            PageField(placeholder: "Replace with", text: $replacement)
                            PagePillButton(title: "Add", glyph: "plus", primary: true, enabled: !trigger.isEmpty && !replacement.isEmpty && !m.preview) {
                                let key = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }), key != SnippetRules.initials, !MentionRules.reservedWords.contains(key), !snippets.keys.contains(key) else { status = "Use one word, without spaces, that is not a built-in shortcut."; return }
                                do {
                                    try Snippets.save(key, replacement, file: "replacements.json")
                                    rows = Snippets.replacements; trigger = ""; replacement = ""; status = "Saved"
                                } catch { status = "Could not save: \(error.localizedDescription)" }
                            }
                        }
                        if !status.isEmpty {
                            Text(status).font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                        }
                    }
                }

                // 4. Frequent Phrase Ideas
                if !ideas.isEmpty {
                    PageCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                PageSectionHead(title: "Frequent Phrase Ideas", glyph: "sparkle")
                                Text("\(ideas.count)")
                                    .font(NativeFont.mono(11)).foregroundStyle(UIInk.muted)
                                    .padding(.horizontal, 7).frame(height: 19)
                                    .background(Capsule().fill(UIInk.well))
                                Spacer()
                            }
                            Text("Sent three or more times. Make one a shortcut, or hide it.")
                                .font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(ideas.enumerated()), id: \.element.id) { idx, idea in
                                    if idx > 0 { Rectangle().fill(UIInk.line).frame(height: 0.5) }
                                    IdeaRow(idea: idea) { key in
                                        do { try Snippets.save(key, idea.text, file: "snippets.json"); snippets = Snippets.all; status = "Saved \(key)" }
                                        catch { status = "Could not save: \(error.localizedDescription)" }
                                        ideas.removeAll { $0.id == idea.id }
                                    } hide: { Snippets.hideIdea(idea.text); ideas.removeAll { $0.id == idea.id } }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, PageLayout.margin)
            .padding(.bottom, 22)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            snippets = m.preview ? [";mail": "alex@example.com", ";cal": "https://example.com/meet/alex"] : Snippets.all
            rows = m.preview ? [";дякую": "Дякую, отримав."] : Snippets.replacements
            if m.preview { ideas = [Snippets.Idea(text: "Thanks, got it. I will look today and come back.", count: 4)] }
            else if Drafter.shared.settings.learn { DispatchQueue.global(qos: .utility).async { let i = Snippets.ideas(); DispatchQueue.main.async { ideas = i } } }
        }
    }
}
