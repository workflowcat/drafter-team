"""Big-model round (2026-11-15): one table for several recordings of the same held set (bench/typebench.py with
--tokens 24), each model judged with its own gate (refit on held-out folds of its own recording, as gate.summary does),
model text only (no phrase memory, no word finisher), so the models compare and nothing else moves. Numbers only.

    .venv/bin/python -B bench/big/score.py data/bench/<base>.jsonl data/bench/<other>.jsonl ... [--out data/bench/big/x.json]

The first recording is the baseline for the paired 95 % intervals (whole lines resampled together).
The default historical-big preserves this table. --policy-mode current-2026-11-16 changes the replay's
request flags only; gates remain out-of-fold, and static replay cannot exercise keep-in-flight.
Per app kind (claude = AI apps, beeper = chats) and language:
  first right %   at every key: the model's first word is his next word (no gate)
  run all         at every key: words right in a row from the caret (mean, p50, p90, 3+ %, 5+ %), as Tab, Tab, Tab
  run gated       the same at the keys its own gate says yes to (th 0.4): what he would see
  saved/1k        letters saved per 1,000 in sentence mode (gatecore.run_words, floor 0.1, cap 24) with the gate,
                  in the replay (a new ghost after the words he took: the rolling ghost)
  wrong/1k        grey words shown that were not his, per 1,000 letters (same replay)
  shown, right %  ghosts shown and first word right among them
  word ms         ms to the first whole word (the token that ends it: when the gate can decide) p50, p90, p95
  token ms        ms per token after the first, p50
  retrain score   gate.summary saved % and right % (the weekly retrain's own score, comparable with earlier rounds)"""
import argparse, json, random, re, statistics, sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
for p in (ROOT / "bench", ROOT / "engine"):
    if str(p) not in sys.path: sys.path.insert(0, str(p))
import gatecore, measure, request_policy

END = re.compile(r"[.!?…)\n]")
TH = 0.4


def q(xs, p):
    return sorted(xs)[min(len(xs) - 1, int(len(xs) * p))] if xs else None


def decision(toks):
    for j, t in enumerate(toks):
        if t[0] and (gatecore.word_done(t[0]) or END.search(t[0])): return j
    return len(toks) - 1


def ended_by_model(row):
    w = [t for t in row["toks"] if t[0]]
    return bool(w) and len(w) < row.get("max_tokens", 24) and "\n" not in w[-1][0]


def run_len(row, text, pos):
    """Words of the model's text right in a row from the caret (bench/long_ghosts.py runs, the same rule)."""
    if not row["toks"] or not row["toks"][-1][0]: return 0
    raw = measure.clean(text[:pos], row["toks"][-1][0])
    ws = re.findall(r"\s*\S+ ?", raw.split("\n")[0])
    if ws and not ws[-1].endswith(" ") and not ended_by_model(row) and len(raw.split("\n")) == 1: ws = ws[:-1]
    k, at = 0, pos
    for w in ws:
        if text[at:].startswith(w) or (w is ws[-1] and text[at:].startswith(w.rstrip()) and at + len(w.rstrip()) == len(text)): k += 1; at += len(w)
        else: break
    return k


def first_ok(row, text, pos):
    if not row["toks"] or not row["toks"][-1][0]: return False
    w = measure.clean(text[:pos], row["toks"][-1][0])
    w = re.match(r"\s*\S+", w)
    return bool(w) and text[pos:].startswith(w.group(0)) and (pos + len(w.group(0)) == len(text) or not text[pos + len(w.group(0))].isalnum()
                                                              or not w.group(0)[-1].isalnum())


