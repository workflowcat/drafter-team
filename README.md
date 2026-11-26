# Drafter

Drafter is a writing helper for macOS that runs on your own Mac.
It shows grey ghost text at the caret in any app, from a small language model on this Mac. Tab takes it.
Hold Right Option to dictate. It can also record a call or a long spoken note and write notes from it.
It learns how you write from what you type, and you can train a small layer on your own text.
Nothing needs a network or an account. A cloud model is something you connect yourself, and only if you want one.

Source: https://github.com/workflowcat/drafter-team

## Start here

- **New on the team?** [Onboarding](docs/onboarding.md): Drafter on your Mac in about 30 minutes.
- **With Claude Code:** open it in this folder and say "set up Drafter for me". The `drafter-setup` skill
  (`.claude/skills/drafter-setup/`) checks the Mac, downloads the models that fit it, builds the app and fills in your
  config with you.
- **What can it do?** [Features](docs/features.md): every feature, its key and whether it is on by default.
- **Where am I?** `python3 scripts/doctor.py` prints every setup step and the next command for what is missing.
- **Make it yours:** [customise](docs/customize.md) (settings, your config, the code) and
  [your data](docs/your-data.md) (bring in your own writing and train on it).

## What stays on your Mac, and what can leave

Ghost text, dictation, call transcripts and training all run locally. Your text stays in `data/` in this folder, which
is never in git.

Some helpers can use a bigger model: proofreading, translation, rework of a selection, the next message in an empty
box, call summaries. On a new install they are off and their switches are disabled. They turn on only after you pick
**Settings > Connect a model** and then turn on each switch you want. You connect one of three ways:

1. Claude Code on this Mac (a signed-in `claude` CLI).
2. An Anthropic API key.
3. An OpenAI-compatible endpoint: another provider, or a model server on your own machine.

A key goes into the macOS Keychain, never into a file or a log. **Disconnect** turns every such switch off and
deletes the key. [Privacy](docs/privacy.md) lists what each switch sends.

## Requirements

- A Mac with Apple silicon (M1 or newer) and macOS 15 or newer.
- 16 GB of memory or more. Typing alone may fit in 8 GB; that is not measured. Both models sleep after 30 idle
  minutes (`textIdleMin`, `voiceIdleMin` in Settings), so an idle Drafter holds little memory.
