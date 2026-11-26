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
| Turn a part on or off (ghosts, voice, calls, Quick panel, offers) | Settings | Each switch says what it does. Help lists every key. |
| Typing model | Settings > Typing > Model | The list marks the one that suits your Mac. Download, then pick it. Smaller is faster, bigger guesses better. |
| How bold the ghosts are | Settings > Typing | Fewer and surer, or more and earlier. |
| A writing instruction for every app, or for one app | Settings > Typing | For example "short, no greetings" for Slack. Goes into the local model's prompt. |
| Voice level per app: Raw, Clean, Polished, or your own mode | Settings > Voice, or say "mode email" as a whole take, or type `;mode` | Your own modes are a name and a prompt. Polished and your modes use a connected model. |
| Snippets (`;mail` to your address and so on) | The Shortcuts page (⌘J in the window) | Saved in `data/snippets.json`. |
| Words Drafter should know (names, terms) | The Dictionary page (⇧⌘D, or the menu bar pen) | Helps both typing and dictation. |
| Quick panel and clipboard picker keys | Settings, search "quick" | Keys are in one registry, `app/KeyMap.swift`; Help shows the live list. |
| Cloud helpers (proofread, rework, call notes, summaries) | Settings > Cloud > Connect a model | Off until you connect Claude Code, an Anthropic key or any OpenAI-compatible endpoint (a local server works too). [Privacy](privacy.md) lists what each switch sends. |
| Look | Settings, search "look" | Follows macOS light and dark and your accent colour. |

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
- `languages`: the languages you type and dictate in. A language not listed here is not learned from (for example,
  Russian lines stay out of training unless `"ru"` is listed).
- `corpus`: which of your own writing trains your layer. See [your data](your-data.md).
- `integrations`: tools on your Mac Drafter may use, all off by default. Each is on only when you set
  `"enabled": true` and its tool answers (`python3 engine/integrations.py` shows each one's state):

| Name | What it adds |
|---|---|
| `claude` | Claude actions through a signed-in `claude` CLI |
| `gam` | `;docs`, `;meetings`, `;free` Google lookups through the GAM CLI |
| `beeper` | Your older lines per chat from the Beeper app |
| `vault` | A notes folder (an Obsidian vault): a note action, and your own notes for training |
| `voice_guide` | A text file describing your writing voice, for the next-message prompt |

## 3. The code

- **Actions** (`actions/*.py`): a chip offered at the caret when a line matches, for example "add to calendar". One
  file per action: a trigger regex, a function that pulls the fields, and what it does. See `actions/README.md`.
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
