# Onboarding: Drafter on your Mac in about 30 minutes

Drafter shows grey ghost text at the caret in any app, from a small model on your own Mac. Tab takes it. Hold Right
Option to dictate. It can record a call or a long spoken note and write notes from it. Nothing leaves your Mac unless
you connect a cloud model or turn on an integration yourself.

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

1. **Check the Mac.** You need Apple silicon, macOS 15 or newer and about 8 GB of free disk. 16 GB of memory or more
   is best.

   ```bash
   python3 scripts/doctor.py
   ```

   The doctor prints every step, what is done, and the next command for what is missing. Run it again at any time.

2. **Install the tools.** If the doctor asks for them: uv (Python) and Apple Command Line Tools.

   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```

   ```bash
   xcode-select --install
   ```

3. **Set up the environment, the models and the app.** This takes 10 to 20 minutes, mostly downloads (about 1 GB for
   typing and 4 GB more for voice).

   ```bash
   scripts/setup.sh --voice --app
   ```

   Leave out `--voice` if you only want typing. Nothing starts yet.

4. **Tell Drafter who you are.** Open `data/drafter.local.json` and fill in `user`: your name, the languages you write
   in (for example `["uk", "en"]`), and one sentence about your work. Every key is optional. This file never goes into
   git.

5. **Open the app and grant permissions.**

   ```bash
   open ~/Applications/Drafter.app
   ```

   A pen appears in the menu bar. macOS asks for permissions when a feature needs them:
   - Accessibility: required. Drafter reads the field you type in and puts the ghost text there.
   - Microphone: for voice and calls.
   - Screen & System Audio Recording: optional. Used for the other side of a call, and for text above the caret
     when an app does not give it.

   After you turn a permission on, quit Drafter from the menu bar and open it again.

6. **Start at login** (optional):

   ```bash
   scripts/install-login.sh
   ```

   Then run the one command it prints.

7. **Check again.** `python3 scripts/doctor.py` should end with "Ready."

## Your first day

- Type in any app: mail, Slack, Notes, a browser. Grey text appears when the model is fairly sure. Tab takes a word,
  Shift-Tab takes all of it, and any other key ignores it.
- Hold Right Option and speak; let go and the text goes in at the caret. Tap it twice to put the last take in again.
- Shift-Right Option records a long note, or a call when a call app is using the microphone.
- Open the window from the menu bar pen to see what you typed, said and copied. Search it from the field at the top.
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
- Dictation types nothing: check Microphone permission, and that the voice models are downloaded (`scripts/setup.sh --voice`).
- Everything else: [customise](customize.md) explains every setting, and Claude Code with the `drafter-setup` skill
  can read the logs with you.

Next: [every feature](features.md) · [make it yours](customize.md) · [your data and training](your-data.md) · [privacy](privacy.md)
