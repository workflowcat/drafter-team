"""Earlier round (2026-11-16, Andrii: "it starts late; it should try to offer more and start earlier"; then "lets do 3-5
words and lessen the confidence"). Offline, on recordings of the held set (bench/big/run.py rec: 24 tokens a key with
token times), each model under its own gate refit on held-out folds (bench/big/score.py oof), so the numbers sit on
the same footing as the catalog's. Loads no model. Numbers only.
Use --policy-mode current-2026-11-16 for the shared request flags. The default historical-earlier
keeps the original sweeps and labels. Gates remain out-of-fold; finishers and the live selector are not replayed.

    .venv/bin/python -B bench/earlier.py length data/bench/big-live.jsonl [data/bench/big-q4b-lr5-s10.jsonl ...] [--out f.json]

Policy at a key (the engine's model path, gate on the first word, then the run rule of engine/gatecore.py):
  sure      gate P >= TH (0.4, today)            -> shown in the usual grey
  guess     GUESS <= P < TH (the lower gate)     -> shown lighter, Tab takes it the same
  length    "sentence" (today: floor 0.1, cap 24) or "words" (min / max words, floor between them)
Replay (bench/measure.py replay): he types each line; a ghost stays while he types its letters, Tab takes each right
word, a wrong letter drops it; when the ghost runs out after Tabs a new one is asked at the same spot.

Columns (per variant, per shade):
  shown %        new ghosts / keys where one could be asked (no ghost up)
  row shown/all  words right in a row from the caret at a shown ghost (mean) / the same summed over all asked keys
  kept /1k       letters Tab put in that are his, less one key per Tab, per 1,000 typed letters
  wrong /1k      shown ghosts whose first word is not his, per 1,000 typed letters ("wrong offers")
  grey /1k       grey words shown that were not his, per 1,000 typed letters (bench/big/score.py wrong/1k)
  first, full ms ms to the first whole word (when the gate decides and the first part is drawn) and to the whole
                 ghost, p50 / p95, engine only (recorded token times)"""
import argparse, json, re, statistics, sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
for p in (ROOT / "bench", ROOT / "bench/big", ROOT / "engine"):
    if str(p) not in sys.path: sys.path.insert(0, str(p))
import gatecore, measure, request_policy

END = re.compile(r"[.!?…)\n]")
TH = 0.4


def q(xs, p):
    return sorted(xs)[min(len(xs) - 1, int(len(xs) * p))] if xs else 0


def ended_by_model(row):
    w = [t for t in row["toks"] if t[0]]
    return bool(w) and len(w) < row.get("max_tokens", 24) and "\n" not in w[-1][0]


def decision(toks):
    for j, t in enumerate(toks):
        if t[0] and (gatecore.word_done(t[0]) or END.search(t[0])): return j
    return len(toks) - 1


def ghost(row, before, mode="sentence", floor=gatecore.RUN_FLOOR, cap=24, min_words=None, max_words=None, min_letters=5):
    """The engine's run path on the recorded tokens (model.complete_gated with run=): -> (text, first ms, full ms)."""
    consumed, count, decided = [], 0, False
    kw = dict(min_letters=min_letters, min_words=min_words, words=max_words)
    for tok in row["toks"]:
        consumed.append(tok)
        if not tok[0]: continue
        count += 1
        if not decided and (gatecore.word_done(tok[0]) or END.search(tok[0])): decided = True
        if decided:
            _, _, why, _ = gatecore.run_words(consumed, mode, floor, **kw)
            if gatecore.run_settled(why): break
        if count >= cap: break
    if not consumed or not consumed[-1][0]: return "", 0, 0
    closed = "eos" if len(consumed) == len(row["toks"]) and ended_by_model(row) else ("cap" if count >= cap or len(consumed) == len(row["toks"]) else None)
    text, _, _, _ = gatecore.run_words(consumed, mode, floor, closed=closed, **kw)
    out = measure.clean(before, text)
    if out and gatecore.letters(out) < min_letters: return "", 0, 0
    # the first key of a line reads the whole screen text (prefill 270-480 ms here); live warms it on focus (/prefill),
    # so the reading beyond twice the usual one is taken off the times
    extra = max(0.0, row.get("prefill_ms", 0) - 2 * row.get("_prefill50", 0))
    return out, consumed[decision(consumed)][3] - extra, consumed[-1][3] - extra