- About 3 GB of free disk, and 4.1 GB more for the voice models.
- [uv](https://docs.astral.sh/uv/) for Python, and Apple Command Line Tools (`xcode-select --install`) to build the app.
- Optional: `ffmpeg` to read audio files that are not WAV.

## Install

```sh
git clone https://github.com/workflowcat/drafter-team.git
cd drafter-team
scripts/setup.sh --models --app          # add --voice for dictation and calls
```

`scripts/setup.sh` checks the Mac, makes the Python environment from the pinned lock file, writes
`data/drafter.local.json` from `drafter.local.example.json`, downloads the models you asked for and builds
`~/Applications/Drafter.app`. It starts nothing. `scripts/setup.sh --help` lists the options.

Then:

1. Put your name and languages into `data/drafter.local.json` (`user`). Every key is optional.
2. Open `~/Applications/Drafter.app`. A pen appears in the menu bar.
3. Grant the permissions macOS asks for. setup.sh prints the list: Accessibility is the one typing needs.
4. To start Drafter at login, run `scripts/install-login.sh` and then the one command it prints.

## Keys

| Key | What it does |
|---|---|
| Tab | Takes the next ghost word, or runs the chip shown |
| Shift-Tab | Takes the whole ghost |
| Right Option | Voice: hold to talk, or press to start and stop; Esc drops the take |
| Shift-Right Option | A long note, or records a call |
| Option-Tab on a selection | Rework list: Shorter, Fix, Clearer, Warmer and more (needs a connected model) |
| Shift twice | The other keyboard layout for the last word |
| Command-K in the window | The command field |
| Control-Option-V | The Quick panel: what you copied, typed and said; type to narrow, Return puts it at the caret |
| Command-Shift-V | The paste switcher: hold, tap through recent copies, let go to paste |

Any other key drops the ghost and goes to the app as usual.

## The first hour

- Type in any app. Grey text appears when the model is fairly sure. Short guesses stay hidden on purpose.
- Open the window from the menu bar. **Voice**, **Calls & notes**, **Typed** and **Clipboard** show what Drafter kept.
  **Settings** turns each part on or off. **Help** has the keys.
- With "Learn from what I send" on (menu bar), Drafter keeps what you send in `data/typed.jsonl` for phrase memory and training.
- Control-Option-V opens the Quick panel over any app. Tab there rewrites the row (plain, one line, a quote, or the
  rework list). Settings sets its key, how many copies it keeps and for how long, and which copies are never kept.
- The look follows macOS: light or dark, your accent colour, the system font.
- Shortcuts are snippets: type `;mail` and Tab inserts your address once you fill it in.

## Train on your writing

After a week or two of use:

```sh
scripts/train.sh --check     # is there enough of your text yet?
scripts/train.sh             # quit Drafter first; 15 to 40 minutes on power
```

It builds a corpus from the sources your config allows (typed lines and voice takes by default) and stops with a
clear message when there is too little text. [Training](docs/training.md) explains the layer and the weekly retrain.

## Optional integrations: optional, off by default

Drafter was first built for one person's set of tools. Each one is optional, off by default, and turned on only in
`data/drafter.local.json`. When it is off or its tool does not answer, its chips and actions are not offered.

| Name | What it is | What it adds |
|---|---|---|
| `beeper` | The `beeper` CLI for the Beeper chat app | Your older lines per chat; example messages; your chats in the corpus |
| `gam` | GAM, the Google Workspace admin CLI | `;docs`, `;meetings` and `;free` lookups; contacts |
| `vault` | A notes folder | A note action; your notes in the training corpus |
| `claude` | A signed-in `claude` CLI | Claude actions (a note, a doc, a page); also on when picked under Connect a model |
| `voice_guide` | A text file that describes your writing voice | The next-message prompt |

`.venv/bin/python engine/integrations.py` prints each one's state on your Mac.

## How it is built

A Swift menu-bar app (`app/`) watches the caret through Accessibility, draws the ghost text and records voice. A
Python engine (`engine/server.py`, HTTP on 127.0.0.1:8798) holds one warm MLX model and decides what to show. A second
process reads voice with Parakeet and Whisper. [Architecture](docs/architecture.md) has the whole picture.

- [Features](docs/features.md): every feature by area, with keys and defaults
- [Architecture](docs/architecture.md): the three processes and where state lives
- [Typing](docs/typing.md): where a suggestion comes from, and the gate that hides weak ones
- [Training](docs/training.md): the personal layer, the corpus, the weekly retrain
- [Voice and calls](docs/voice-and-calls.md): takes, the strip, recording a call, call notes
- [Privacy](docs/privacy.md): Connect a model, what each feature sends, how to delete your data
- [Look](docs/look.md): the native look rules and the made-up preview renders (`scripts/look-preview.sh`)
- [Building with agents](docs/building-with-agents.md): how the work is split and checked
- [Contributing](docs/contributing.md): tests and the rules a change must meet

Tests: `zsh scripts/run_tests.sh` runs every Python test file in its own process.

## How it was built

One person directed the work; Claude agents wrote most of the code. Each track (typing, voice, look, quality) is a
saved agent role in `.claude/agents/`. Agents build in their own git worktrees, and every
change comes with tests and, for typing, numbers before and after. Other models did outside reviews of the code. [Building with agents](docs/building-with-agents.md) tells how a round runs.

## Credits and licences

- Typing model: Qwen3-1.7B (Alibaba Qwen team, Apache-2.0), MLX conversion by mlx-community.
- Voice: Parakeet TDT 0.6B v3 (NVIDIA, CC-BY-4.0) and Whisper large-v3-turbo (OpenAI, MIT), MLX conversions by
  mlx-community.
- Libraries: MLX and mlx-lm (Apple, MIT), parakeet-mlx, mlx-whisper; the full list is in `requirements-lock.txt`.
- Look: the macOS system font and SF Symbols; no bundled fonts or art. Origins of each part: [NOTICE.md](NOTICE.md).

The models are downloaded from Hugging Face by `scripts/download_models.py`; they are not part of this repository.

## Licence

MIT, copyright 2026 the user Udovychenko. See [LICENSE](LICENSE).
