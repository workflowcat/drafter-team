# Your data: gather your writing and train on it

Drafter gets better at guessing your next words the more of **your own** writing it has seen. All of it stays in
`data/` on your Mac, which is never in git. Training runs on your Mac too.

## What Drafter keeps by itself

| File | What | Turn off |
|---|---|---|
| `data/typed.jsonl` | Each message you send with ↵ while Drafter is on | Menu bar: "Learn from what I send" |
| `data/takes.jsonl` | Your dictation takes | Settings > Voice |
| `data/clipboard.jsonl` | Text you copied (for the clipboard picker; never trained on) | Settings, search "clipboard" |
| `data/calls/` | Recordings and transcripts of calls and long notes | Settings > Calls |

Password fields, apps you skip and secure input are never read.

## Bring in writing you already have

Put your own writing into `data/import/`. Drafter reads three kinds of file there:

- `*.txt` and `*.md`: split into paragraphs; headings and front matter are skipped.
- `*.jsonl`: one message per line, `{"text": "...", "t": 1764000000, "app": "Slack"}`. Only `text` is required;
  `t` is the time in Unix seconds.

Or point Drafter at a notes folder without copying it: add it to `corpus.folders` in `data/drafter.local.json`
(read only, `.md` and `.txt`):

```json
"corpus": {"typed": true, "takes": true, "folders": ["~/Documents/Notes"]}
```

Good sources, in order of value:

1. Messages you sent: a Slack export, a Telegram export, WhatsApp chats, mail you wrote. **Keep only your side.**
   Other people's lines teach the model their voice, not yours.
2. Documents and notes you wrote yourself.
3. Prompts you typed to Claude Code or Codex: set `"claude_code": true` or `"codex": true` in `corpus`. Drafter reads
   only your own prompts from their session files.

Leave out text you pasted from elsewhere, agent output, and anything you would not want a model to repeat.

### Converting an export

Each app exports differently. The `drafter-setup` Claude skill can write a small converter for yours: give it the
export file and your name as it appears there, and it writes `data/import/<app>.jsonl` with your lines only. By hand,
the shape is all that matters:

```python
import json
mine = [...]   # your own messages from the export: (unix_time, text)
with open("data/import/slack.jsonl", "w") as f:
    for t, text in mine:
        f.write(json.dumps({"text": text, "t": t, "app": "Slack"}, ensure_ascii=False) + "\n")
```

## Check what you have

```bash
.venv/bin/python bench/corpus.py --dry-run
```

It prints counts per source (lines kept, dropped as pastes, too short, repeats), never the text.

```bash
scripts/train.sh --check
```

It says whether there is enough text to train yet.

## Train

Quit Drafter from the menu bar first: training needs the memory the typing model uses.

```bash
scripts/train.sh
```

15 to 40 minutes on power. It trains a small layer (LoRA) on your lines into `data/adapters/`. Open Drafter again to
load it. With the nightly job on (`scripts/install-login.sh --nightly`) it retrains weekly and keeps a new layer only
when it beats the old one on your newest lines. [Training](training.md) explains the details.

## Moving to a new Mac

Copy the whole `data/` folder (with Drafter quit), then run `scripts/setup.sh --voice --app` on the new Mac.
Everything, your layer included, comes with it.

## Sharing with the team

Share the repository, never `data/`. Each person trains their own layer on their own writing. A layer learned from
your text can repeat your phrases, so do not hand it to someone else.