def place(before):
    """Where the caret is: "start" (fewer than 2 letters in the field: the app asks nothing), "space" (right after a
    space or line break), "punct" (right after punctuation), "word1" (the first 1-2 letters of a word), "mid" (3+)."""
    if len(before.strip()) < 2: return "start"
    if before[-1].isspace(): return "space"
    m = re.search(r"[\w'’-]+$", before)
    if not m: return "punct"
    return "word1" if len(m.group(0)) <= 2 else "mid"


class Policy:
    def __init__(self, P, th=TH, guess=None, places=None, policy_mode=request_policy.EARLIER, **run):
        """places: {place: bar} a lower gate bar at those caret places (step 2: ghosts from a word's first letters)."""
        self.request_policy = request_policy.build(policy_mode)
        run = dict(self.request_policy.run_kwargs(), **run)
        if guess is None: guess = self.request_policy.guess_bar
        self.P, self.th, self.guess, self.places, self.run, self.info, self.memo, self.why = P, th, guess, places or {}, run, None, {}, None

    def __call__(self, row, before, src):
        self.info, self.why = None, "gate"
        p = self.P.get(row.get("_key"))
        if p is None: return "", 0
        bar = self.th if self.guess is None else min(self.th, self.guess)
        bar = min(bar, self.places.get(place(before), bar))
        if p < bar: return "", 0
        k = row["_key"]
        if k not in self.memo: self.memo[k] = ghost(row, before, **self.run)
        text, first, full = self.memo[k]
        self.why = "short"
        if not text: return "", 0
        self.why = None
        self.info = {"shade": "sure" if p >= self.th else "guess", "first_ms": first, "full_ms": full}
        return text, first


def score(items, rows, pol):
    res, per = measure.replay(items, rows, pol)
    letters = sum(l["letters"] for l in per); keys = sum(l["keys"] for l in per)
    out = {}
    gs = [g for l in per for g in l.get("ghosts", [])]
    # the replay keeps (right in a row, words shown, letters, info) per ghost; kept letters per shade from a second pass
    for shade in ("all", "sure", "guess"):
        sub = [g for g in gs if shade == "all" or (g[3] or {}).get("shade") == shade]
        if not sub and shade != "all": continue
        wrong = sum(1 for g in sub if g[0] == 0)
        firsts = [g[3]["first_ms"] for g in sub if g[3]]; fulls = [g[3]["full_ms"] for g in sub if g[3]]
        out[shade] = {"shown": len(sub), "shown_pct": round(100 * len(sub) / max(1, keys), 1),
                      "row_shown": round(statistics.mean([g[0] for g in sub]), 2) if sub else 0,
                      "row_all": round(sum(g[0] for g in sub) / max(1, keys), 3),
                      "right_pct": round(100 * sum(1 for g in sub if g[0] > 0) / max(1, len(sub)), 1),
                      "wrong_1k": round(1000 * wrong / letters, 1),
                      "grey_1k": round(1000 * sum(g[1] - g[0] for g in sub) / letters, 1),
                      "words_p50": q([g[1] for g in sub], .5), "words_mean": round(statistics.mean([g[1] for g in sub]), 2) if sub else 0,
                      "first_ms": (round(q(firsts, .5)), round(q(firsts, .95))), "full_ms": (round(q(fulls, .5)), round(q(fulls, .95)))}
    out["all"]["kept_1k"] = round(1000 * sum(l["saved"] for l in per) / letters, 1)
    out["all"]["keys"], out["all"]["letters"] = keys, letters
    return out, per


