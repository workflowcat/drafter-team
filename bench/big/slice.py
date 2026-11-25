"""Fast check for layer recipes (2026-11-15 q35b): a slice of the held set with every Ukrainian AI-app line, every 4th
English AI-app line and every 2nd chat line. Loads no model.

    .venv/bin/python -B bench/big/slice.py make                      -> data/bench/big/held-slice.json
    .venv/bin/python -B bench/big/slice.py cut data/bench/big-live.jsonl [--label live]
                                                                     -> data/bench/big-slice-<label>.jsonl (+ meta)

`cut` takes the slice's keys out of a held-137 recording (each key is recorded on its own, so the rows are the same as
a slice recording would give), so base and live need no new model run. Record a candidate on the slice with
`bench/big/run.py rec ... --set data/bench/big/held-slice.json --label slice-<name>`, then score all of them with
`bench/big/score.py` (the first recording is the paired baseline)."""
import argparse, hashlib, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "bench"))
FULL = "data/bench/weights/held-137.json"
SLICE = "data/bench/big/held-slice.json"


def lang(text):
    import measure
    return measure.lang(text)


def pick(items):
    """Indexes into the full set: all claude/uk, every 4th claude/en, every 2nd beeper (in set order)."""
    out, seen = [], {"claude/en": 0, "beeper/uk": 0, "beeper/en": 0}
    for i, it in enumerate(items):
        g = f"{it['src']}/{lang(it['text'])}"
        if g == "claude/uk": out.append(i); continue
        step = 4 if g == "claude/en" else 2
        if seen.get(g, 0) % step == 0: out.append(i)
        seen[g] = seen.get(g, 0) + 1
    return out


def sha(p):
    return hashlib.sha1(Path(p).read_bytes()).hexdigest()[:12]


def make(a):
    items = json.loads((ROOT / FULL).read_text())
    idx = pick(items)
    (ROOT / SLICE).parent.mkdir(parents=True, exist_ok=True)
    (ROOT / SLICE).write_text(json.dumps([items[i] for i in idx], ensure_ascii=False))
    (ROOT / (SLICE[:-5] + ".idx.json")).write_text(json.dumps(idx))
    keys = sum(len(items[i]["text"]) for i in idx)
    print(f"slice: {len(idx)} lines, about {keys} keys (full: {len(items)} lines)")


def cut(a):
    idx = json.loads((ROOT / (SLICE[:-5] + ".idx.json")).read_text())
    new = {old: j for j, old in enumerate(idx)}
    src = ROOT / a.rec
    label = a.label or src.stem.removeprefix("big-")
    dst = ROOT / f"data/bench/big-slice-{label}.jsonl"
    n = 0
    with dst.open("w") as f:
        for l in src.read_text().splitlines():
            try: r = json.loads(l)
            except ValueError: continue
            if r["i"] in new:
                r["i"] = new[r["i"]]; f.write(json.dumps(r, ensure_ascii=False) + "\n"); n += 1
    m = json.loads(Path(str(src)[:-6] + ".meta.json").read_text())
    m.update({"set": str(ROOT / SLICE), "set_sha": sha(ROOT / SLICE), "cut_from": src.name})
    Path(str(dst)[:-6] + ".meta.json").write_text(json.dumps(m, indent=1))
    print(f"{dst.relative_to(ROOT)}: {n} keys")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("make")
    p = sub.add_parser("cut"); p.add_argument("rec"); p.add_argument("--label")
    a = ap.parse_args()
    {"make": make, "cut": cut}[a.cmd](a)


if __name__ == "__main__":
    main()
