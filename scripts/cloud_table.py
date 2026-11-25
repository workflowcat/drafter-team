"""The table of features that can send text to Claude, from engine/cloud.py, for docs/privacy.md.

    python3 scripts/cloud_table.py            # prints the table
    python3 scripts/cloud_table.py --write    # puts it between the cloud-table markers in docs/privacy.md

tests/test_public_docs.py fails when the page and engine/cloud.py disagree."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import cloud

START, END = "<!-- cloud-table:start -->", "<!-- cloud-table:end -->"
WHAT = {
    "rework": "rework a selection (shorter, clearer, ...) with Option-Tab",
    "rewrite": "speak over a selection to rewrite it",
    "command": "the command panel line, after you pick it",
    "ask": "a spoken question to your own notes",
    "call_notes": "the live outline and the summary of a call or long note",
    "entities": "the kind of a name no source knows (the name only), when you run it",
    "backoffice": "a nightly or on-demand batch: tags the day, cleans call notes, person cards, grades ghosts, the weekly review",
    "voice_claude": "a Clean or Polished voice take after it went in, with names and the screen text before it; Raw never",
    "pause_rewrite": "after a 1.5 s typing pause: the paragraph before the caret, with the ⌥Tab rework context",
}


def table():
    rows = ["| Feature | What it does | Settings switch that owns it (default) |", "|---|---|---|"]
    for f, owners in cloud.OWNERS.items():
        own = " + ".join(f"`{k}` ({'on' if cloud.DEFAULTS[k] else 'off'})" for k in owners) or "none: runs only on your own action"
        rows.append(f"| `{f}` | {WHAT.get(f, '')} | {own} |")
    return "\n".join(rows)


def write(path=ROOT / "docs/privacy.md"):
    text = path.read_text()
    a, b = text.index(START) + len(START), text.index(END)
    path.write_text(text[:a] + "\n" + table() + "\n" + text[b:])


if __name__ == "__main__":
    write() if "--write" in sys.argv else print(table())
