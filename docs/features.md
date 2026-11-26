# Features

Everything Drafter does, by area, with its key and whether it is on by default. Every key lives in one registry,
`app/KeyMap.swift`, and the in-app Help is built from it, so Help is always the exact list. Every switch is in
Settings (⌘, in the window; type a word in its search field to find it), except the few config-only keys named
below, which are set in `data/settings.json`. "Cloud" marks a feature that needs a model you connect yourself
(Settings > Cloud > Connect a model). It stays off until you connect one and turn it on. Words used here are in the
[glossary](look.md#glossary).

## Typing at the caret

| Feature | Key | Default |
|---|---|---|
| Ghost text: grey words at the caret in any app, from the local model | | on |
| Take one word, or run the chip shown | ⇥ | on |
| Take the whole suggestion | ⇧⇥ | on |
| Take it back right after ⇥ | ⌫ | on |
| Pause ghosts in this field for 10 minutes | Esc Esc | on |
| Two-step ghost: the sure words at once, the rest grows in place | | on |
| Longer tail in AI apps (Claude, ChatGPT and so on) | | on |
| Ghosts in an empty field after a pause | | on |
| A recent copy helps the guess (never secrets or password managers) | | on |
| Three alternatives | ⌥1 ⌥2 ⌥3, once turned on (by default these keys stay your apps') | off |
| Phrase memory: lines you send teach Drafter your phrases (local file) | | on, menu "Learn from what I send" |

## Fixing as you type

| Feature | Key | Default |
|---|---|---|
| Typo fix when a word ends (macOS speller plus your own words) | ⌫ undoes | on (English), off (Ukrainian) |
| Wrong keyboard layout (ghbdsn → привіт) fixed, layout switched | Shift Shift by hand | on |
| "→ word" offer for a word you never write | ⇥ | on |
| Typography: dashes, quotes, ellipsis, arrows, symbols | | on |
| Rework a selection: Shorter, Fix, Clearer, Warmer, Formal, List, Translate, your own | ⌥⇥ | off, cloud |
| Rewrite after a pause: the paragraph before the caret, as a chip | ⇥ on the chip | off, cloud |

## Voice

Voice starts off. Turn it on in the menu bar pen: Voice on Right Option, then allow the Microphone. Dictation runs
locally (Parakeet and Whisper). A take is one dictation.

| Feature | Key | Default |
|---|---|---|
| Start and stop a take | Right Option | off until turned on |
| Push to talk | hold Right Option | |
| Put the take in at the caret: the words wait in the strip until you press it | ↵ | on (`voiceInsert` "enter"; "live" types the words as you speak) |
| The last take in again | Right Option twice | on |
| Drop the take (it stays in the journal) | Esc | |
| Pin the language for this take: UK or EN | Left Option during a take | |
| Voice levels per app: Raw, Clean, Polished, or your own mode | say "mode email", or type `;mode` | Clean |
| Cleanup notes ("Cleaned: 2 fillers") | | on |
| Voice snippets: say a snippet name | | on |
| Polished and your own modes through a bigger model | | off, cloud |
| Lower other audio while you talk | | on |

## Calls and long notes

A recording is a call or a long spoken note. Meeting notes are a recording started for a calendar event.

| Feature | Key | Default |
|---|---|---|
| Start a recording: a long spoken note, or the call a call app is on | ⇧ Right Option | |
| Meeting notes 1 minute before a calendar event with a video link | ↵ on the offer | on (Calendars permission) |
| Recording window with the live transcript | | on |
| Screenshots while recording, kept in `data/calls/<time>/shots/` on this Mac | | off; Settings: "Screenshots while recording" (Screen Recording permission) |
| Screen video of the call | | off |
| Live outline and call summary through a bigger model | | off, cloud (else the local model) |
| To do: follow-ups found in the notes, kept with them | | on |
| Meeting page: chapters on the left, the chapter in focus in the middle, notes on the right | ↑ ↓ chapters | on (window 1100 pt or wider) |
| Your points fold open to what the call added, with the moment it was said | | on |
| Copy for agent: a line on the clipboard that points a coding agent (Claude Code, Codex) at the open recording. Share notes: the notes (summary, your points, To do, chapters, links) on the clipboard, for you to paste | ⇧⌘A for Copy for agent | |

## The window

Open it from the menu bar pen.

- **Stream:** the window's main view: what you typed, said, copied and recorded, by day. Pinch or ⌘+ and ⌘− for zoom: days, weeks, topics.
- **Search** from the field at the top; ⌘K opens the command field.
- **Recordings:** each call or note with its transcript, chapters, speakers and notes.
- **Dictionary** (⇧⌘D): words Drafter should know. It helps typing and dictation.
- **Shortcuts** (⌘J): your snippets (`;mail` and so on).
- **Links & Files**, **What Drafter sees** (⇧⌘I), **Settings**, **Help**.
- **Welcome and setup** (menu bar): the first-run window with permissions, your name and languages, voice and an optional model. Opens by itself at the first launch.

## Clipboard picker

| Feature | Key | Default |
|---|---|---|
| Clipboard picker: what you copied, typed and said, over any app; ↑ ↓ or ⇧⌘V again to choose, ← → the form, ↵ puts in, ⌘↵ keeps it open | ⇧⌘V | on (not in terminals and editors, where ⇧⌘V stays the app's) |
| A key of its own for the same picker | ⌃⌥V | off (Settings: "A key of its own for the full picker") |
| The small list while ⇧⌘V is held (the older way) | hold ⇧⌘V | off (`switchQuickForm`, config-only) |
| Forget copies after 30 days | | on (`quickDays`) |
| At most 1000 copies; copies matching secret patterns never kept | | on (`quickMax`, `quickSecret`, config-only) |
| Pick parts of a long copy | ⌃⌥P, or the strip's offer | on |
| A copy's written forms (plain, one line, quote) | ⇧⇥ on a copy chip | on |

## Snippets, the `;` picker and people

| Feature | Key | Default |
|---|---|---|
| The one `;` picker: snippets, quick starts, people | Right ⌘ twice, or `;` plus 2 letters | on |
| Snippets: `;mail` puts in your address | ⇥ | on |
| People: `;ana` lists people; 1 name, 2 phone, 3 email, 4 address, 5 company | 1 to 6 | on (names in your dictionary) |
| "Ana's number" offers the field as a chip | ⇥ | on |
| In AI apps a name gets a quiet mark; ⌥⇥ attaches what Drafter knows about it | ⌥⇥ | on |

## Screenshots

| Feature | Key | Default |
|---|---|---|
| Screenshot to a capture deck, with a spoken caption per shot | ⇧⌘5 once macOS's own is off | on |
| Scrolling capture | S in the capture overlay | |

## Learning your writing

- Phrase memory and your own words, from what you send and say (local files in `data/`).
- Your own layer: `scripts/train.sh` trains a small LoRA on your writing on your Mac. See
  [your data](your-data.md) and [training](training.md).
- Bring writing you already have: `data/import/` (text, Markdown, JSON lines) or a notes folder in your config.
- Models: pick the typing model in Settings > Typing > Model. The list marks the one that suits your Mac.

## Optional integrations

All off until you turn them on in `data/drafter.local.json` ([customise](customize.md)).

| Name | What it adds |
|---|---|
| `claude` | A signed-in `claude` CLI for actions of your own (`actions/_claude.py`) |

## What is not in this repository

Tools tied to one setup are not part of the core: a separate knowledge app, an inbox, an older dictation app, jobs
and training on a server, a nightly cloud batch, and a local MCP server. Everything here runs on one Mac.
