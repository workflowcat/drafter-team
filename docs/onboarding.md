# Onboarding: Drafter on your Mac in about 30 minutes

Drafter shows grey ghost text at the caret in any app, from a small model on your own Mac. Tab takes it. Turn on
voice and hold Right Option to dictate. It can record a call or a long spoken note and write notes from it. Nothing
leaves your Mac unless you connect a model or turn on an integration yourself.

## Get the code

```bash
git clone https://github.com/workflowcat/drafter-team.git
```

```bash
cd drafter-team
```

## The fast way: ask Claude

If you use Claude Code, open it in the folder you cloned and say:

> set up Drafter for me

The `drafter-setup` skill in `.claude/skills/` runs the checklist below with you. It checks the Mac, installs what is
missing, picks and downloads the models that fit your memory, builds the app, fills in your config, and tells you
which permissions to grant. It asks before each download and never sends your text anywhere.

## By hand

1. **Check the Mac.** You need Apple silicon, macOS 15 or newer, and free disk: about 3 GB for typing only, about
   8 GB with voice. 16 GB of memory or more is best.

   ```bash
   python3 scripts/doctor.py
   ```

   The doctor prints every step, what is done, and the next command for what is missing. Run it again at any time.

2. **Install the tools, if the doctor asks for them:** uv (Python) and Apple Command Line Tools.

   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```

   ```bash
   xcode-select --install
   ```

3. **Set up the environment, the models and the app.** This takes 10 to 20 minutes, mostly downloads: about 1 GB
   for typing, and 4.1 GB more for voice.

   ```bash
   scripts/setup.sh --models --app
   ```

   Add `--voice` for dictation and calls: `scripts/setup.sh --models --app --voice`. Nothing starts yet. Setup
   installs the exact packages in `requirements-lock.txt` and does not resolve them again, so a change on PyPI
   cannot break it.

   A teammate may hand you a prebuilt `Drafter.app` (from `scripts/package_app.sh`). Then clone into the folder it
   names (`~/drafter-team` by default), run `scripts/setup.sh --models` without `--app`, and unzip the app into
   `~/Applications`. No Command Line Tools needed.

4. **Open Drafter.**

   ```bash
   open ~/Applications/Drafter.app
   ```

   A pen appears in the menu bar, and the first time a Welcome window opens. It walks through steps 5 to 11 below,
   one by one, each with its own button; every step but Accessibility can be skipped. Open it again from the menu bar:
   Welcome and setup….

5. **Grant Accessibility.** System Settings > Privacy & Security > Accessibility: turn on Drafter. It is required:
   Drafter reads the field you type in and puts the ghost text there. Then quit Drafter from the menu bar pen and
   open it again. This is the one permission that needs a restart.

6. **Tell Drafter who you are.** In the Welcome window, type your name and the languages you write in (for example
   `uk, en`). They are saved in `data/drafter.local.json` under `user`; open that file to add one sentence about your work. Every key is optional. This file never goes into
   git.

7. **Turn on voice** (if you ran setup with `--voice`). Voice starts off. In the menu bar pen, turn on "Voice on
   Right Option", then allow the Microphone when macOS asks.

8. **Optional: calls and meeting notes.** Screen & System Audio Recording lets Drafter hear the other side of a call
   and read text above the caret when an app gives none. Screenshots while recording are off; turn on "Screenshots
   while recording" in Settings to keep them in `data/calls/<time>/shots/`, on this Mac only.
   Calendars lets Drafter offer meeting notes 1 minute before an event with a video link.

9. **Optional: connect a model.** Settings > Cloud > Connect a model: Claude Code on this Mac, an Anthropic API key,
   or an OpenAI-compatible endpoint. Connecting turns nothing on; each switch under Cloud stays off until you turn
   it on. [Privacy](privacy.md) lists what each one sends.

10. **Start at login** (optional):

    ```bash
    scripts/install-login.sh
    ```

    Then run the one command it prints.

11. **Try it.** Type a few words in Notes: grey text appears when the model is fairly sure, and Tab takes a word.
    With voice on, press Right Option, say a sentence, press Right Option again: the words wait in the strip, and ↵
    puts them in at the caret.

12. **Check again.** `python3 scripts/doctor.py` should end with "Ready."

## Your first day

- Type in any app: mail, Slack, Notes, a browser. Grey text appears when the model is fairly sure. ⇥ takes a word,
  ⇧⇥ takes all of it, and any other key ignores it.
- A take is one dictation. Hold Right Option and speak, or press it to start and again to stop. The words show in the
  strip; ↵ puts them in at the caret, and Esc drops them (they stay in the window). Press Right Option twice to put
  the last take in again.
- ⇧ Right Option starts a recording: a long note, or a call when a call app is using the microphone.
- ⇧⌘V opens the clipboard picker: what you copied, typed and said. ↑ ↓ choose, ↵ puts it in.
- Open the window from the menu bar pen to see the stream: what you typed, said and copied, by day. Search it from
  the field at the top.
- Settings (⌘, in the window) turns each part on or off. Help lists every key; [features](features.md) lists
  every feature with its default.

## After a week

Drafter learns your words and phrases as you use it. To train a small layer on your own writing, gather it first
([your data](your-data.md)), then:

```bash
scripts/train.sh --check
```

```bash
scripts/train.sh
```

Quit Drafter before training. It takes 15 to 40 minutes on power.

## When something is wrong

- No ghost text: check Accessibility in System Settings > Privacy & Security, then quit and reopen Drafter.
- The doctor says the engine does not answer: wait a minute after opening the app, then look at the end of
  `data/engine.log`.
- Dictation does nothing: check that "Voice on Right Option" is on in the menu bar pen, the Microphone permission,
  and that the voice models are downloaded (`scripts/setup.sh --models --app --voice`). The words wait in the strip
  until you press ↵.
- Everything else: [customise](customize.md) explains every setting, and Claude Code with the `drafter-setup` skill
  can read the logs with you.

Next: [every feature](features.md) · [make it yours](customize.md) · [your data and training](your-data.md) · [privacy](privacy.md)
