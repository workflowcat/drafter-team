"""Mid-line round (2026-11-15, docs/rounds/2026-11-15-fim.md): fill in the middle with the live model. Numbers only.

    .venv/bin/python -B bench/fim.py sets                       # data/bench/fim/mid.json from the held set
    .venv/bin/python -B bench/fim.py rec none|after [--smoke]   # guarded recording (bench/fim_record.py), mains power only
    .venv/bin/python -B bench/fim.py score <rec.jsonl> [...]    # the table
    .venv/bin/python -B bench/fim.py eol data/bench/big-live.jsonl   # today's end-of-line ghosts, same metrics

Set: each held line (data/bench/weights/held-137.json, all after the last retrain) with 4+ words loses one span of 1-4
whole words from its middle (seeded by the line, never its first or last word; trailing punctuation stays in the rest).
The rest of the line after the span is what the app sends as `after_line` (at most 120 characters, the app's limit).
Keys: every caret position from the end of the word before the gap to the end of the span (the last key is "nothing
missing": he has typed it all, any ghost there is wrong).

Policy (what he would see): the live gate (data/gate.json, not refit) on the first word, as the engine decides; then
the candidate's rule; a ghost under `--min` letters is not shown (the app's minGhost, 5).
  eol     the same keys as line ends: today's ghost against all his next words (no mid-line rule, no trim)
  today   end-of-line rule (first word + sure words >= 0.5, up to 3) and the app's own midText trim
  cut     engine/fim.shape without the probability stop (text rules only)
  fim     engine/fim.shape (stop at p(rest) >= STOP, text rules)
Metrics per 1,000 keys: shown, exact fill (ghost == the missing text), first word right, wrong offers (first word
wrong); words right in a row (mean at shown keys); ms to the ghost's last token (p50/p95)."""
import argparse, json, re, statistics, subprocess, sys, zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
for p in (ROOT / "engine", HERE):
    if str(p) not in sys.path: sys.path.insert(0, str(p))
import fim, gatecore

SET = ROOT / "data/bench/fim/mid.json"
TOKEN_END = re.compile(r"[\w'’-]")


