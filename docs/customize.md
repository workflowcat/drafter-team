# Make it yours

Drafter has three layers you can change, from easy to deep. None of them needs code for everyday changes.

1. **Settings in the app.** Switches, keys, models, voice modes. Saved in `data/settings.json`.
2. **Your config file.** Who you are, how you write, which tools on your Mac Drafter may use. `data/drafter.local.json`.
3. **The code.** Actions, rules and the model prompts. It is a normal repository: change it on a branch.

`data/` is yours and never goes into git, so your changes there never clash with an update.

## 1. Settings (⌘, in the window)

Settings has a search field at the top: type a word ("model", "quick", "mode") to find its switch.

| What | Where | Notes |
|---|---|---|
| Turn a part on or off (ghosts, voice, calls, clipboard picker, offers) | Settings | Each switch says what it does. Help lists every key. |
| Typing model | Settings > Typing > Model | The list marks the one that suits your Mac. Download, then pick it. Smaller is faster, bigger guesses better. `scripts/train.sh` trains your layer for the default Qwen3 1.7B only; another model runs without it ([training](training.md)). |
| How bold the ghosts are | Settings > Typing | Fewer and surer, or more and earlier. |
| A writing instruction for every app, or for one app | Settings > Typing | For example "short, no greetings" for Slack. Goes into the local model's prompt. |
| Voice level per app: Raw, Clean, Polished, or your own mode | Settings > Voice, or say "mode email" as a whole take, or type `;mode` | Your own modes are a name and a prompt. Polished and your modes use a connected model. |
| Snippets (`;mail` to your address and so on) | The Shortcuts page (⌘J in the window) | Saved in `data/snippets.json`. |
| Words Drafter should know (names, terms) | The Dictionary page (⇧⌘D, or the menu bar pen) | Helps both typing and dictation. |
| Clipboard picker keys (⇧⌘V; ⌃⌥V off by default) | Settings, search "clipboard" | Keys are in one registry, `app/KeyMap.swift`; Help shows the live list. |
| Cloud helpers: rework a selection, a rewrite after a pause, tidying a voice take, the outline and summary of a recording, the kind of a new name | Settings > Cloud > Connect a model, then each switch under Cloud | Off until you connect Claude Code, an Anthropic key or any OpenAI-compatible endpoint (a local server works too, with no key). Each switch then sends to the model you connected. [Privacy](privacy.md) lists what each switch sends. |
| Look | macOS | Follows macOS light and dark, your accent colour and the system font. |

A few keys have no row in Settings. They are config-only: quit Drafter, edit `data/settings.json`, open Drafter.

| Key | What it sets | Default |
|---|---|---|
| `voiceIdleMin` | Minutes without a take before the voice reader sleeps | 30 |
| `quickMax` | Copies the clipboard history keeps | 1000 |
| `quickSecret` | Patterns of copies never kept | API keys, card numbers, one-time codes |
| `switchQuickForm` | ⇧⌘V held shows the small list (the older way) instead of the full picker | false |

`app/SettingsRules.swift` (`hidden`) lists every key with no row.

## 2. Your config: `data/drafter.local.json`

`scripts/setup.sh` writes it from `drafter.local.example.json`. Every key is optional; `python3 engine/local.py`
prints what is in effect.

```json
{
 "user": {
  "name": "Olena Example",
  "short_name": "Olena",
  "own_names": ["Olena", "Олена"],
  "about": "Project manager; writes to clients in English and to the team in Ukrainian.",
  "languages": ["uk", "en"],
  "style_rules": "Short sentences. No exclamation marks. Ukrainian to the team, English to clients.",
  "timezone": "Europe/Kyiv",
  "city": "Kyiv"
 },
 "corpus": {"typed": true, "takes": true, "claude_code": false, "codex": false, "folders": ["~/Documents/Notes"]}
}
```

- `user` goes into the prompts: the local model's head and, when you connect one, the cloud model's. `style_rules` is
  the most useful line: write how you write.
- `languages`: the languages you type and dictate in. For learning it changes one thing: lines with Russian-only
  letters (ы, э, ъ, ё) stay out of the corpus unless `"ru"` is listed (`bench/corpus.py`). Lines in any other
  language are kept whether it is listed or not.
- `corpus`: which of your own writing trains your layer, including `folders` of your own `.md` and `.txt` files.
  See [your data](your-data.md).
- `projects.roots`: folders whose subfolders are your code projects, so a project name gets a pointer to its folder.
  None by default.
- `integrations`: tools on your Mac Drafter may use, all off by default. Each is on only when you set
  `"enabled": true` and its tool answers (`python3 engine/integrations.py` shows each one's state):

| Name | What it adds |
|---|---|
| `claude` | A signed-in `claude` CLI for actions of your own (`actions/_claude.py`) |

## 3. The code

- **Actions** (`actions/*.py`): a chip offered at the caret when a line matches, for example "add to calendar". One
  file per action: a trigger regex, a function that pulls the fields, and what it does. See `actions/README.md`. An
  action that needs your own tools or skills belongs in your fork; give it `NEEDS` so it stays off until they are on.
- **Keys**: `app/KeyMap.swift` is the one registry (job, place, default, Help line). `tests/key_map.swift` fails on a
  clash.
- **Prompts**: the local model's prompt is built in `engine/server.py` from your config; the cloud prompts are in
  `engine/` next to each feature (`engine/cloud.py` lists them).
- **Rules**: most behaviour is in pure `app/*Rules.swift` files, each with a test in `tests/`. Change the rule, run
  its test (the compile line is at the top of the test file), then the whole suite:

```bash
zsh scripts/run_swift_tests.sh
```

```bash
zsh scripts/swift_fast_check.sh --link
```

The second one builds a debug copy in seconds. To install your change, run `zsh app/build.sh`, then quit and reopen
Drafter. [Contributing](contributing.md) has the rules for tests and privacy;
[building with agents](building-with-agents.md) shows how to let Claude Code or Codex do the work.

## Updating

```bash
git pull
```

```bash
scripts/setup.sh --app
```

Your `data/` folder, settings and trained layer stay as they are.
