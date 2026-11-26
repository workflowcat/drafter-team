// The key map (17 November 2026, docs/plans/2026-11-17-key-map.md), pure: no AppKit. One table of Drafter's keys:
// what each does, where it works, its setting and default, and its Help line. Help (app/Window.swift HelpView), the
// global chords' defaults (Settings, QuickRules, ShotRules agree with it) and the double-press window read it; the
// clash test (tests/key_map.swift) checks it: no two default-on keys share a chord in one place, no default key is
// one Drafter gave back to macOS or other apps, Help names no retired key.
// Rule (the user, 17 November 2026): one job per key, one key family per job, no chord taken from other apps unless the user
// asked for it.
import Foundation

/// Where a key works.
enum KeySurface: String, CaseIterable {
    case global    // anywhere (the event tap, before the app)
    case field     // a text field in another app, with Drafter's grey text or chip at the caret
    case picker    // the clipboard picker (⌘⇧V)
    case deck      // the capture deck after a screenshot
    case window    // Drafter's own window
    case overlay   // the strip: an offer, a voice take
    case markup    // the markup editor on a captured picture
}

struct KeyDef: Equatable {
    let id: String
    let keys: String          // as the user sees it: "⇧⇥", "⌘⇧V", "Right Option twice"
    let job: String           // the family: one job, one family
    let surface: KeySurface
    var scope = ""            // a part of the surface where the key means this ("file" row, "names" pane); "" = all of it
    var setting = ""          // the Settings name that switches or sets it; "" = always there
    var on = true             // on in a fresh install
    var help = ""             // its Help line; "" = not in Help
    var section = ""          // Help's part: typing, names, dictionary, voice, calls, actions, elsewhere
}

enum KeyMap {
    /// Every double press (Esc Esc, Shift Shift, Right Option twice) uses this one window, in seconds.
    static let doubleWindow = 0.45