def sets():
    held = json.loads((ROOT / "data/bench/weights/held-137.json").read_text())
    out = []
    for it in held:
        t = it["text"]
        if "\n" in t: continue
        ws = [(m.start(), m.end()) for m in re.finditer(r"\S+", t)]
        if len(ws) < 4: continue
        h = zlib.crc32(t.encode())
        k = 1 + h % 4
        k = min(k, len(ws) - 2)
        lo, hi = 1, len(ws) - 1 - k          # span = words[a : a+k], a in [lo, hi]
        if hi < lo: continue
        a = lo + (h // 4) % (hi - lo + 1)
        s, e = ws[a - 1][1], ws[a + k - 1][1]
        while e > ws[a + k - 1][0] + 1 and not TOKEN_END.match(t[e - 1]): e -= 1   # "park," -> the comma stays in the rest
        rest = t[e:]
        if not rest.strip() or len(rest) > 120 or not re.search(r"\w", t[:s]): continue
        out.append({"text": t, "app": it["app"], "src": it["src"], "context": it.get("context", ""), "gap": [s, e]})
    SET.parent.mkdir(parents=True, exist_ok=True)
    SET.write_text(json.dumps(out, ensure_ascii=False))
    keys = sum(e - s + 1 for s, e in (x["gap"] for x in out))
    print(json.dumps({"lines": len(out), "keys": keys, "words": statistics.mean(len(x["text"][x["gap"][0]:x["gap"][1]].split()) for x in out)}))


def on_power():
    s = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout
    return "AC Power" in s.splitlines()[0] if s else True


def others():
    pat = r"guarded\.py|bench/big/run\.py|typebench|record\.py"
    r = subprocess.run(["pgrep", "-fl", pat], capture_output=True, text=True).stdout
    return [l for l in r.splitlines() if "pgrep" not in l]


def rec(form, smoke):
    import os, time
    if not on_power(): raise SystemExit("on battery: not starting")
    for _ in range(2):
        if others(): raise SystemExit("another model step runs: " + "; ".join(others())[:200])
        time.sleep(30)
    label = f"mid-{form}" + ("-smoke" if smoke else "")
    env = dict(os.environ, DRAFTER_MID_FORM=form, DRAFTER_HEAD_CACHE="")
    cmd = [str(ROOT / ".venv/bin/python"), "-B", str(HERE / "weights/guarded.py"), "4.0", str(HERE / "fim_record.py"),
           "--label", label] + (["--n", "3"] if smoke else [])
    r = subprocess.run(cmd, env=env, cwd=ROOT, stdin=subprocess.DEVNULL)
    raise SystemExit(r.returncode)


def load(path):
    items = json.loads(SET.read_text())
    rows = [json.loads(l) for l in Path(path).read_text().splitlines()]
    return items, rows


class Gate:
    def __init__(self):
        import ngram
        from retrain_state import last_retrain
        self.g = gatecore.load(ROOT / "data/gate.json")
        self.W = ngram.Words(ngram.corpus(last_retrain(ROOT)))

    def p(self, toks, before, src):
        """The engine's decision on the first word (server._complete decide, live weights). -> p or None."""
        # the engine decides on the tokens up to the one that ends the first word
        cut = next((j for j, t in enumerate(toks) if t[0] and (gatecore.word_done(t[0]) or fim.END.search(t[0]))), len(toks) - 1)
        line = before.split("\n")[-1]
        finish = self.W.finish(before, 2, 0.5, 1) if re.search(r"[\w'’-]$", line) else ""
        f, _ = gatecore.features([t[:3] for t in toks[: cut + 1]], before, src == "claude", finish)
        return gatecore.score(self.g["w"], f) if f else None


def clean(before, text):
    import measure
    return measure.clean(before, text)


def app_trim(ghost, rest):
    """app/GhostRules.midText."""
    g = re.split(r"[\r\n]", ghost, maxsplit=1)[0]
    for k in range(min(len(g), len(rest), 40), 1, -1):
        if g.endswith(rest[:k]): g = g[:-k]; break
    if rest[:1].isspace(): g = g.rstrip()
    return g


def ghost(rule, row, before, rest, stop=fim.STOP, more=fim.MORE, words=fim.WORDS):
    toks = row["toks"]
    if not toks or not toks[-1][0]: return "", 0.0
    closed = len([t for t in toks if t[0]]) < 16
    if rule == "eol":
        out = clean(before, gatecore.extend([t[:3] for t in toks], gatecore.next_word(toks[-1][0]), 0.5, 3))
        return out, next((t[3] for t in toks if t[0] and len(t[0]) > len(out.rstrip())), toks[-1][3])
    if rule == "today":
        out = gatecore.extend([t[:3] for t in toks], gatecore.next_word(toks[-1][0]), 0.5, 3)
        g = app_trim(clean(before, out), rest)
        end = len(out.rstrip())
    else:
        rests = [t[5] for t in toks]
        g, why = fim.shape(toks, rests, rest, row.get("heal", ""), more, words, stop if rule == "fim" else None, closed=closed)
        g = fim.cut(clean(before, g), rest)
        end = len(g)
    ms = next((t[3] for t in toks if t[0] and len(t[0]) > end), toks[-1][3])
    return g, ms


def words_of(s):
    return re.findall(r"\S+", s)


def judge(g, before, target):
    """(exact, first right, words right in a row) of ghost g against the missing text `target`."""
    gn, tn = " ".join(words_of(g)), " ".join(words_of(target))
    lead = (g[:1].isspace()) == (target[:1].isspace()) or before[-1:].isspace()
    exact = bool(gn) and gn == tn and lead
    gw, tw = words_of(g), words_of(target)
    k = 0
    for a, b in zip(gw, tw):
        if a != b: break
        k += 1
    # the first word of the gap may be the half word he is typing: compare the letters that follow the caret
    first = bool(gw) and bool(tw) and gw[0] == tw[0] and (g[:1].isspace() == target[:1].isspace())
    return exact, first, k


def score(path, rules=("eol", "today", "cut", "fim"), min_letters=5, stop=fim.STOP, more=fim.MORE, words=fim.WORDS, quiet=False):
    items, rows = load(path)
    G = Gate()
    out = {}
    for rule in rules:
        n = shown = exact = first = wrong = 0
        runs, ms, last_shown = [], [], 0
        for r in rows:
            it = items[r["i"]]; s, e = it["gap"]
            before, rest, target = it["text"][: r["pos"]], it["text"][e:], it["text"][r["pos"]: e]
            if rule == "eol": target = it["text"][r["pos"]:]      # the same key read as a line end: his next words
            n += 1
            p = G.p(r["toks"], before, it["src"]) if r["toks"] and r["toks"][-1][0] else None
            if p is None or p < G.g["th"]["ai" if it["src"] == "claude" else "chat"]: continue
            g, t_ms = ghost(rule, r, before, rest, stop, more, words)
            if not g.strip() or gatecore.letters(g) < min_letters: continue
            shown += 1; ms.append(t_ms)
            ex, fr, k = judge(g, before, target)
            exact += ex; first += fr; wrong += not fr; runs.append(k)
            last_shown += r["pos"] == e
        q = lambda xs, p: sorted(xs)[min(len(xs) - 1, int(len(xs) * p))] if xs else None
        out[rule] = {"keys": n, "shown_1k": round(1000 * shown / n, 1), "exact_1k": round(1000 * exact / n, 1),
                     "first_1k": round(1000 * first / n, 1), "wrong_1k": round(1000 * wrong / n, 1),
                     "exact_shown": round(100 * exact / max(1, shown), 1), "first_shown": round(100 * first / max(1, shown), 1),
                     "run_shown": round(statistics.mean(runs), 2) if runs else 0, "shown_nothing_missing": last_shown,
                     "ms_p50": q(ms, .5), "ms_p95": q(ms, .95)}
        if not quiet: print(f"{Path(path).stem:18s} {rule:6s} {out[rule]}", flush=True)
    return out


def eol(path, min_letters=5):
    """Today's end-of-line ghosts on the whole held set (a typebench recording), with the same gate, policy and metrics:
    shown, first word right, wrong offers per 1,000 keys, words right in a row at shown keys."""
    import typescore as ts
    items, rows = ts.load(path)
    G = Gate()
    n = shown = first = 0; runs = []
    for (i, pos), r in rows.items():
        text = items[i]["text"]; before = text[:pos]
        n += 1
        toks = r.get("toks") or []
        if not toks or not toks[-1][0]: continue
        p = G.p(toks, before, items[i]["src"])
        if p is None or p < G.g["th"]["ai" if items[i]["src"] == "claude" else "chat"]: continue
        out = clean(before, gatecore.extend([t[:3] for t in toks], gatecore.next_word(toks[-1][0]), 0.5, 3))
        if not out.strip() or gatecore.letters(out) < min_letters: continue
        shown += 1
        _, fr, k = judge(out, before, text[pos:])
        first += fr; runs.append(k)
    res = {"keys": n, "shown_1k": round(1000 * shown / n, 1), "first_1k": round(1000 * first / n, 1),
           "wrong_1k": round(1000 * (shown - first) / n, 1), "first_shown": round(100 * first / max(1, shown), 1),
           "run_shown": round(statistics.mean(runs), 2) if runs else 0}
    print(json.dumps(res))
    return res


def sweep(path):
    for stop in (0.1, 0.2, 0.3, 0.5):
        for more in (0.3, 0.5):
            for words in (3, 4):
                r = score(path, ("fim",), stop=stop, more=more, words=words, quiet=True)["fim"]
                print(f"stop {stop} more {more} words {words}: exact {r['exact_shown']}% first {r['first_shown']}% "
                      f"wrong/1k {r['wrong_1k']} exact/1k {r['exact_1k']} nothing-missing shown {r['shown_nothing_missing']}", flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["sets", "rec", "score", "eol", "sweep"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--min", type=int, default=5)
    a = ap.parse_args()
    if a.cmd == "sets": sets()
    elif a.cmd == "rec": rec(a.args[0], a.smoke)
    elif a.cmd == "score":
        for p in a.args: score(p, min_letters=a.min)
    elif a.cmd == "eol": eol(a.args[0], a.min)
    else: sweep(a.args[0])