class Sentence:
    """Recorded model path: historical sentence mode by default, or the dated current request mode."""

    def __init__(self, P, cap=24, floor=gatecore.RUN_FLOOR, policy_mode=request_policy.BIG):
        self.request_policy = request_policy.build(policy_mode)
        self.run = self.request_policy.run_kwargs()
        self.run.pop("cap")
        self.run["floor"] = floor
        if "max_words" in self.run: self.run["words"] = self.run.pop("max_words")
        self.P, self.cap, self.floor, self.info = P, cap, floor, None

    def __call__(self, row, before, src):
        self.info = None
        p = self.P.get(row.get("_key"))
        bar = self.request_policy.guess_bar
        if p is None or p < (TH if bar is None else min(TH, bar)): return "", 0
        consumed, count, decided = [], 0, False
        for tok in row["toks"]:
            consumed.append(tok)
            if not tok[0]: continue
            count += 1
            if not decided and (gatecore.word_done(tok[0]) or END.search(tok[0])): decided = True
            if decided:
                _, _, why, _ = gatecore.run_words(consumed, **self.run)
                if gatecore.run_settled(why): break
            if count >= self.cap: break
        if not consumed or not consumed[-1][0]: return "", 0
        closed = "eos" if len(consumed) == len(row["toks"]) and ended_by_model(row) else ("cap" if count >= self.cap or len(consumed) == len(row["toks"]) else None)
        text, sure, why, confs = gatecore.run_words(consumed, closed=closed, **self.run)
        out = measure.clean(before, text)
        if out and gatecore.letters(out) < self.run["min_letters"]: return "", 0
        d = decision(consumed)
        self.info = {"first_ms": consumed[d][3], "full_ms": consumed[-1][3], "src": "model"}
        return out, consumed[-1][3]


def oof(rec):
    """(items, rows, P): out-of-fold gate probabilities for every key of this recording (bench/gate.py)."""
    import gate, ngram, typescore as ts
    from retrain_state import last_retrain
    items, rows = ts.load(rec)
    for k, r in rows.items(): r["_key"] = k
    W = ngram.Words(ngram.corpus(last_retrain(ROOT)))
    X, y, keys = gate.dataset(items, rows, W)
    return items, rows, gate.held_out(items, X, y, keys)


def keys_of(it):
    return [it["src"], f"{it['src']}/{measure.lang(it['text'])}", "all"]


def per_line(items, rows, P):
    """{line: {"first": [..], "run": [..], "gated": [..], "word_ms": [..], "tok_ms": [..]}}"""
    out = defaultdict(lambda: defaultdict(list))
    for (i, pos), row in rows.items():
        text = items[i]["text"]
        L = out[i]
        k = run_len(row, text, pos)
        L["run"].append(k); L["first"].append(first_ok(row, text, pos))
        if P.get((i, pos), 0) >= TH: L["gated"].append(k)
        t = row.get("toks") or []
        if t:
            L["word_ms"].append(t[decision(t)][3]); L["first_ms"].append(t[0][3])
            L["tok_ms"] += [b[3] - a[3] for a, b in zip(t, t[1:])]
    return out


def agg(lines):
    run = [k for L in lines for k in L["run"]]; gated = [k for L in lines for k in L["gated"]]
    first = [x for L in lines for x in L["first"]]
    wm = [x for L in lines for x in L["word_ms"]]; fm = [x for L in lines for x in L["first_ms"]]; tm = [x for L in lines for x in L["tok_ms"]]
    st = lambda xs: {"mean": round(statistics.mean(xs), 3) if xs else 0, "p50": q(xs, .5), "p90": q(xs, .9),
                     "3+": round(100 * sum(x >= 3 for x in xs) / max(1, len(xs)), 1), "5+": round(100 * sum(x >= 5 for x in xs) / max(1, len(xs)), 1), "n": len(xs)}
    return {"first_right": round(100 * sum(first) / max(1, len(first)), 1), "run": st(run), "gated": st(gated),
            "word_ms": (q(wm, .5), q(wm, .9), q(wm, .95)), "first_ms": (q(fm, .5), q(fm, .9), q(fm, .95)), "token_ms": round(statistics.median(tm), 2) if tm else None}


def boot(a_lines, b_lines, fn, n=1000, seed=7):
    """95 % interval of fn(b) - fn(a) over the same lines resampled together."""
    rnd, vals = random.Random(seed), []
    for _ in range(n):
        idx = [rnd.randrange(len(a_lines)) for _ in a_lines]
        vals.append(fn([b_lines[j] for j in idx]) - fn([a_lines[j] for j in idx]))
    vals.sort()
    return round(vals[int(.025 * n)], 3), round(vals[int(.975 * n)], 3)


