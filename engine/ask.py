"""Ask your notes (2026-10-20): a take that starts with "Drafter, …" / "Драфтер, …" is a question, not text to paste.
Snippets come from the user's long notes and calls (data/notes), voice takes (data/takes.jsonl, or data/journal.sqlite with `journalDB` on). Claude Haiku answers in 2-3 lines with
where it came from; the app shows it in the strip, nothing is pasted."""
import json, re, time
from pathlib import Path
import claude_worker, local
from data_dir import data_dir
import journal_db

ROOT = Path(__file__).resolve().parent.parent
WAKE = re.compile(r"(?i)^\s*(drafter|драфтер|дрaфтер|дрефтер|дрaфтэр)[,.:!?]?\s+")
STOP = set("що як де коли хто чи і й та в у на з із до про по за це той та the a an of to in on is was what when who where how did do i me my".split())


def words(s):
    return {w for w in re.findall(r"[\w'’]{3,}", s.lower()) if w not in STOP}


def score(q, text):
    t = text.lower()
    return sum(1 for w in q if w[:5] in t)


def gather(question):
    q = words(question)
    found = []
    for f in sorted((data_dir() / "notes").glob("*.md"), reverse=True)[:200]:
        t = f.read_text(errors="ignore")
        s = score(q, t)
        if s: found.append((s + 0.5, f"нотатка {f.stem[:16]}", t[:1500]))
    try:
        # the newest 2000 takes; with `journalDB` on from data/journal.sqlite, hidden and removed takes left out
        for r in journal_db.takes_rows(data_dir(), 2000):
            t = r.get("text", "")
            if len(t) < 25: continue
            s = score(q, t)
            if s >= 2: found.append((s, "голос " + time.strftime("%d.%m %H:%M", time.localtime(r.get("t", 0))), t[:600]))
    except Exception:
        pass
    found.sort(key=lambda x: -x[0])
    return found[:8]


def answer(question):
    t = time.perf_counter()
    q = WAKE.sub("", question).strip()
    snips = gather(q)
    if not snips:
        return {"answer": "Нічого про це в нотатках не знайшов.", "sources": [], "ms": 0}
    prompt = ("Answer " + local.possessive() + " question from his own notes below, in the language of the question, in 2-3 short lines. "
              "Use only what the notes say; if they do not answer it, say so in one line. End with the sources you used "
              "in brackets, like [нотатка 2026-10-20].\n\nQuestion: " + q + "\n\nNotes:\n"
              + "\n\n".join(f"[{src}]\n{txt}" for _, src, txt in snips) + "\n\nPut the answer between <answer> and </answer>.")
    raw = claude_worker.ask(prompt, 40) or ""
    m = re.search(r"<answer>(.*?)</answer>", raw, re.S)
    out = (m.group(1).strip() if m else "") or snips[0][2][:200]
    return {"answer": out[:500], "sources": [s for _, s, _ in snips], "ms": round((time.perf_counter() - t) * 1000)}


if __name__ == "__main__":
    import sys
    print(json.dumps(answer(" ".join(sys.argv[1:])), ensure_ascii=False, indent=1))