def kept_by_shade(items, rows, pol):
    """Kept letters per 1,000 that came from each shade: the same replay, Tab letters counted by the ghost's shade."""
    got = defaultdict(int); letters = 0
    for i, it in enumerate(items):
        text = it["text"]; letters += len(text)
        pos, g, shade = 1, "", None
        while pos < len(text):
            if not g:
                row = rows.get((i, pos))
                if row is None: pos += 1; continue
                t, _ = pol(row, text[:pos], it["src"])
                t = measure.clean(text[:pos], t)
                if t: g, shade = t, pol.info["shade"]
            if g:
                w = measure.next_word(g)
                if w.strip() and text[pos:].startswith(w):
                    got[shade] += len(w) - 1; pos += len(w); g = g[len(w):]; continue
                if text[pos] == g[0]: g = g[1:]; pos += 1; continue
                g = ""; pos += 1; continue
            pos += 1
    return {k: round(1000 * v / letters, 1) for k, v in got.items()}


# ---- step 2: the app's waits, simulated (the order of events of app/Keys.swift and engine/server.py) ----
# Key gaps: live keygap histograms in data/app.log (app/KeyGapRules.swift), per app kind, drawn per key (uniform
# inside a bucket; a pause = 1.5 s). App time on top of the engine: live "shown ... key Nms engine Mms predicted"
# lines (key - engine). The path at a key (Keys.predict / schedule / ask):
#   predicted: the previous key had a field read (a gap of at least DEBOUNCE + AX after it): asked at the key itself
#   debounced: else DEBOUNCE, a field read (AX), then asked
# The engine stops a running request at the next token when a newer one comes (server.run, stale), so a ghost whose
# time is over the gap to his next key never shows ("late"); with --keep it runs on and shows when the letters typed
# meanwhile are its start (the app's typedSince rule), and the newer ask waits for it.
# Look-ahead (server.look_ahead): after an answer the engine works out, in the rest of the gap, the answer for the
# next letter the model wrote (branch 1 of K; the recordings keep no other alternatives, so this counts only it).
BUCKETS_MS = [(25, 60), (60, 90), (90, 120), (120, 150), (150, 200), (200, 300), (300, 500), (500, 1000), (1500, 1500)]
DEBOUNCE, AX = 35.0, 2.0


def live_numbers(path=ROOT / "data/app.log"):
    """-> ({"ai": [9 bucket counts], "chat": [...]}, [predicted app ms], [debounced app ms]) from the live log."""
    kg = {"ai": [0] * 9, "chat": [0] * 9}; pred, deb = [], []
    for l in Path(path).read_text(errors="ignore").splitlines():
        m = re.search(r" keygap (ai|chat) (.*)", l)
        if m:
            v = [int(x) for x in re.findall(r"\b(?:lt\d+|pause) (\d+)", m.group(2))][:9]
            kg[m.group(1)] = [a + b for a, b in zip(kg[m.group(1)], v)]
            continue
        m = re.search(r" shown \S+ \d+ms engine (\d+)ms.* key (\d+)ms", l)
        if m and " fix " not in l and " ahead" not in l and int(m.group(1)) > 0:
            (pred if " predicted" in l else deb).append(int(m.group(2)) - int(m.group(1)))
    return kg, pred or [13], deb or [54]


def draw_gap(rnd, counts):
    b = rnd.choices(range(9), weights=counts)[0]
    lo, hi = BUCKETS_MS[b]
    return rnd.uniform(lo, hi)


