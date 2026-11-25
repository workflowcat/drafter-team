"""Weekly page (2026-10-20, run by bench/nightly.sh on Fridays): what Drafter did for him in the last 7 days, local
only. Notes and calls with their follow-ups, voice minutes and words, letters Tab saved, replies drafted, questions
asked, words learned. Writes data/review/week-YYYY-MM-DD.md and prints it.

    .venv/bin/python bench/week.py [days]      (default 7)"""
import json, re, sys, time
from collections import Counter
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
days = int(sys.argv[1]) if len(sys.argv) > 1 else 7
since = time.time() - days * 86400
first_day = time.strftime("%Y-%m-%d", time.localtime(since))


def rows(name):
    try: return [r for r in (json.loads(l) for l in (ROOT / "data" / name).read_text().splitlines() if l.strip()) if r.get("t", 0) >= since]
    except Exception: return []


takes, acc, typed, clip = rows("takes.jsonl"), rows("accepted.jsonl"), rows("typed.jsonl"), rows("clipboard.jsonl")
log = [l for l in (ROOT / "data/app.log").read_text(errors="ignore").splitlines() if l[:10] >= first_day]
count = lambda pat: sum(1 for l in log if re.search(pat, l))
spoken = [t for t in takes if t.get("text")]
words = sum(len(t["text"].split()) for t in spoken)
apps = Counter(t.get("app", "") for t in spoken).most_common(4)

def ghosts_by_length(log):
    """Grey text per app and length when shown (app.log "ghost ... len N ... taken T typed Y"): how many were taken,
    and the letters taken or typed through by hand."""
    by = {}
    for l in log:
        m = re.search(r"ghost (\S+) (\S+) len (\d+) word \d+ taken (\d+) typed (\d+)", l)
        if not m: continue
        n = int(m.group(3)); b = next(b for lo, hi, b in kept.BUCKETS if lo <= n < hi)
        r = by.setdefault(m.group(1).split(".")[-1], {}).setdefault(b, [0, 0, 0, 0])
        r[0] += 1; r[1] += int(m.group(4)) > 0; r[2] += int(m.group(4)); r[3] += int(m.group(5))
    order = [b for *_, b in kept.BUCKETS]
    lines = ["", "## Сірий текст за довжиною (ended / taken / letters taken / typed through)"]
    for app, bs in sorted(by.items(), key=lambda x: -sum(v[0] for v in x[1].values())):
        lines.append(f"- {app}: " + ", ".join(f"{b} {v[0]}/{v[1]}/{v[2]}/{v[3]}" for b, v in sorted(bs.items(), key=lambda x: order.index(x[0]))))
    return lines


out = [f"# Drafter: тиждень до {time.strftime('%d.%m.%Y')}", ""]
notes = sorted((f for f in (ROOT / "data/notes").glob("*.md") if f.stat().st_mtime >= since), key=lambda f: f.name)
out += [f"## Нотатки і дзвінки: {len(notes)}"]
for f in notes:
    t = f.read_text(errors="ignore").splitlines()
    out.append(f"- {f.stem[:10]} {t[0].lstrip('# ') if t else f.stem}")
    fu = [l.strip() for l in t if re.match(r"\s*(- \[ \]|→)", l)][:3]
    out += ["  " + l for l in fu]
if not notes: out.append("- немає")
out += ["", "## Голос",
        f"- {len(spoken)} записів, {sum(t.get('secs', 0) for t in spoken) / 60:.0f} хв, {words} слів"
        + (f" (≈{words / 40:.0f} хв друку зекономлено)" if words else ""),
        "- де: " + (", ".join(f"{a or '?'} {n}" for a, n in apps) or "—")]
out += ["", "## Текст",
        f"- Tab узяв {len(acc)} разів, {sum(len(a.get('text', '')) for a in acc)} знаків",
        f"- надіслано рядків, з яких вчиться: {len(typed)}",
        f"- чернеток відповіді (Tab у порожньому полі): {count(r'reply drafted')}",
        f"- питань до нотаток: {count(r'ask: answered')}",
        f"- дзвінків запропоновано / записано: {count(r'call: offered')} / {count(r'call: recording')}",
        f"- у буфері збережено: {len(clip)}"]
try:
    learned = [w for w in json.loads((ROOT / "data/words.json").read_text())["words"] if w.get("source") == "edits"]
    out.append(f"- слів вивчено з правок (усього): {len(learned)}")
except Exception:
    pass
# kept letters (2026-11-13, roadmap item 5): of the grey text taken with Tab, how much is still in what he sent
try:
    sys.path.insert(0, str(ROOT / "bench"))
    import kept
    out += ["", "## Залишилось після Tab (kept letters)"] + (kept.report(days) or ["- немає"])
    out += ghosts_by_length(log)
except Exception as e:
    out += ["", f"## Kept letters: {e}"]
# his writing the typing help learns from, per source (bench/corpus.py, rebuilt every night)
try:
    cs = json.loads((ROOT / "data/corpus-counts.json").read_text())
    out += ["", "## З чого вчиться (рядки / слова / надиктовано)"] + [
        f"- {s}: {c.get('kept', 0)} / {c.get('words', 0)} / {c.get('dictated', 0)}" for s, c in cs["sources"].items()]
except Exception:
    pass
stops = count(r"engine exited|guard")
if stops: out += ["", f"## Збої: двигун зупинявся {stops} разів"]
text = "\n".join(out) + "\n"
(ROOT / "data/review").mkdir(parents=True, exist_ok=True)
(ROOT / "data/review" / f"week-{time.strftime('%Y-%m-%d')}.md").write_text(text)
print(text)
