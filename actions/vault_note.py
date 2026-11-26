"""Vault note: "запиши в нотатки: ...", "занотуй ...", "save to vault: ...". Off unless the `vault` integration is on
(data/drafter.local.json `integrations.vault`). After the chip is pressed it writes one Markdown file into the vault's
`Drafter/` folder with plain Python: no model outside the Mac, no other tool. An existing note is never overwritten."""
import re, sys, time
from pathlib import Path
from _ask import fields
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import local

ID = "vault.note"
NEEDS = ("vault",)   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(запиши|занотуй|збережи)\s+(в|у)\s+(нотатки|волт|обсідіан|vault)|(?:^|[\s,.])(save|note)\s+(this\s+)?(to|in)\s+(the\s+)?(vault|obsidian)")
FOLDER = "Drafter"


def extract(line, ask):
    f = fields(ask, "З команди зберегти нотатку витягни коротку назву нотатки і сам текст нотатки (слова автора, без команди).",
               line, ["title", "text"])
    if not f.get("text"): return None
    return {"chip": f"Note in {local.setting('vault', 'name') or 'the vault'} «{f.get('title') or 'untitled'}»", "run": {"kind": "python"},
            "fields": {"title": f.get("title", ""), "text": f["text"]}}


def safe_name(title):
    name = re.sub(r"[\\/:*?\"<>|#^\[\]\x00-\x1f]", " ", title or "").strip(" .")
    return re.sub(r"\s+", " ", name)[:80] or time.strftime("Note %Y-%m-%d %H%M")


def run(fields, root=None):
    root = Path(root or local.setting("vault", "path") or "/nonexistent")
    if not root.is_dir(): return "No vault folder: set integrations.vault.path"
    folder = root / FOLDER
    folder.mkdir(exist_ok=True)
    base = safe_name(fields.get("title"))
    dest, n = folder / f"{base}.md", 2
    while dest.exists(): dest, n = folder / f"{base} {n}.md", n + 1
    head = f"# {fields['title']}\n\n" if fields.get("title") else ""
    dest.write_text(head + fields["text"].strip() + "\n")
    return f"Saved: {FOLDER}/{dest.name}"