    static let all: [KeyDef] = [
        // a field: take what Drafter shows at the caret
        KeyDef(id: "take", keys: "⇥", job: "take", surface: .field,
               help: "accept one word, or put in what the chip shows (an outside action only runs by click)", section: "typing"),
        KeyDef(id: "takeAll", keys: "⇧⇥", job: "take", surface: .field, help: "accept the whole suggestion", section: "typing"),
        KeyDef(id: "tabBack", keys: "⌫", job: "undo take", surface: .field, setting: "tabBack", help: "right after ⇥: take it back", section: "typing"),
        KeyDef(id: "escPause", keys: "esc esc", job: "pause", surface: .field, setting: "escPause",
               help: "pause suggestions in this field for 10 min; twice again resumes", section: "typing"),
        KeyDef(id: "layout", keys: "Shift Shift", job: "layout", surface: .field, setting: "layoutFix",
               help: "the last word in the other keyboard layout", section: "typing"),
        KeyDef(id: "rework", keys: "⌥⇥", job: "rework", surface: .field, setting: "contextPacks",
               help: "on a selection: rework it (when on); on a marked name in AI apps: attach its context", section: "typing"),
        KeyDef(id: "pauseRewrite", keys: "⇥", job: "take", surface: .field, scope: "rewrite chip", setting: "pauseRewrite", on: false,
               help: "after a pause, on Claude's rewrite chip: put the rewrite in (⌫ right after takes it back)"),
        KeyDef(id: "keepTyping", keys: "keep typing", job: "dismiss", surface: .field, help: "adjust or dismiss", section: "typing"),
        KeyDef(id: "alternatives", keys: "⌥1 ⌥2 ⌥3", job: "take", surface: .field, setting: "alternatives", on: false),
        KeyDef(id: "cardArrows", keys: "← → ↑", job: "take", surface: .field, scope: "opened draft card"),
        KeyDef(id: "chipArrows", keys: "← → ↓", job: "take", surface: .field, scope: "person chip"),

        // anywhere: voice on Right Option, once on (menu: Voice on Right Option)
        KeyDef(id: "voice", keys: "Right Option", job: "voice", surface: .global, setting: "voice", on: false,
               help: "start / stop, once on (menu: Voice on Right Option)", section: "voice"),
        KeyDef(id: "voiceHold", keys: "hold Right Option", job: "voice", surface: .global, setting: "voice", on: false,
               help: "push to talk", section: "voice"),
        KeyDef(id: "voiceAgain", keys: "Right Option twice", job: "voice", surface: .global, setting: "againTap",
               help: "insert the last voice note again", section: "voice"),
        KeyDef(id: "voiceChord", keys: "Right Option + a key", job: "voice", surface: .global, setting: "voice", on: false,
               help: "a key while Right Option is held, before any words: no take, the key goes to the app", section: "voice"),
        KeyDef(id: "voiceLong", keys: "⇧ Right Option", job: "voice", surface: .global, setting: "voice", on: false,
               help: "start / finish a recording, or record the call the strip offers", section: "calls"),
        KeyDef(id: "commands", keys: "Right ⌘ twice", job: "commands", surface: .global, setting: "commandsKey",
               help: "the one ; picker: snippets, quick starts, people (also in the menu); ↑ ↓, ↵ puts in, esc", section: "typing"),
        KeyDef(id: "againKey", keys: "⌃⌥R", job: "voice", surface: .global, setting: "againKey", on: false),

        // the strip
        KeyDef(id: "offerTake", keys: "⇥", job: "take", surface: .overlay, help: "take a copy's written form (never a call)"),
        KeyDef(id: "offerStep", keys: "⇧⇥", job: "take", surface: .overlay, help: "a copy's next written form"),
        KeyDef(id: "offerOff", keys: "⇧esc", job: "dismiss", surface: .overlay, help: "no more call offers in that app"),
        KeyDef(id: "voiceInsert", keys: "↵", job: "voice", surface: .overlay, setting: "voice", on: false,
               help: "insert what you said, the note goes on; nothing said: it goes to the app", section: "voice"),
        KeyDef(id: "meetOffer", keys: "↵", job: "voice", surface: .overlay, scope: "meeting offer",
               help: "start the meeting notes the strip offers (1 min before a calendar event with a video link); Tab stays the app's",
               section: "calls"),
        KeyDef(id: "voicePin", keys: "Left Option", job: "voice", surface: .overlay, setting: "voice", on: false,
               help: "during a take: hear it as Ukrainian or English (UK / EN in the strip); never translates", section: "voice"),
        KeyDef(id: "stripEsc", keys: "esc", job: "dismiss", surface: .overlay,
               help: "drop the voice note (it stays in the journal), or dismiss an offer", section: "voice"),
        KeyDef(id: "askNotes", keys: "Drafter, …", job: "voice", surface: .overlay, setting: "voice", on: false,
               help: "ask your notes", section: "voice"),

        // anywhere: chords
        KeyDef(id: "picker", keys: "⌘⇧V", job: "clipboard", surface: .global, setting: "switchKey",
               help: "clipboard picker: ↑ ↓ or ⌘⇧V again choose, ← → the form, ↵ puts in, ⌘↵ keeps it open; in skipped apps (terminals, VS Code, Xcode) ⌘⇧V stays the app's",
               section: "elsewhere"),
        KeyDef(id: "swap", keys: "⌘⇧V", job: "clipboard", surface: .global, scope: "within 2 s of a paste", setting: "switchSwap", on: false),
        KeyDef(id: "quickKey", keys: "⌃⌥V", job: "clipboard", surface: .global, setting: "quickKey", on: false),
        KeyDef(id: "capture", keys: "⌘⇧5", job: "screenshot", surface: .global, setting: "captureKey",
               help: "screenshot, once macOS's own ⌘⇧5 is off", section: "elsewhere"),
        KeyDef(id: "captureFallback", keys: "⌃⌥S", job: "screenshot", surface: .global, setting: "captureFallbackKey", on: false),
        KeyDef(id: "captureSaveAs", keys: "⌘⇧S", job: "screenshot", surface: .global, setting: "captureCmdShiftS", on: false),
        KeyDef(id: "pick", keys: "⌃⌥P", job: "edit before it goes in", surface: .global, setting: "pickKey",
               help: "Pick parts of the copied text", section: "elsewhere"),

        // the clipboard picker
        KeyDef(id: "pickerMove", keys: "↑ ↓", job: "clipboard", surface: .picker),
        KeyDef(id: "pickerNext", keys: "⌘⇧V", job: "clipboard", surface: .picker),
        KeyDef(id: "pickerForm", keys: "← →", job: "clipboard", surface: .picker),
        KeyDef(id: "pickerPut", keys: "↵", job: "clipboard", surface: .picker),
        KeyDef(id: "pickerStay", keys: "⌘↵", job: "clipboard", surface: .picker),
        KeyDef(id: "pickerWithText", keys: "⇧↵", job: "clipboard", surface: .picker, scope: "picture"),
        KeyDef(id: "pickerEdit", keys: "⌘E", job: "edit before it goes in", surface: .picker),
        KeyDef(id: "pickerPin", keys: "⌘P", job: "pin", surface: .picker),
        KeyDef(id: "pickerRemove", keys: "⌘⌫", job: "clipboard", surface: .picker),
        KeyDef(id: "pickerCopy", keys: "⌘C", job: "clipboard", surface: .picker, help: "copy the row (a file row: the file itself)"),
        KeyDef(id: "pickerPath", keys: "⌥⌘C", job: "clipboard", surface: .picker, scope: "file", help: "copy the file's path"),
        KeyDef(id: "pickerOpen", keys: "⌘O", job: "clipboard", surface: .picker),
        KeyDef(id: "pickerMarkdown", keys: "⌘M", job: "clipboard", surface: .picker, scope: "link"),
        KeyDef(id: "pickerClean", keys: "⌘T", job: "clipboard", surface: .picker, scope: "link"),
        KeyDef(id: "pickerText", keys: "⌘T", job: "clipboard", surface: .picker, scope: "picture"),
        KeyDef(id: "pickerReveal", keys: "⌘R", job: "clipboard", surface: .picker, scope: "file"),
        KeyDef(id: "pickerSave", keys: "⌘S", job: "clipboard", surface: .picker, scope: "picture"),
        KeyDef(id: "pickerRewrite", keys: "⇥", job: "rework", surface: .picker),
        KeyDef(id: "pickerClose", keys: "esc", job: "dismiss", surface: .picker),

        // the capture deck takes no keys (round 4 "Hand", 18 November 2026): it never becomes key, every key stays the user's
        // app's; the capture key while it is up takes the next shot (Capture.open). docs/rounds/2026-11-17-deck.md

        // the markup editor (app/MarkupRules.swift Markup.key owns the keys; listed so a new one shows a clash). Its tool
        // digits 1-7 are not listed: plain digits are on the given-back list for fields, and the editor takes them only
        // while it is open. The pen is a letter for that reason.
        KeyDef(id: "markupPen", keys: "P", job: "mark up", surface: .markup),
        KeyDef(id: "markupRed", keys: "R", job: "mark up", surface: .markup),
        KeyDef(id: "markupYellow", keys: "Y", job: "mark up", surface: .markup),
        KeyDef(id: "markupGreen", keys: "G", job: "mark up", surface: .markup),
        KeyDef(id: "markupBlue", keys: "B", job: "mark up", surface: .markup),
        KeyDef(id: "markupViolet", keys: "V", job: "mark up", surface: .markup),
        KeyDef(id: "markupThinner", keys: "[", job: "mark up", surface: .markup),
        KeyDef(id: "markupThicker", keys: "]", job: "mark up", surface: .markup),
        KeyDef(id: "markupUndo", keys: "⌘Z", job: "mark up", surface: .markup),
        KeyDef(id: "markupRedo", keys: "⌘⇧Z", job: "mark up", surface: .markup),
        KeyDef(id: "markupDelete", keys: "⌫", job: "mark up", surface: .markup),
        KeyDef(id: "markupAnother", keys: "⌘N", job: "mark up", surface: .markup),
        KeyDef(id: "markupDone", keys: "↵", job: "mark up", surface: .markup),
        KeyDef(id: "markupBack", keys: "esc", job: "dismiss", surface: .markup),

        // Drafter's window
        KeyDef(id: "openNames", keys: "⇧⌘N", job: "window", surface: .window, help: "open", section: "names"),
        KeyDef(id: "nameFix", keys: "↵", job: "window", surface: .window, scope: "names", help: "fix the spelling", section: "names"),
        KeyDef(id: "nameMerge", keys: "⌘M", job: "window", surface: .window, scope: "names", help: "merge into another", section: "names"),
        KeyDef(id: "nameHide", keys: "⌘⌫", job: "window", surface: .window, scope: "names", help: "hide", section: "names"),
        KeyDef(id: "nameUndo", keys: "⌘Z", job: "window", surface: .window, scope: "names", help: "undo", section: "names"),
        KeyDef(id: "openDictionary", keys: "⇧⌘D", job: "window", surface: .window, help: "open", section: "dictionary"),
        KeyDef(id: "dictEdit", keys: "↵", job: "window", surface: .window, scope: "dictionary", help: "edit a word; on a word to learn: learn it", section: "dictionary"),
        KeyDef(id: "dictRemove", keys: "⌘⌫", job: "window", surface: .window, scope: "dictionary", help: "remove; on a word to learn: ignore it", section: "dictionary"),
        KeyDef(id: "dictUndo", keys: "⌘Z", job: "window", surface: .window, scope: "dictionary", help: "undo", section: "dictionary"),
        KeyDef(id: "agentCopy", keys: "⇧⌘A", job: "window", surface: .window, help: "copy the open item or recording for an agent", section: "calls"),
        KeyDef(id: "command", keys: "⌘K", job: "command", surface: .window, help: "go to the field", section: "actions"),
        KeyDef(id: "commandAsk", keys: "↵", job: "command", surface: .window, scope: "command field", help: "suggest options", section: "actions"),
        KeyDef(id: "commandRun", keys: "click", job: "command", surface: .window, scope: "command field", help: "run one", section: "actions"),
        KeyDef(id: "commandUndo", keys: "⌘Z", job: "command", surface: .window, scope: "command field"),
        KeyDef(id: "openLinks", keys: "⇧⌘L", job: "window", surface: .window, help: "Links & Files", section: "elsewhere"),
        KeyDef(id: "openScreen", keys: "⇧⌘I", job: "window", surface: .window, help: "What Drafter sees", section: "elsewhere"),
        KeyDef(id: "settings", keys: "⌘,", job: "window", surface: .window, help: "Settings", section: "elsewhere"),
        KeyDef(id: "shortcuts", keys: "⌘J", job: "window", surface: .window, help: "Shortcuts", section: "elsewhere"),
    ]

