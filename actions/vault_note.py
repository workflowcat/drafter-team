"""Vault note through the vault skill named in the local config: "запиши в нотатки: ...", "занотуй ...", "save to vault: ..."."""
import re
from _ask import fields
import _claude, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import local

ID = "vault.note"
NEEDS = ("claude", "vault")   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(запиши|занотуй|збережи)\s+(в|у)\s+(нотатки|волт|обсідіан|vault)|(?:^|[\s,.])(save|note)\s+(this\s+)?(to|in)\s+(the\s+)?(vault|obsidian)")


def extract(line, ask):
    f = fields(ask, "З команди зберегти нотатку витягни коротку назву нотатки і сам текст нотатки (слова автора, без команди).",
               line, ["title", "text"])
    if not f.get("text"): return None
    return {"chip": f"Note in {local.setting('vault', 'name') or 'the vault'} «{f.get('title') or 'untitled'}» (Claude + {local.setting('vault', 'skill') or 'files'}, in the background)", "run": {"kind": "python"},
            "fields": {"title": f.get("title", ""), "text": f["text"]}}


def run(fields):
    vault = local.setting("vault", "name") or "notes"
    return _claude.run(ID, local.setting("vault", "skill") or "default", f"File this note into the {vault} vault. Title: {fields['title']!r}. Text, kept as written: {fields['text']!r}. "
                       "Never write into people/private.", ["Read", "Write", "Edit", "Glob", "Grep", "Skill"])