def timed(items, rows, pol, live, seed=1, keep=False, ahead=True, debounce=DEBOUNCE, app_ms=True):
    """One pass with his gaps. -> per-key records and per-ghost records (see waits())."""
    import random
    kg, pred_ms, deb_ms = live
    keys, ghosts, letters, saved, visible_at = [], [], 0, 0, 0
    nkeys = 0
    for i, it in enumerate(items):
        text = it["text"]; letters += len(text)
        rnd = random.Random(seed * 100003 + i)
        kind = "ai" if it["src"] == "claude" else "chat"
        gap = [0.0] + [draw_gap(rnd, kg[kind]) for _ in range(len(text))] + [10 ** 6]   # gap[j]: before key j (0-based)
        tkey = [0.0]
        for j in range(1, len(text) + 1): tkey.append(tkey[-1] + gap[j])
        # key j (1-based) types text[j-1] at tkey[j-1]; then the field holds text[:j]
        G, pos = "", 1
        prev = None        # (pos, done_at, branch letter, branch_ready_at) of the last answered request
        busy_until = -1.0  # keep: the running request's end
        ext_until = -1.0   # cadence round: an extension still running on the GPU (a newer ask waits for its next token)
        pending = None     # keep: (pos asked, text, done_at, shade)
        while pos < len(text):
            t = tkey[pos - 1]; nxt = tkey[pos] if pos < len(text) else 10 ** 9
            nkeys += 1
            if G: visible_at += 1
            if G:
                w = measure.next_word(G)
                if w.strip() and text[pos:].startswith(w):
                    saved += len(w) - 1; pos += len(w); G = G[len(w):]
                    if not G:   # used up by Tabs: the look-ahead "next" answer is ready (rolling ghost)
                        G = ask_now(pol, rows, i, pos, text, ghosts, keys, 13.0, "space" if text[pos - 1:pos].isspace() else "tab", it)
                    continue
                if text[pos] == G[0]: G = G[1:]; pos += 1; continue
                G = ""; pos += 1; continue
            before = text[:pos]
            where = place(before)
            rec = {"place": where, "src": it["src"]}
            keys.append(rec)
            if where == "start": rec["why"] = "guard"; pos += 1; continue
            row = rows.get((i, pos))
            if row is None: rec["why"] = "norow"; pos += 1; continue
            see = getattr(pol, "see", None)   # cadence round: the policy may read the gaps he typed at (causal)
            if see: see(gap[pos - 1] if pos > 1 else None, gap[pos - 2] if pos > 2 else None)
            g, eng = pol(row, before, it["src"])
            g = measure.clean(before, g)
            if not g: rec["why"] = pol.why or "gate"
            # the path and the time to the ghost
            predicted = gap[pos - 1] >= debounce + AX if pos > 1 else False
            app = rnd.choice(pred_ms) if predicted else (debounce + AX + max(0.0, rnd.choice(deb_ms) - DEBOUNCE - AX))
            if not app_ms: app = 0.0
            eng_all = pol.info["first_ms"] if g else (row["toks"][decision(row["toks"])][3] if row["toks"] else 0)
            start = t
            if keep and busy_until > t: start = busy_until
            contend = getattr(pol, "contend", 0.0)
            if contend and ext_until > start: start = start + min(contend, ext_until - start)
            hit = False
            if ahead and prev and prev[0] == pos - 1 and prev[2] and text[pos - 1] == prev[2]:
                ready = prev[3]
                if ready <= t: hit = True; L = 13.0
                elif ready - t < 600: hit = True; L = ready - t + 13.0   # joined: the look-ahead for it is running
            if not hit: L = (start - t) + app + eng_all
            rec.update(L=L, eng=eng_all, app=app, path="ahead" if hit else ("predicted" if predicted else "debounced"))
            done = t + L
            first = L
            opts = getattr(pol, "opts", None)
            if opts:
                # combo: the ghost he sees at his next key is the newest one that came by then (each model's own time)
                last = pos == len(text) - 1
                pick = opts[-1] if hit else next((o for o in reversed(opts) if last or t + (start - t) + app + o[0] < nxt), None)
                if pick is None: pick = opts[0]
                g = measure.clean(before, pick[1]); pol.info = dict(pol.info or {}, shade=pick[2], first_ms=pick[0], src=pick[3])
                if not hit: L = (start - t) + app + pick[0]; first = (start - t) + app + opts[0][0]
                else: first = L
                if contend and not hit and pick is not opts[-1]: ext_until = t + (start - t) + app + opts[-1][0]
                rec.update(L=L, eng=pick[0]); done = t + L
            if g:
                if done < nxt or pos == len(text) - 1:
                    rec["why"] = "shown"; G = g
                    ghosts.append(dict(record(g, text, pos), L=L, first=min(first, L), shade=pol.info["shade"], place=where,
                                       src=(pol.info or {}).get("src")))
                    prev = None
                    continue      # at this very spot: he takes it (Tab) or types on into it
                else:
                    rec["why"] = "late"
                    if keep:
                        busy_until = done
                        # it runs on: shown at the key where it lands when the letters typed meanwhile are its start
                        k = pos
                        while k < len(text) and tkey[k] < done: k += 1
                        typed = text[pos:k]
                        if k < len(text) and g.startswith(typed) and len(g) > len(typed):
                            # the keys in between asked nothing new: they wait for this one
                            for _ in range(pos + 1, k): keys.append({"place": place(text[:_]), "src": it["src"], "why": "waited"})
                            nkeys += max(0, k - pos - 1)
                            G = g[len(typed):]
                            ghosts.append(dict(record(G, text, k), L=done - tkey[k - 1], shade=pol.info["shade"], place=where, kept=True))
                            pos = k; prev = None
                            continue
                    prev = None
            else:
                if done < nxt:
                    raw = measure.clean(before, row["toks"][-1][0]) if row["toks"] and row["toks"][-1][0] else ""
                    letter = raw[:1] if raw[:1].strip() else ""
                    cost = rows.get((i, pos + 1), {}).get("toks", [[0, 0, 0, 60.0]])
                    cost = cost[decision(cost)][3] if cost else 60.0
                    prev = (pos, done, letter, done + cost)
                else: prev = None
            pos += 1
    return keys, ghosts, letters, saved, visible_at, nkeys


