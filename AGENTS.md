# Drafter

An offline writing helper for macOS. Grey ghost text at the caret in any app from a small model on this Mac,
voice on Right Option, call and long-note recording. Swift menu-bar app in `app/`, Python engine in `engine/`.
For people: README.md and docs/. This file is for coding agents working in this repository.

## This repository
The Drafter core: typing, voice, calls and notes, the window and its UI. Work here goes to the core and the UI; tools
of one person stay in their own config or their own fork. It lives on GitHub only (https://github.com/workflowcat/drafter-team, public):
branch, open a pull request or push to `origin`; never force. Nothing private may land here: names, hosts, paths and
text of a real person go in `data/drafter.local.json`, which is never tracked (`tests/test_no_private.py`).
When a feature is added, removed or its default changes, update `docs/features.md` in the same change.

## What leaves the Mac
Ghost text, transcription and training stay local. Text goes to a model outside the Mac only after the user connects
one (Settings > Cloud > Connect a model) and turns on that feature's switch. Every such call goes through
`claude_on(feature)` and `engine/cloud.py`; docs/privacy.md lists them. Optional integrations
(`engine/integrations.py`) are off unless `data/drafter.local.json` turns them on, and fail quietly.

## Keys
`app/KeyMap.swift` is the one list. ⇥ takes the next ghost word or runs the chip (⇧⇥ the whole ghost). Right Option =
voice once turned on (menu: Voice on Right Option; hold = push to talk, ↵ puts the take in, Esc drops); ⇧ Right
Option = a recording (long note or call). ⌥⇥ on a selection = rework list. Double Shift = other layout for the last
word. ⇧⌘V = clipboard picker (⌃⌥V off by default). ⌘K = command field in the window. Any other key drops the ghost
and goes to the app. Docs write keys in macOS order (⌃⌥⇧⌘) and use "Esc" and "↵".

## Parts
`app/` (all `*.swift` build into one binary; a `*Rules.swift` file is pure, with its test in `tests/`):
- Typing: Keys, KeyHooks, KeyMap (every key, the one registry), Focus (Accessibility reads and inserts), Ghost, Fixer,
  Autocorrect, Typo*, Layout, Words, Typography, LiveType, Put*/Insert*, Rework, PauseRewrite, Reader, Screen and
  ScreenContext (text above the caret).
- Voice: Voice (the voice process), VoicePipeline, Voice*Rules, Talk*, Mic, Duck, Speed.
- Recordings (calls and long notes): Call*, Recording, Recordings, RecordWindow, MeetingNotes, Shots, Shot*,
  ScreenVideo*, Tape*, Speakers, Transcript*, FileTranscribe, AudioImport.
- The window: Window, Stream*, Journal* (the SQLite journal), Search*, Inspector*, Entity*, Names*, People*, Links*,
  TodayThread*, Topic*, ShareBriefRules (Share notes), SettingsView, Settings, SettingsRules, HelpViews, Look, Panel,
  PageChrome, PageParts.
- Clipboard and screenshots: Quick* (the clipboard picker), Clip*, Pick*, Paste*, Capture*, Deck*, Markup*, ScrollShot,
  PictureLook*.
- Snippets and commands: Snippets, SnippetRules, SpokenSnippetRules, Fields, SmartFields, Command*, Commands, Presets,
  Dictionary, DictRules, Synonym*, Mention*, Actions, DetectActions.
- Glue: Main, MenuBar, Engine (the engine process), Connect (Connect a model), LocalConfig, Preview* (`--ui-preview`),
  DevHooks, build.sh, icon/.

`engine/`: server.py HTTP on 127.0.0.1:8798, started by the app · model.py one warm MLX model · catalog.py,
fetch_model.py typing models · gatecore.py show/hide gate · prompt.py, chat_template.py prompts · words.py word
finisher · memory.py phrase memory · fim.py mid-line ghosts · cadence.py, instant.py, idle_prompt.py · typos.py,
word_fixes.py, synonyms.py · whom.py keyboard hint · rework.py, pause_rewrite.py, voice_claude.py the cloud helpers ·
cloud.py which switch owns each · provider.py Connect a model · claude_type.py, claude_worker.py, worker_pool.py the
CLI workers · router.py online/offline · command.py, actions.py, snippets.py · notes.py, ask.py, promises.py,
speakers.py recordings · names.py, entities.py, know.py, dictionary.py knowledge · journal_db.py · edits.py, marks.py,
reader.py, tweaks.py · integrations.py optional tools · local.py local config · data_dir.py the data folder ·
guard.py memory watchdog · voice.py voice process (Parakeet, Whisper), voice_settings.py, voice_language.py,
voice_timing.py, whisper_mel.py, stand_ins.py.

Also: `actions/` chip actions · `dictionary/` words, presets, cues · `bench/` benches, retrain, nightly.sh ·
`scripts/` setup, doctor, downloads, checks, rotate_logs.py, prune_audio.py · `tests/` · `data/` the user's data, never in git.

## Build and test
- Setup: `python3 scripts/doctor.py`, then `scripts/setup.sh --models --app` (add `--voice` for dictation and calls;
  `--help` for the options). People follow docs/onboarding.md. The app builds with `app/build.sh` into
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
