# Drafter

An offline writing helper for macOS. Grey ghost text at the caret in any app from a small model on this Mac,
voice on Right Option, call and long-note recording. Swift menu-bar app in `app/`, Python engine in `engine/`.
For people: README.md and docs/. This file is for coding agents working in this repository.

## What leaves the Mac
Ghost text, transcription and training stay local. Text goes to a model outside the Mac only after the user connects
one (Settings > Connect a model) and turns on that feature's switch. Every such call goes through
`claude_on(feature)` and `engine/cloud.py`; docs/privacy.md lists them. Optional integrations
(`engine/integrations.py`) are off unless `data/drafter.local.json` turns them on, and fail quietly.

## Keys
Tab takes the next ghost word or runs the chip (⇧Tab the whole ghost). Right Option = voice (hold = push to talk,
Esc drops); ⇧ Right Option = long note, or records a call. ⌥Tab on a selection = rework list. Double Shift = other
layout for the last word. ⌘K = command field in the window. Any other key drops the ghost and goes to the app.

## Parts
`app/` (all `*.swift` build into one binary): AppKind kind of app (ai/chat/mail) · Autocorrect typo and layout fix,
offered at Space · Call call watch, offers, `Spool` files, `Tape` writes both sides on the mic queue · CaptureRules
back-off, side warnings, call pick, unread (pure) · Clip copied-text chips · Command floating command panel ·
CorrectionRules pure take-back rules · Emoji emoji codes · Entry voice-history rows, `TypedList` one row per message ·
Facts fact chips · Fields snippet fill-ins · FixMarks visible undo · Fixer mid-word fix ghost and at-space offer ·
Focus Accessibility reads and inserts · Ghost grey text panel and chip · History takes and clipboard history ·
IdeaRules phrases worth a snippet (pure) · Keys event tap, requests, chips · Layout wrong-layout fix · LocalSnapshot
off-thread file snapshots · LogStats 7-day shown/taken from app.log (pure) · LookupQuery `;docs` etc. · Main menu,
settings, engine process, `log()`, test typer · Mic microphone capture · PeopleCards / PersonRules person cards ·
Pill notch strip · PixelTokens generated colours · Presets quick starts · Preview `--ui-preview` renders · Proof
proofread chip · Recording / Recordings Calls & notes model and view · Rework ⌥Tab list · Rules spoken corrections ·
Screen OCR fallback · SettingsRules calendar groups (pure) · Shots screenshots in recordings · SnippetRules /
Snippets snippets · Theme native PixelKit · Transcript brief, echo (pure) · Translate translate chip · Voice voice
engine process, takes, memory budget · Window main window · Words dictation clean-up · build.sh, sync-pixelkit.py, icon/.

`engine/`: server.py HTTP on 127.0.0.1:8798, started by the app · model.py one warm MLX model ·
gatecore.py show/hide gate · words.py word finisher, booster, fix · memory.py phrase memory · prompt.py prompt head ·
people.py per-chat lines, `beeper_bin()` · style.py example lines (optional Beeper) · claude_type.py Claude on a pause, helper workers
· claude_worker.py kept Haiku worker · router.py online/offline · proofread.py, translate.py, rework.py, facts.py the
Claude chips · command.py command line · lookup.py Google lookups · snippets.py snippet cues · actions.py action picker
· notes.py long-note notes · ask.py ask your notes · prep.py call prep · edits.py learn from edits · integrations.py optional tools · local.py local config · provider.py Connect a model · dictionary.py shared
dictionary · know.py, contacts.py knowledge pack · guard.py memory watchdog · voice.py voice process (Parakeet,
Whisper) · voice_settings.py, voice_language.py, stand_ins.py voice helpers.

Also: `actions/` chip actions · `dictionary/` words, presets, cues · `bench/` benches, review, retrain, nightly.sh ·
`scripts/` setup, checks, smoke, rotate_logs.py · `tests/` · `data/` the user's data, never in git.

## Build and test
- Setup: `scripts/setup.sh --models --app` (`--help` for the options). The app builds with `app/build.sh` into
  `~/Applications/Drafter.app`; the bundle id and launchd label come from `data/drafter.local.json` (`build`).
- Tests: each file in its own process, `zsh scripts/run_tests.sh` for all Python tests, or
  `.venv/bin/python -B tests/test_x.py`. Swift: a pure file with its test, the exact command heads each test file.
  Whole app: `swiftc -typecheck -swift-version 5 -parse-as-library -target arm64-apple-macosx15.0 app/*.swift`.
- A typing change brings numbers before and after (docs/contributing.md).
- Work in a git worktree on a branch; the roles in `.claude/agents/` describe each track (docs/building-with-agents.md).

## Never
- No second model in the engine process; no model run without the memory guard (`engine/guard.py`); short test runs
  before long ones.
- Never send a message. Chat actions fill a draft box only.
- Tests that type or insert go only into a field holding `⟦drafter-test⟧`.
- `data/` never goes to git or anywhere off the Mac. No paste or Accessibility writes into password fields, skipped
  apps, or while secure input is on.
- Keys never in settings, a log or a process argument.

## Privacy for agents
The user's text in `data/` (typed lines, drafts, clipboard, takes, notes, calls) never goes into code, tests, docs or
commits: numbers only, made-up lines in tests. Names and accounts live in `data/drafter.local.json`, never in tracked
files (`tests/test_no_private.py`). Rows and fields holding `⟦drafter-test⟧` are never learned.