def record(g, text, pos):
    ws = re.findall(r"\s*\S+\s?", g); k, at = 0, pos
    for w in ws:
        if text[at:].startswith(w) or (w is ws[-1] and text[at:].startswith(w.rstrip())): k += 1; at += len(w)
        else: break
    return {"row": k, "words": len(ws)}


def ask_now(pol, rows, i, pos, text, ghosts, keys, L, where, it):
    row = rows.get((i, pos))
    if row is None: return ""
    g, _ = pol(row, text[:pos], it["src"])
    g = measure.clean(text[:pos], g)
    if g: ghosts.append(dict(record(g, text, pos), L=L, shade=pol.info["shade"], place="tab"))
    return g


def waits(items, rows, pol, live, seeds=(1, 2, 3), **kw):
    """Means over seeds of: shown %, words in a row (shown / all asked keys), kept /1k, wrong /1k, key-to-ghost p50 /
    p95, ghost on screen at a key %, and per place: keys, shown %, why nothing showed."""
    agg = defaultdict(list); places = defaultdict(lambda: defaultdict(list)); comps = defaultdict(list)
    for sd in seeds:
        keys, ghosts, letters, saved, vis, nk = timed(items, rows, pol, live, seed=sd, **kw)
        asked = [k for k in keys if k["why"] != "guard"]
        fresh = [g for g in ghosts if g.get("place") != "tab"]
        agg["shown"].append(100 * len(fresh) / max(1, len(asked)))
        agg["row_shown"].append(statistics.mean([g["row"] for g in ghosts]) if ghosts else 0)
        agg["row_all"].append(sum(g["row"] for g in ghosts) / max(1, len(asked)))
        agg["kept"].append(1000 * saved / letters)
        agg["wrong"].append(1000 * sum(1 for g in ghosts if g["row"] == 0) / letters)
        agg["grey"].append(1000 * sum(g["words"] - g["row"] for g in ghosts) / letters)
        Ls = [g["L"] for g in fresh]
        agg["p50"].append(q(Ls, .5)); agg["p95"].append(q(Ls, .95))
        if getattr(pol, "firsts", False):   # cadence round: the first grey text (an extension may land later)
            Fs = [g.get("first", g["L"]) for g in fresh]
            agg["first_p50"].append(q(Fs, .5)); agg["first_p95"].append(q(Fs, .95))
        agg["visible"].append(100 * vis / max(1, nk))
        for k in keys:
            places[k["place"]]["n"].append(1); places[k["place"]][k["why"]].append(1)
        for k in keys:
            if "L" in k:
                comps[k["path"]].append(k["L"]); comps["eng"].append(k["eng"]); comps["app_" + k["path"]].append(k["app"])
    out = {k: round(statistics.mean(v), 2) for k, v in agg.items()}
    n = len(seeds)
    out["places"] = {p: {w: round(len(v) / n) for w, v in d.items()} for p, d in places.items()}
    out["paths"] = {p: {"n": round(len(v) / n), "p50": round(q(v, .5)), "p95": round(q(v, .95))} for p, v in comps.items()}
    return out