    static func entry(_ id: String) -> KeyDef? { all.first { $0.id == id } }

    /// The key a fresh install has for `id`: its keys when on by default, "" when off.
    static func defaultChord(_ id: String) -> String { entry(id).map { $0.on ? $0.keys : "" } ?? "" }

    /// Help's key lines for one part, in table order.
    static func help(_ section: String) -> [(String, String)] {
        all.filter { $0.section == section && !$0.help.isEmpty }.map { ($0.keys, $0.help) }
    }

    /// Keys Drafter gave back (keys round three) and must never take by default: tab switching, characters, digits,
    /// launcher keys.
    static let givenBack = ["⌃⇥", "⌃⇧⇥", "⌥1", "⌥2", "⌥3", "⌃⌥Space", "⌘Space"] + (0...9).map(String.init)
    /// Keys that were Drafter's defaults once and Help must not name.
    static let retired = ["⌃⌥R", "⌃⌥V", "⌃⌥S", "⌃⇥", "⌃⇧⇥", "⌃Tab", "⌃⇧Tab", "⌥1", "⌥2", "⌥3"]

    /// One chord as a comparable text: modifiers in macOS's order (⌃⌥⇧⌘), then the key, lower case, with Tab, Return
    /// and Esc spelled one way.
    static func norm(_ k: String) -> String {
        var mods = Set<Character>(), rest = Substring(k.trimmingCharacters(in: .whitespaces))
        while let f = rest.first, "⌃⌥⇧⌘".contains(f) { mods.insert(f); rest = rest.dropFirst() }
        var base = rest.trimmingCharacters(in: .whitespaces).lowercased()
        let alias = ["tab": "⇥", "return": "↵", "enter": "↵", "⏎": "↵", "escape": "esc", "backspace": "⌫", "delete": "⌫"]
        base = alias[base] ?? base
        return String("⌃⌥⇧⌘".filter { mods.contains($0) }) + base
    }

    /// Pairs of default-on keys that share a chord in one place (the same surface, and the same scope or one of them
    /// covering the whole surface).
    static func clashes(_ list: [KeyDef] = all) -> [(KeyDef, KeyDef)] {
        let on = list.filter(\.on)
        var out: [(KeyDef, KeyDef)] = []
        for (i, a) in on.enumerated() {
            for b in on[(i + 1)...] where a.surface == b.surface && norm(a.keys) == norm(b.keys)
                && (a.scope.isEmpty || b.scope.isEmpty || a.scope == b.scope) {
                out.append((a, b))
            }
        }
        return out
    }
}