def score_one(rec, policy_mode=request_policy.BIG):
    import gate
    items, rows, P = oof(rec)
    lines = per_line(items, rows, P)
    pol = Sentence(P, policy_mode=policy_mode)
    res, per = measure.replay(items, rows, pol)
    out = {"rec": Path(rec).name, "groups": {}}
    for key in ("all", "claude", "beeper", "claude/en", "claude/uk", "beeper/uk"):
        idx = [i for i, it in enumerate(items) if key in keys_of(it)]
        if not idx: continue
        g = agg([lines[i] for i in idx])
        sub = [l for l in per if key == "all" or l["src"] == key or f"{l['src']}/{l['lang']}" == key]
        letters = sum(l["letters"] for l in sub)
        gs = [x for l in sub for x in l.get("ghosts", [])]
        g.update({"saved_1k": round(1000 * sum(l["saved"] for l in sub) / max(1, letters), 1),
                  "wrong_1k": round(1000 * sum(x[1] - x[0] for x in gs) / max(1, letters), 1),
                  "shown": len(gs), "right": round(100 * sum(l["right"] for l in sub) / max(1, sum(l["shown"] for l in sub)), 1),
                  "taken_mean": round(statistics.mean([x[0] for x in gs]), 2) if gs else 0,
                  "words_shown_p50": q([x[1] for x in gs], .5), "words_shown_p90": q([x[1] for x in gs], .9),
                  "lines": len(idx)})
        out["groups"][key] = g
    try:
        out["retrain"] = gate.summary(rec)
    except Exception as e:
        out["retrain"] = {"error": str(e)[:120]}
    return out, items, lines, per


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recs", nargs="+")
    ap.add_argument("--out", default=None)
    request_policy.add_argument(ap, request_policy.BIG)
    a = ap.parse_args()
    base = None
    table = []
    for rec in a.recs:
        s, items, lines, per = score_one(rec, a.policy_mode)
        if base is None: base = (items, lines, per)
        else:
            bi, bl, bp = base
            if [it["text"] for it in bi] != [it["text"] for it in items]: raise SystemExit(f"{rec}: another set")
            s["vs_base"] = {}
            for key in s["groups"]:
                idx = [i for i, it in enumerate(items) if key in keys_of(it)]
                A, B = [bl[i] for i in idx], [lines[i] for i in idx]
                mean_run = lambda Ls: statistics.mean([k for L in Ls for k in L["run"]] or [0])
                first = lambda Ls: 100 * statistics.mean([x for L in Ls for x in L["first"]] or [0])
                pa = [l for l in bp if key == "all" or l["src"] == key or f"{l['src']}/{l['lang']}" == key]
                pb = [l for l in per if key == "all" or l["src"] == key or f"{l['src']}/{l['lang']}" == key]
                saved = lambda Ls: 1000 * sum(l["saved"] for l in Ls) / max(1, sum(l["letters"] for l in Ls))
                rnd, vals = random.Random(7), []
                for _ in range(1000):
                    j = [rnd.randrange(len(pa)) for _ in pa]
                    vals.append(saved([pb[x] for x in j]) - saved([pa[x] for x in j]))
                vals.sort()
                s["vs_base"][key] = {"run_mean": boot(A, B, mean_run), "first_right": boot(A, B, first),
                                     "saved_1k": (round(vals[25], 1), round(vals[975], 1))}
        table.append(s)
        g = s["groups"]
        for key, v in g.items():
            vb = (s.get("vs_base") or {}).get(key, {})
            print(f"{s['rec'][:44]:44s} {key:9s} first {v['first_right']:5.1f}% {vb.get('first_right', '')} | run all mean {v['run']['mean']:.2f} "
                  f"{vb.get('run_mean', '')} p50 {v['run']['p50']} p90 {v['run']['p90']} 3+ {v['run']['3+']}% 5+ {v['run']['5+']}% | "
                  f"gated mean {v['gated']['mean']:.2f} p90 {v['gated']['p90']} 3+ {v['gated']['3+']}% 5+ {v['gated']['5+']}% n {v['gated']['n']} | "
                  f"saved/1k {v['saved_1k']} {vb.get('saved_1k', '')} wrong/1k {v['wrong_1k']} shown {v['shown']} right {v['right']}% | "
                  f"word ms {v['word_ms']} token ms {v['token_ms']}", flush=True)
        print(f"{'':44s} retrain score {s.get('retrain')}", flush=True)
    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text(json.dumps(table, indent=1))


if __name__ == "__main__":
    main()