VARIANTS = {
    "today (sentence, th 0.4)": dict(),
    "words 3-5, floor 0.1": dict(mode="words", min_words=3, max_words=5),
    "words 3-5, always 5": dict(mode="words", min_words=3, max_words=5, floor=0.0),
    "words 2-5, floor 0.1": dict(mode="words", min_words=2, max_words=5),
    "words 1-5, floor 0.1": dict(mode="words", min_words=1, max_words=5),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["length", "waits", "combo"])
    ap.add_argument("recs", nargs="+")
    ap.add_argument("--guess", default="0.35,0.3,0.25,0.2")
    ap.add_argument("--out", default=None)
    ap.add_argument("--only", default=None, help="waits: variant names holding this text")
    request_policy.add_argument(ap, request_policy.EARLIER)
    a = ap.parse_args()
    import score as big
    if a.cmd == "waits": return main_waits(a, big)
    if a.cmd == "combo": return main_combo(a, big)
    table = {}
    for rec in a.recs:
        items, rows, P = big.oof(rec)
        p50 = q([r.get("prefill_ms", 0) for r in rows.values()], .5)
        for r in rows.values(): r["_prefill50"] = p50
        name = Path(rec).stem
        table[name] = {}
        for key, knobs in length_cases(a.policy_mode, a.guess):
            pol = Policy(P, **knobs)
            s, _ = score(items, rows, pol)
            if pol.guess is not None: s["kept_shade"] = kept_by_shade(items, rows, pol)
            table[name][key] = s
            al = s["all"]
            print(f"{name:28s} {key:42s} shown {al['shown_pct']:5.1f}% row {al['row_shown']:.2f}/{al['row_all']:.3f} "
                  f"kept {al['kept_1k']:6.1f} wrong {al['wrong_1k']:5.1f} grey {al['grey_1k']:6.1f} words {al['words_mean']:.2f} "
                  f"first {al['first_ms']} full {al['full_ms']}" + (f" | guess {s.get('guess', {}).get('shown_pct')}% right {s.get('guess', {}).get('right_pct')}% kept {s['kept_shade']}" if pol.guess is not None else ""), flush=True)
    if a.out: Path(a.out).write_text(json.dumps(table, indent=1))


