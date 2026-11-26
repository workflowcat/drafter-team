"""Call prep (2026-10-20): a few lines before a call from what is already on this Mac. Today that is the opt-in vault
cache: notes whose title or text match the call window's title (engine/obsidian.py, engine/local_search.py).
Read-only. `people` stays in the answer for the app (app/PreMeetingBriefRules.swift); nothing fills it now."""
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data"


def about(text, *, data_dir=None):
    """Title matches in the opt-in vault cache: {lines, people, vault_notes}."""
    import obsidian
    from local_search import LocalSearchIndex
    data = Path(data_dir) if data_dir is not None else DATA
    hits = []
    if obsidian.enabled(data):
        index = LocalSearchIndex(data_dir=data)
        try:
            hits = index.search(text, kinds=["obsidian"], limit=3)
        finally: index.close()
    return {"lines": ["Obsidian: " + r["title"] + " - " + " ".join(r["snippet"].split())[:100] for r in hits[:2]],
            "people": [],
            "vault_notes": [{k: r.get(k, "") for k in ("id", "title", "snippet", "url")} for r in hits]}
