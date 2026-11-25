"""Parity round (2026-11-15): the held-set slices the round measures on, from data/bench/weights/held-137.json. Loads
no model. Prints counts only. -> data/bench/parity/<name>.json

    .venv/bin/python -B bench/parity_sets.py

clip      held lines that had a copy in the 2 minutes before he sent them (data/clipboard.jsonl against the send time in
          data/typed.jsonl), with that copy as `clip` (prompt.clip_text decides what of it the prompt shows); a copy that
          overlaps the line itself (he copied what he wrote) is left out
noise     30 other held lines, each with a copy from another day (not the line's own): what an unrelated copy costs
notes     24 held lines (12 AI apps, 12 chats, AI apps every 5th line, chats every 3rd) for the instruction tests"""
import json, random, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import prompt

DATA = ROOT / "data"
OUT = DATA / "bench/parity"
norm = lambda t: " ".join((t or "").split())


def overlaps(a, b):
    a, b = norm(a).lower(), norm(b).lower()
    return bool(a and b) and (a[:30] in b or b[:30] in a)


def main():
    held = json.loads((DATA / "bench/weights/held-137.json").read_text())
    typed = [json.loads(l) for l in (DATA / "typed.jsonl").open()]
    clips = [json.loads(l) for l in (DATA / "clipboard.jsonl").open()]
    clips = [c for c in clips if c.get("kind") not in ("image", "file") and c.get("text") and c.get("t")]
    sent = {}
    for r in typed: sent.setdefault(norm(r.get("text")), r.get("t"))
    with_clip, rest, why = [], [], {"no time": 0, "no copy": 0, "own text": 0, "unsafe": 0}
    for i, h in enumerate(held):
        t = sent.get(norm(h["text"]))
        if t is None: why["no time"] += 1; rest.append(i); continue
        cs = [c for c in clips if 0 < t - c["t"] <= 120]
        if not cs: why["no copy"] += 1; rest.append(i); continue
        c = cs[-1]
        if overlaps(c["text"], h["text"]): why["own text"] += 1; rest.append(i); continue
        if not prompt.clip_safe(norm(c["text"])): why["unsafe"] += 1; rest.append(i); continue
        with_clip.append({**h, "clip": c["text"]})
    rng = random.Random(7)
    pool = [c["text"] for c in clips if prompt.clip_safe(norm(c["text"])) and len(norm(c["text"])) >= 12]
    noise = []
    for i in rng.sample(rest, min(30, len(rest))):
        h = held[i]
        c = rng.choice([p for p in pool if not overlaps(p, h["text"])])
        noise.append({**h, "clip": c})
    ai = [h for h in held[::5] if h["app"].lower().startswith("claude")][:12]
    chat = [h for h in held[1::3] if not h["app"].lower().startswith("claude")][:12]
    OUT.mkdir(parents=True, exist_ok=True)
    for name, rows in (("clip", with_clip), ("noise", noise), ("notes", ai + chat)):
        (OUT / f"{name}.json").write_text(json.dumps(rows, ensure_ascii=False))
    print(json.dumps({"held": len(held), "clip": len(with_clip), "left out": why, "noise": len(noise), "notes": len(ai + chat),
                      "clip chars in prompt p50": sorted(len(prompt.clip_text(r["clip"])) for r in with_clip)[len(with_clip) // 2] if with_clip else 0}))


if __name__ == "__main__":
    main()