class Combo:
    """Step 3: the fast model's ghost first, the bigger one's a moment later in its place. The models run one after the
    other on the one GPU: the second starts when the first stopped (its gate said no, or its ghost was written).
    rule "extend": the second's ghost replaces the first only when it starts with the first's first word; with no first
    ghost the second's shows. rule "replace": the second's always wins once it comes. rule "fast": the first only."""

    def __init__(self, fast, big, rows_big, rule="extend"):
        self.fast, self.big, self.rows_big, self.rule, self.info, self.why, self.opts = fast, big, rows_big, rule, None, None, None

    def __call__(self, row, before, src):
        self.opts, self.info = [], None
        ga, ea = self.fast(row, before, src); ia = self.fast.info
        a_end = (ia["full_ms"] if ga else (row["toks"][decision(row["toks"])][3] if row["toks"] else 0))
        a_end = max(0.0, a_end - max(0.0, row.get("prefill_ms", 0) - 2 * row.get("_prefill50", 0)))
        if ga: self.opts.append((ia["first_ms"], ga, ia["shade"], "fast"))
        rb = self.rows_big.get(row["_key"])
        if rb is not None and self.rule != "fast":
            gb, eb = self.big(rb, before, src); ib = self.big.info
            if gb:
                wa = measure.next_word(measure.clean(before, ga)).strip() if ga else ""
                ok = (not ga) or self.rule == "replace" or measure.clean(before, gb).startswith(wa)
                if ok: self.opts.append((a_end + ib["full_ms"], gb, ib["shade"], "big"))
        self.why = self.fast.why if not self.opts else None
        if not self.opts: return "", 0
        self.info = {"shade": self.opts[0][2], "first_ms": self.opts[0][0], "full_ms": self.opts[-1][0]}
        return self.opts[0][1], self.opts[0][0]


def main_combo(a, big):
    """Step 3: rec[0] the fast model, rec[1] the big one, the same held set."""
    live = live_numbers()
    fa, fb = a.recs[0], a.recs[1]
    ia, ra, Pa = big.oof(fa); ib, rb, Pb = big.oof(fb)
    assert [x["text"] for x in ia] == [x["text"] for x in ib]
    for rows in (ra, rb):
        p50 = q([r.get("prefill_ms", 0) for r in rows.values()], .5)
        for r in rows.values(): r["_prefill50"] = p50
    current = a.policy_mode == request_policy.CURRENT
    run = ({"policy_mode": a.policy_mode} if current else dict(PICK1, min_letters=3, guess=0.3))
    pa, pb = lambda: Policy(Pa, **run), lambda: Policy(Pb, **run)
    table = {}
    cases = [
        ("big alone, step 1 + min 3", pb(), rb, {}),
        ("big alone, step 1 + min 3 + keep", pb(), rb, {"keep": True}),
        ("fast alone, step 1 + min 3", pa(), ra, {}),
        ("combo extend", Combo(pa(), pb(), rb, "extend"), ra, {}),
        ("combo replace", Combo(pa(), pb(), rb, "replace"), ra, {}),
        ("combo extend + keep", Combo(pa(), pb(), rb, "extend"), ra, {"keep": True}),
        ("combo replace + keep", Combo(pa(), pb(), rb, "replace"), ra, {"keep": True})]
    if current:
        keep = request_policy.build(a.policy_mode).timing_kwargs()
        cases = [(f"{a.policy_mode}: {name}", pol, rows, keep) for name, pol, rows in [
            ("big alone", pb(), rb), ("fast alone", pa(), ra),
            ("combo extend", Combo(pa(), pb(), rb, "extend"), ra),
            ("combo replace", Combo(pa(), pb(), rb, "replace"), ra)]]
    for name, pol, rows, kw in cases:
        s = waits(ia, rows, pol, live, **kw)
        table[name] = s
        print(f"{name:34s} shown {s['shown']:5.1f}% row {s['row_shown']:.2f}/{s['row_all']:.3f} kept {s['kept']:6.1f} "
              f"wrong {s['wrong']:5.1f} grey {s['grey']:6.1f} key-to-ghost {s['p50']:.0f}/{s['p95']:.0f} visible {s['visible']:.1f}%", flush=True)
    if a.out: Path(a.out).write_text(json.dumps(table, indent=1))


