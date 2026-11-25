"""Call prep (2026-10-20): who the call is likely with (names in the call window's title, matched in Aleph) and a few
lines about each from what is already known: role and projects, last contact, the latest note, open follow-ups that
mention them. Read-only (Aleph's database, Inbox follow-ups, Drafter's own notes)."""
import json, re, sqlite3, time
from pathlib import Path
import notes

import local, integrations
DB = Path(local.setting("aleph", "db") or "/nonexistent/aleph.db")          # optional integrations (engine/integrations.py)
FOLLOW = Path(local.setting("inbox", "path") or "/nonexistent") / "followups.json"
NOTES = Path(__file__).resolve().parent.parent / "data/notes"


def facts(c, pid, rels):
    q = f"select rel, obj, value, at from facts where subj=? and until is null and rel in ({','.join('?' * len(rels))}) order by at desc"
    return c.execute(q, (pid, *rels)).fetchall()


def name_of(c, tid):
    r = c.execute("select coalesce(nullif(short,''), name) from things where id=?", (tid,)).fetchone()
    return r[0] if r else tid.split(":", 1)[-1]


def _people_about(text):
    people = [l for l in notes.links(text) if l["kind"] == "person"][:2]
    if not people: return {"lines": [], "people": []}
    c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    lines = []
    for p in people:
        f = facts(c, p["id"], ("role", "works_on", "works_at", "last_contact", "note"))
        role = next((v or name_of(c, o) for r, o, v, _ in f if r == "role"), "")
        work = [name_of(c, o) for r, o, v, _ in f if r in ("works_on", "works_at") and o][:2]
        last = next((at for r, o, v, at in f if r == "last_contact"), None)
        note = next((v for r, o, v, _ in f if r == "note" and v), "")
        head = p["name"] + (f" — {role}" if role else "") + (f" · {', '.join(work)}" if work else "")
        if last: head += f" · востаннє {time.strftime('%d.%m', time.localtime(last))}"
        lines.append(head)
        if note: lines.append("  нотатка: " + note.replace("\n", " ")[:110])
        first = p["name"].split()[0].lower()
        try:
            open_fu = [x for x in json.loads(FOLLOW.read_text()) if not x.get("isDone") and first in (x.get("what", "") + " " + x.get("person", "")).lower()]
            for x in open_fu[:2]: lines.append("  фоловап: " + x["what"][:100])
        except Exception:
            pass
        for f2 in sorted(NOTES.glob("*.md"), reverse=True)[:40]:
            t = f2.read_text(errors="ignore")
            if re.search(r"(?i)\b" + re.escape(first[:4]), t):
                lines.append("  " + f2.stem[:10] + ": " + t.splitlines()[0].lstrip("# ")[:90]); break
    c.close()
    return {"lines": lines[:6], "people": [p["name"] for p in people]}


def about(text, *, data_dir=None):
    """Participant facts plus title/participant matches in the opt-in vault cache."""
    try: result = _people_about(text)
    except (OSError, sqlite3.Error): result = {"lines": [], "people": []}
    import obsidian
    from local_search import LocalSearchIndex
    data = Path(data_dir) if data_dir is not None else NOTES.parent
    hits = []
    if obsidian.enabled(data):
        index = LocalSearchIndex(data_dir=data)
        try:
            hits = index.search(" ".join([text, *result["people"]]), kinds=["obsidian"], limit=3)
        finally: index.close()
    result["vault_notes"] = [{k: r.get(k, "") for k in ("id", "title", "snippet", "url")} for r in hits]
    # The existing call window consumes lines: reserve a slot even when person facts fill the brief.
    vault_lines = ["Obsidian: " + r["title"] + " - " + " ".join(r["snippet"].split())[:100] for r in hits[:2]]
    if vault_lines: result["lines"] = result["lines"][:max(0, 4 - len(vault_lines))] + vault_lines
    return result
