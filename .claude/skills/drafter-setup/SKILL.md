---
name: drafter-setup
description: Set up, check, update or fix Drafter (the offline writing helper in this repository) on this Mac - install the tools, pick and download the models that fit this Mac, build the app, fill in the person's config, grant permissions, gather their own writing into data/import and train their layer. Use when someone says "set up Drafter", "install Drafter", "download the models", "Drafter does not work", "train Drafter on my writing", "import my Slack/Telegram messages into Drafter" or "update Drafter".
---

# Drafter setup

You help one person get Drafter running on their own Mac and make it theirs. Work from the repository root. The
guides you follow and point to: `docs/onboarding.md`, `docs/customize.md`, `docs/your-data.md`, `docs/privacy.md`.

## Rules

- `data/` is the person's private writing. Never print, quote or summarise its contents; counts only. Never commit it,
  copy it elsewhere or send it anywhere. Never read `data/drafter.local.json` aloud beyond the keys you set.
- Ask before each download (say its size) and before anything that starts at login.
- Never type passwords, tokens or keys yourself. A cloud model key goes in through Drafter's own Settings > Cloud >
  Connect a model, typed by the person.
- Never change macOS settings for them: tell them which permission to turn on and where.
- Nothing is sent to a server unless the person turns on an integration in their config and says so.

## 1. Where are we

```bash
python3 scripts/doctor.py --json
```

Each check has `ok`, `optional`, `detail` and `next` (the command that fixes it). Tell the person in a few lines what
is done and what is left, then work through the required ones in order. Run the doctor again after each step.

## 2. Tools

- uv missing: `curl -LsSf https://astral.sh/uv/install.sh | sh`, then open a new shell.
- swiftc missing: `xcode-select --install` opens a macOS dialog; the person clicks Install and waits.
- ffmpeg is optional (`brew install ffmpeg` if they have Homebrew).

## 3. Environment and models

Ask what they want: typing only, or typing and voice (dictation and calls). Free disk needed: about 3 GB for typing
only, about 8 GB with voice. Then:

```bash
scripts/setup.sh --models --app          # typing: about 1 GB to download
scripts/setup.sh --models --app --voice  # typing and voice: about 5 GB to download
```

Run it in the background; it takes 10 to 20 minutes, mostly downloads. If a download fails, run it again: it goes on
from where it stopped.

The doctor's "suggested for this Mac" line names the typing model that fits this Mac's memory and speed. The default
one (Qwen3 1.7B) works everywhere, and it is the only one `scripts/train.sh` trains a layer for. To use the
suggested one, the person picks it in Drafter: Settings > Typing > Model, Download, then select. Or download it ahead
from the shell, by its catalog id (the doctor line shows it), which also takes the revision pinned in
`engine/catalog.json` (ask first, with its `disk_gb` from the catalog):

```bash
.venv/bin/python -B engine/fetch_model.py --id <catalog id from the doctor line>
```

## 4. Their config

`data/drafter.local.json` (written by setup.sh from `drafter.local.example.json`). Ask for, and fill in under `user`:
name, short name, the forms of their own name (`own_names`), the languages they write in (codes like `uk`, `en`), one
sentence about their work (`about`), and how they write (`style_rules`, for example "short sentences, no exclamation
marks"). Every key is optional; keep the JSON valid. Leave `integrations` off unless they ask for one; explain each
from `docs/customize.md` first.

## 5. Open, permissions, voice, login

Follow the order in `docs/onboarding.md`:

```bash
open ~/Applications/Drafter.app
```

1. Accessibility (required): System Settings > Privacy & Security > Accessibility, turn on Drafter, then quit
   Drafter from the menu bar pen and open it again. Only this permission needs the restart.
2. Their config (step 4 above), if not done yet.
3. Voice (if set up with `--voice`): it starts off. They turn on "Voice on Right Option" in the menu bar pen and
   allow the Microphone.
4. Optional: Screen & System Audio Recording (the other side of calls; Drafter then keeps screenshots of the screen
   in `data/calls/<time>/shots/` while a recording runs, off in Settings: "Screenshots while recording") and
   Calendars (meeting notes before an event).
5. Optional: Settings > Cloud > Connect a model, typed by the person. Connecting turns no switch on.
6. Optional, ask first: `scripts/install-login.sh` and the one `launchctl bootstrap` command it prints.
7. Try it: grey text in Notes, Tab takes a word. With voice on: Right Option, a sentence, Right Option again; the
   words wait in the strip until ↵ puts them in.
8. Run the doctor again: it should end with "Ready."

## 6. Their own writing (optional, after setup)

Follow `docs/your-data.md`. To convert an export they give you (a Slack, Telegram or WhatsApp export, a mail
archive): ask for the file and the exact name they appear under in it. Write a small Python script in a temporary
folder (not in the repo) that keeps only their own messages and writes `data/import/<app>.jsonl`, one
`{"text", "t", "app"}` per line. Run it, then report counts only:

```bash
.venv/bin/python bench/corpus.py --dry-run
```

Never show their lines back to them as examples; give counts per source. Then:

```bash
scripts/train.sh --check
```

If there is enough, they quit Drafter and run `scripts/train.sh` (15 to 40 minutes, on power). They reopen Drafter
after it.

## 7. When something is wrong

- Run the doctor first.
- Engine silent: Drafter needs up to a minute after opening. Then `tail -n 40 data/engine.log`, and look only for
  error lines and tracebacks (the log may hold their text: do not quote it).
- No ghosts: Accessibility is off, or the app is in Settings' skipped list, or the field is a password field.
- Build fails: `zsh app/build.sh` and read the first `error:` line.
- Tests: `zsh scripts/run_swift_tests.sh` (a failure keeps its whole output in `app/build/test-logs/`) and
  `.venv/bin/python -B tests/<file>.py`.

## 8. Updating

```bash
git pull && scripts/setup.sh --models --app      # add --voice if they use voice
```

Then quit and reopen Drafter. `data/` stays as it is.