PICK1 = dict(mode="words", min_words=3, max_words=5)
WAIT_VARIANTS = [
    ("today (sentence, 0.4, min 5 letters)", dict(), {}, {}),
    ("step 1 (3-5 words, guess 0.3)", dict(PICK1), {"guess": 0.3}, {}),
    ("step 1 + min 3 letters", dict(PICK1, min_letters=3), {"guess": 0.3}, {}),
    ("step 1 + min 2 letters", dict(PICK1, min_letters=2), {"guess": 0.3}, {}),
    ("step 1 + word start 0.25", dict(PICK1), {"guess": 0.3, "places": {"space": 0.25, "word1": 0.25}}, {}),
    ("step 1 + word start 0.2", dict(PICK1), {"guess": 0.3, "places": {"space": 0.2, "word1": 0.2}}, {}),
    ("step 1 + min 3 + word start 0.25", dict(PICK1, min_letters=3), {"guess": 0.3, "places": {"space": 0.25, "word1": 0.25}}, {}),
    ("step 1 + no debounce", dict(PICK1), {"guess": 0.3}, {"debounce": 0.0}),
    ("step 1 + keep in flight", dict(PICK1), {"guess": 0.3}, {"keep": True}),
    ("step 1, no look-ahead", dict(PICK1), {"guess": 0.3}, {"ahead": False}),
    ("step 1 + min 3 + keep in flight", dict(PICK1, min_letters=3), {"guess": 0.3}, {"keep": True}),
    ("step 1 + min 2 + keep in flight", dict(PICK1, min_letters=2), {"guess": 0.3}, {"keep": True}),
    ("step 1, engine 0 ms (ceiling)", dict(PICK1), {"guess": 0.3}, {"zero": True}),
]


def length_cases(mode, guesses):
    if mode == request_policy.CURRENT:
        return [(mode, {"policy_mode": mode})]
    request_policy.build(mode)  # reject unknown modes instead of silently using the historical sweep
    return [(name + ("" if g is None else f" + guess {g}"), dict(run, guess=g))
            for name, run in VARIANTS.items() for g in [None] + [float(x) for x in guesses.split(",") if x]]


def wait_cases(mode):
    policy = request_policy.build(mode)
    if mode == request_policy.CURRENT:
        return [(mode, {}, {"policy_mode": mode}, policy.timing_kwargs())]
    return WAIT_VARIANTS


def main_waits(a, big):
    live = live_numbers()
    print("live gaps:", {k: v for k, v in live[0].items()}, "app ms predicted p50", q(live[1], .5), "debounced p50", q(live[2], .5), flush=True)
    table = {}
    for rec in a.recs:
        items, rows, P = big.oof(rec)
        p50 = q([r.get("prefill_ms", 0) for r in rows.values()], .5)
        for r in rows.values(): r["_prefill50"] = p50
        name = Path(rec).stem; table[name] = {}
        for vname, run, pk, kw in wait_cases(a.policy_mode):
            if a.only and not any(x in vname for x in a.only.split("|")): continue
            kw = dict(kw)
            if kw.pop("zero", False):
                import copy
                rows0 = {k: dict(r, toks=[t[:3] + [0.0] + t[4:] for t in r["toks"]], prefill_ms=0) for k, r in rows.items()}
                s = waits(items, rows0, Policy(P, **pk, **run), (live[0], [0], [DEBOUNCE + AX]), **kw)
            else:
                s = waits(items, rows, Policy(P, **pk, **run), live, **kw)
            table[name][vname] = s
            print(f"{name:24s} {vname:36s} shown {s['shown']:5.1f}% row {s['row_shown']:.2f}/{s['row_all']:.3f} kept {s['kept']:6.1f} "
                  f"wrong {s['wrong']:5.1f} grey {s['grey']:6.1f} key-to-ghost {s['p50']:.0f}/{s['p95']:.0f} visible {s['visible']:.1f}%", flush=True)
    if a.out: Path(a.out).write_text(json.dumps(table, indent=1))


if __name__ == "__main__":
    main()
