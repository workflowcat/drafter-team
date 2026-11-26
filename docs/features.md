# Features

Everything Drafter does, by area, with its key and whether it is on by default. Every key lives in one registry,
`app/KeyMap.swift`, and the in-app Help is built from it, so Help is always the exact list. Every switch is in
Settings (⌘, in the window; type a word in its search field to find it). "Cloud" marks a feature that needs a model you
connect yourself (Settings > Connect a model). It stays off until you connect one and turn it on.

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
| Three alternatives | ⌥1 ⌥2 ⌥3 | off |
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

Turn on in the menu bar: Voice on Right Option. Dictation runs locally (Parakeet and Whisper).

| Feature | Key | Default |
|---|---|---|
| Start and stop a take | Right Option | off until turned on |
| Push to talk | hold Right Option | |
| The last take in again | Right Option twice | on |
| Drop the take (it stays in the journal) | Esc | |
| Pin the language for this take: UK or EN | Left Option during a take | |
| Voice levels per app: Raw, Clean, Polished, or your own mode | say "mode email", or type `;mode` | Clean |
| Cleanup notes ("Cleaned: 2 fillers") | | on |
| Voice snippets: say a snippet name | | on |
| Polished and your own modes through a bigger model | | off, cloud |
| Lower other audio while you talk | | on |

## Calls and long notes

| Feature | Key | Default |
|---|---|---|
| Record a long spoken note, or the call a call app is on | ⇧ Right Option | |
| Meeting notes 1 minute before a calendar event with a video link | ↵ on the offer | on |
| Recording window with the live transcript | | on |
| Screenshots while a call records, for the brief | | on (Screen Recording permission) |
| Screen video of the call | | off |
| Live outline and call summary through a bigger model | | off, cloud (else the local model) |
| Follow-ups found in the note, kept with it | | on |

## The window

Open it from the menu bar pen.

- **Stream:** what you typed, said, copied and recorded, by day. Pinch or ⌘+ and ⌘− for zoom: days, weeks, topics.
- **Search** from the field at the top; ⌘K opens the command field.
- **Recordings:** each call or note with its transcript, chapters, speakers and notes.
- **Dictionary** (⇧⌘D): words Drafter should know. It helps typing and dictation.
- **Shortcuts** (⌘J): your snippets.
- **Links & Files**, the **Inspector** (what Drafter sees on screen), **Settings**, **Help**.

## Clipboard and the Quick panel

| Feature | Key | Default |
|---|---|---|
| Clipboard picker: recent copies, ↑ ↓ to choose, ← → the form, ↵ puts in | ⌘⇧V | on (not in terminals and editors) |
| Quick panel: what you copied, typed and said, over any app | ⌃⌥V | on |
| Pick parts of a long copy | ⌃⌥P, or the strip's offer | on |
| A copy's written forms (plain, one line, quote) | ⇧⇥ on a copy chip | on |

## Snippets, the `;` picker and people

| Feature | Key | Default |
|---|---|---|
| The one `;` picker: snippets, quick starts, lookups, people | Right ⌘ twice, or `;` plus 2 letters | on |
| Snippets: `;mail` puts in your address | ⇥ | on |
| People: `;ana` lists people; 1 name, 2 phone, 3 email, 4 address, 5 company | 1 to 6 | on (your contacts) |
| "Ana's number" offers the field as a chip | ⇥ | on |
| In AI apps a name gets a quiet mark; ⌥⇥ attaches what Drafter knows about it | ⌥⇥ | on |

## Screenshots

| Feature | Key | Default |
|---|---|---|
| Screenshot to a capture deck, with a spoken caption per shot | ⌘⇧5 once macOS's own is off | on |
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
| `claude` | Claude actions through a signed-in `claude` CLI |
| `gam` | `;docs`, `;meetings`, `;free` Google lookups through GAM |
| `beeper` | Your older lines per chat from Beeper, for better guesses in chats |
| `vault` | A notes folder (Obsidian): a note action, people and projects, your notes for training |
| `voice_guide` | A text file describing your writing voice |

## What is not in this repository

The first user's own tools are not part of the core: a private knowledge app, a private inbox, an older dictation app,
background jobs and training on a private server, a nightly cloud batch, and a local MCP server. Everything here runs
on one Mac.
