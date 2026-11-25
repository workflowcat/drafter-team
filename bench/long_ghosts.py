"""Long ghosts round (2026-11-14, Andrii: "it also gotta suggest more words ... full sentences i could finish quickly").
Judges a ghost by the words he can take in a row (Tab takes one word at a time), not by whole takes. Numbers only:
nothing here prints his text.

    .venv/bin/python -B bench/long_ghosts.py live [--days 7]            where the words stop, from data/app.log
    .venv/bin/python -B bench/long_ghosts.py attrib <recording>         what ended each ghost of today's policy
    .venv/bin/python -B bench/long_ghosts.py runs <recording> [...]      words right in a row when the model runs on
    .venv/bin/python -B bench/long_ghosts.py ends <recording> [...]      the model ends the line within 3 words
    .venv/bin/python -B bench/long_ghosts.py table <recording>          word / phrase / sentence, caps and floors
    .venv/bin/python -B bench/long_ghosts.py futures <recording>        prepared answers with his real key gaps

Recordings come from bench/typebench.py with --tokens 24 (each key: the model's text after the caret, token by
token, with p and ms). The replay is bench/measure.py: a simulated Andrii takes every right word with Tab.
"""
import argparse, json, math, re, statistics, sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import gatecore, measure

END = re.compile(r"[.!?…)\n]")


def q(xs, p):
    return sorted(xs)[min(len(xs) - 1, int(len(xs) * p))] if xs else None


# ---------------------------------------------------------------- live log

SHOWN = re.compile(r"^(\S+) shown (\S+) (\d+)ms engine (\d+)ms(.*)$")
GHOST = re.compile(r"^(\S+) ghost (\S+) (\S+) len (\d+) word (\d+) taken (\d+) typed (\d+)")


def live(a):
    import live_ghosts as lg
    lines = Path(a.log).read_text(errors="replace").splitlines()
    last = max((l[:20] for l in lines if l[:4] == "2026"), default="")
    import datetime as dt
    since = (dt.datetime.strptime(last[:19], "%Y-%m-%dT%H:%M:%S") - dt.timedelta(days=a.days)).strftime("%Y-%m-%dT%H:%M:%S")
    shown, _ = lg.parse(lines, since)
    loc = [s for s in shown if s["len"] is not None and s["src"] not in ("ending",)]
    print(f"live {since[:16]} .. {last[:16]}: local ghosts shown {len(loc)}")
    # words per shown ghost: the log keeps letters only (never the text); a word is ~6.1 characters with its space in
    # his held lines (measured below by `table`), so words ~ len / 6.1, marked as an estimate
    for kind in ("all", "ai", "chat"):
        xs = [s["len"] for s in loc if kind == "all" or s["kind"] == kind]
        if not xs: continue
        words = [max(1, round(x / 6.1)) for x in xs]
        c = Counter(min(w, 5) for w in words)
        n = len(xs)
        print(f"  {kind:4s} n {n:5d} len chars p50 {q(xs, .5)} p90 {q(xs, .9)} | words (est.) p50 {q(words, .5)} p90 {q(words, .9)} | "
              f"1 word {100 * c[1] / n:.0f}% 2 {100 * c[2] / n:.0f}% 3-4 {100 * (c[3] + c[4]) / n:.0f}% 5+ {100 * c[5] / n:.0f}%")
    ended = [s for s in loc if s["ended"]]
    taken = [s for s in ended if s["taken"]]
    if taken:
        share = [s["taken"] / max(1, s["glen"]) for s in taken]
        print(f"  ghosts with a Tab: {len(taken)} ({100 * len(taken) / len(loc):.1f}% of shown); letters taken per such ghost p50 "
              f"{q([s['taken'] for s in taken], .5)} p90 {q([s['taken'] for s in taken], .9)}; share of the ghost taken p50 "
              f"{100 * q(share, .5):.0f}% p90 {100 * q(share, .9):.0f}%")


# ---------------------------------------------------------------- policies on recordings

def ended_by_model(row):
    """The recording ended before its token cap and not at a line break: the model wrote its end of text."""
    words_toks = [t for t in row["toks"] if t[0]]
    if not words_toks: return False
    return len(words_toks) < row.get("max_tokens", 24) and "\n" not in words_toks[-1][0]


def decision(consumed):
    """Index of the token at which the gate decides (the first word is whole)."""
    for j, t in enumerate(consumed):
        if t[0] and (gatecore.word_done(t[0]) or END.search(t[0])): return j
    return len(consumed) - 1


class ModelPolicy:
    """The engine's model path (server._complete gated + model.complete_gated) for one length mode.
    mode "word": today's rule (sure words, grow to 5 letters, the lighter tail 0.3 up to 8 words, cap 18 tokens).
    mode "phrase" / "sentence": gatecore.run_words after the gate, up to `cap` tokens, `floor`.
    self.info: the last ghost's {why, first_ms, full_ms, src} (why: what ended it)."""

    def __init__(self, W, gate, mode="word", cap=24, floor=gatecore.RUN_FLOOR, min_letters=5, likely=gatecore.RUN_LIKELY, kind="prod", garbage=gatecore.RUN_GARBAGE):
        import lengths
        self.W, self.gate, self.mode, self.cap, self.floor, self.min_letters, self.likely = W, gate, mode, cap, floor, min_letters, likely
        self.kind, self.garbage = kind, garbage
        self.word = lengths.policy(W, None, dict(gate, th={"ai": 0.0, "chat": 0.0}), min_letters=min_letters, grow=0.05,
                                   tail=0.3, tail_words=8, settle=True) if mode == "word" else None
        self.info = None

    def __call__(self, row, before, src):
        self.info = None
        if self.mode == "word": return self._word(row, before, src)
        consumed, count, decided = [], 0, False
        for tok in row["toks"]:
            consumed.append(tok)
            if not tok[0]: continue
            count += 1
            if not decided and (gatecore.word_done(tok[0]) or END.search(tok[0])): decided = True
            if decided:
                _, _, why, _ = gatecore.run_words(consumed, self.mode, self.floor, likely=self.likely, min_letters=self.min_letters, kind=self.kind, garbage=self.garbage)
                if gatecore.run_settled(why): break
            if count >= self.cap: break
        if not consumed or not consumed[-1][0]: return "", 0
        closed = None
        if consumed is not None and len(consumed) == len(row["toks"]) and ended_by_model(row): closed = "eos"
        elif count >= self.cap or len(consumed) == len(row["toks"]): closed = "cap"
        text, sure, why, confs = gatecore.run_words(consumed, self.mode, self.floor, closed=closed, likely=self.likely, min_letters=self.min_letters, kind=self.kind, garbage=self.garbage)
        out = measure.clean(before, text)
        if why == "floor" and out and len(out.split()) == 1: why = "floor"
        if out != text.lstrip(" ") and out != text and text.strip() and out.strip() != text.strip(): why = "clean"
        if out and gatecore.letters(out) < self.min_letters: return "", 0
        d = decision(consumed)
        self.info = {"why": why, "first_ms": consumed[d][3], "full_ms": consumed[-1][3], "src": "model",
                     "sure": len(out) - (len(text) - sure) if sure <= len(text) else len(out), "confs": confs}
        return out, consumed[-1][3]

    def _word(self, row, before, src):
        out, ms = self.word(row, before, src)
        if not out: return "", ms
        # what ended it: look at the model's text after the ghost
        toks = row["toks"]
        raw = toks[-1][0]
        limit = 18
        nonempty = [t for t in toks if t[0]]
        lead = len(raw) - len(raw.lstrip(" "))
        start = raw.find(out.strip()[:max(1, min(len(out.strip()), 8))])
        pos = (start if start >= 0 else lead) + len(out.strip())
        rest = raw[pos:]
        d = decision(toks)
        full = nonempty[min(len(nonempty), limit) - 1][3] if nonempty else 0
        if END.search(out.rstrip()[-1:] or ""): why = "sentence" if out.rstrip()[-1:] != ")" else "clause"
        elif not rest.strip():
            if "\n" in rest: why = "line"
            elif len(nonempty) <= limit and ended_by_model(row): why = "end"
            else: why = "cap"
        elif rest.lstrip(" ").startswith("\n"): why = "line"
        elif len(out.split()) >= 8: why = "words"
        else:
            m = re.match(r"\s*\S+ ?", rest)
            end_tok = sum(1 for t in nonempty if len(t[0]) <= pos + len(m.group(0).rstrip()))
            if end_tok >= limit and not END_RE_word(m.group(0)): why = "cap"
            else:
                ps = gatecore.word_ps(toks, pos, pos + len(m.group(0).rstrip()))
                why = "tail bar" if ps and min(ps) < 0.3 else "other"
        self.info = {"why": why, "first_ms": toks[d][3], "full_ms": ms, "src": "model"}
        return out, ms


def END_RE_word(w):
    return bool(gatecore.END_RE.search(w))


class Live:
    """The engine's order with the selector (bench/settle.live): phrase memory and his word first when they clear the
    bar, else the model's ghost when its first word clears it; the model path is `model` (a ModelPolicy)."""

    def __init__(self, W, M, gate, sel, model):
        import selector as S
        self.src = S.Sources(W, M, gate, sel["wordgate"], {"min_letters": 5, "grow": 0.05, "tail": 0.3, "tail_words": 8, "settle": True})
        self.src.model = model
        self.sel = S.Selector(self.src, sel["w"], sel["th"])
        self.model, self.info, self.text = model, None, ""

    def __call__(self, row, before, src):
        self.model.info = None
        g, ms = self.sel(row, before, src)
        info = self.model.info if g and self.model.info is not None and ms == self.model.info.get("full_ms") else None
        self.info = info or ({"why": "selector", "first_ms": ms, "full_ms": ms, "src": "selector"} if g else None)
        return g, ms


def setup(path):
    import lengths, ngram, typescore as ts, words, memory as mem
    from retrain_state import last_retrain
    items, rows = ts.load(path)
    cut = last_retrain(ROOT)
    W = ngram.Words(ngram.corpus_from(cut, words.Words.SOURCES))
    M = lengths.memory_from(ngram.corpus_from(cut, mem.Memory.SOURCES))
    gate = json.loads((ROOT / "data/gate.json").read_text()); sel = json.loads((ROOT / "data/selector.json").read_text())
    return items, rows, W, M, gate, sel


def ghosts_of(per, key=None):
    return [g for l in per if key is None or l["src"] == key or f"{l['src']}/{l['lang']}" == key for g in l.get("ghosts", [])]


def attrib(a):
    items, rows, W, M, gate, sel = setup(a.path)
    pol = Live(W, M, gate, sel, ModelPolicy(W, gate, "word"))
    res, per = measure.replay(items, rows, pol)
    for key in ["claude", "beeper", None]:
        gs = ghosts_of(per, key)
        if not gs: continue
        c = Counter(g[3]["why"] if g[3] else "?" for g in gs)
        n = len(gs)
        print(f"{key or 'all':7s} ghosts {n}: " + " · ".join(f"{k} {v} ({100 * v / n:.0f}%)" for k, v in c.most_common()))
        words = [g[1] for g in gs]
        cw = Counter(min(w, 5) for w in words)
        print(f"         words shown p50 {q(words, .5)} p90 {q(words, .9)} · 1 word {100 * cw[1] / n:.0f}% 2 {100 * cw[2] / n:.0f}% "
              f"3-4 {100 * (cw[3] + cw[4]) / n:.0f}% 5+ {100 * cw[5] / n:.0f}%")


def runs(a):
    """At keys where the gate says yes to the model's first word, let the model run its 24 tokens with no bar after it:
    how many words from the start are his, in a row. By app kind and language."""
    import typescore as ts
    for path in a.paths:
        items, rows = ts.load(path)
        gate = json.loads((ROOT / "data/gate.json").read_text())
        out = defaultdict(list)
        for (i, pos), row in rows.items():
            it = items[i]; text = it["text"]; before = text[:pos]
            if not row["toks"] or not row["toks"][-1][0]: continue
            d = decision(row["toks"])
            f, _ = gatecore.features(row["toks"][: d + 1], before, it["src"] == "claude", "")
            if not f or gatecore.score(gate["w"], f) < gate["th"]["ai" if it["src"] == "claude" else "chat"]: continue
            raw = measure.clean(before, row["toks"][-1][0])
            ws = re.findall(r"\s*\S+ ?", raw.split("\n")[0])
            # the last word counts only when something follows it (or the model ended there)
            if ws and not ws[-1].endswith(" ") and not ended_by_model(row) and len(raw.split("\n")) == 1: ws = ws[:-1]
            k, at = 0, pos
            for w in ws:
                if text[at:].startswith(w) or (w is ws[-1] and text[at:].startswith(w.rstrip()) and at + len(w.rstrip()) == len(text)): k += 1; at += len(w)
                else: break
            for key in (it["src"], f"{it['src']}/{measure.lang(text)}", "all"): out[key].append((k, len(ws)))
        print(Path(path).stem)
        for key in sorted(out):
            ks = [k for k, _ in out[key]]; right = [k for k in ks if k >= 1]
            print(f"  {key:10s} gated keys {len(ks):5d} words right in a row p50 {q(ks, .5)} p90 {q(ks, .9)} mean {statistics.mean(ks):.2f} | "
                  f"first word right {len(right)}: p50 {q(right, .5)} p90 {q(right, .9)} mean {statistics.mean(right) if right else 0:.2f} | "
                  f"3+ {100 * sum(k >= 3 for k in ks) / len(ks):.0f}% 5+ {100 * sum(k >= 5 for k in ks) / len(ks):.0f}% | words written p50 {q([n for _, n in out[key]], .5)}")


def ends(a):
    """How often the model ends the line (end of text or a line break) within its first 3 words, at every key."""
    import typescore as ts
    same = None
    if getattr(a, "same", False):       # only the keys every recording has (the same lines and spots)
        for path in a.paths:
            ks = set(ts.load(path)[1]); same = ks if same is None else same & ks
    for path in a.paths:
        items, rows = ts.load(path)
        if same is not None: rows = {k: v for k, v in rows.items() if k in same}
        out = defaultdict(lambda: [0, 0, 0, [], 0, 0])
        for (i, pos), row in rows.items():
            it = items[i]
            toks = [t for t in row["toks"] if t[0]]
            if not toks: continue
            raw = toks[-1][0]
            line = raw.split("\n")[0]
            ended = "\n" in raw or ended_by_model(row)
            nw = len(line.split())
            left = len(it["text"][pos:].split("\n")[0].split())      # his words still to come on this line
            for key in (it["src"], f"{it['src']}/{measure.lang(it['text'])}", "all"):
                o = out[key]; o[0] += 1; o[1] += ended and nw <= 3; o[2] += ended; o[3].append(nw if ended else 99)
                if left >= 5: o[4] += 1; o[5] += ended and nw <= 3      # too early: he wrote 5+ more words
        print(Path(path).stem, json.loads(Path(path).with_suffix(".meta.json").read_text()).get("adapter"))
        for key in sorted(out):
            n, e3, e, nws, n5, e5 = out[key]
            print(f"  {key:10s} keys {n:5d} ends within 3 words {100 * e3 / n:5.1f}% · ends within 24 tokens {100 * e / n:5.1f}% · "
                  f"where he wrote 5+ more words: {n5} keys, ended within 3 words {100 * e5 / max(1, n5):5.1f}%")


def table(a):
    items, rows, W, M, gate, sel = setup(a.path)
    configs = [("word (today)", dict(mode="word"))]
    for mode in ("phrase", "sentence"):
        configs.append((f"{mode} cap 24 floor {gatecore.RUN_FLOOR}", dict(mode=mode)))
    for cap in (12, 18):
        configs.append((f"sentence cap {cap} floor {gatecore.RUN_FLOOR}", dict(mode="sentence", cap=cap)))
    for fl in (0.01, 0.02, 0.1, 0.2):
        configs.append((f"sentence cap 24 floor {fl}", dict(mode="sentence", floor=fl)))
    if a.grid:
        configs = [("word (today)", dict(mode="word"))]
        for fl in (0.3, 0.4, 0.5, 0.6): configs.append((f"sentence mean {fl}", dict(mode="sentence", kind="mean", floor=fl)))
        for g in (0.02, 0.05, 0.1): configs.append((f"sentence garbage-only {g}", dict(mode="sentence", kind="prod", floor=0.0, garbage=g)))
    if a.only: configs = [c for c in configs if a.only in c[0]]
    base = None
    print("cfg | app | saved/1k letters | words taken per ghost mean p90 | 3+ in a row | wrong grey words/1k | first word ms p50 p90 | full ghost ms p50 p90 | right% | shown | sure-part words right / lighter words right")
    rows_out = []
    for name, kw in configs:
        pol = Live(W, M, gate, sel, ModelPolicy(W, gate, **kw))
        res, per = measure.replay(items, rows, pol)
        if base is None: base = per
        for key in ("claude", "beeper", "claude/en", "claude/uk", "beeper/uk", "beeper/en"):
            if key not in res: continue
            gs = ghosts_of(per, key)
            letters = res[key]["letters"]
            ks = [g[0] for g in gs]
            bad = sum(g[1] - g[0] for g in gs)
            fm = [g[3]["first_ms"] for g in gs if g[3] and g[3]["src"] == "model"]
            fu = [g[3]["full_ms"] for g in gs if g[3] and g[3]["src"] == "model"]
            ci = measure.paired(base, per, key, "saved") if per is not base else (0, 0)
            line = (f"{name:30s} {key:10s} {10 * res[key]['saved']:5.0f} ({ci[0]*10:+.0f}..{ci[1]*10:+.0f}) | {statistics.mean(ks) if ks else 0:.2f} {q(ks, .9)} | "
                    f"{100 * sum(k >= 3 for k in ks) / max(1, len(ks)):4.1f}% | {1000 * bad / max(1, letters):5.1f} | "
                    f"{q(fm, .5)} {q(fm, .9)} | {q(fu, .5)} {q(fu, .9)} | {res[key]['right']} | {res[key]['shown']}")
            ns = [g[1] for g in gs]
            line += f" | words shown p50 {q(ns, .5)} p90 {q(ns, .9)} 5+ {100 * sum(n >= 5 for n in ns) / max(1, len(ns)):.0f}%"
            print(line, flush=True)
            rows_out.append({"cfg": name, "key": key, "saved_1k": 10 * res[key]["saved"], "ci": ci, "taken_mean": statistics.mean(ks) if ks else 0,
                             "taken_p90": q(ks, .9), "three": 100 * sum(k >= 3 for k in ks) / max(1, len(ks)), "bad_1k": 1000 * bad / max(1, letters),
                             "first": (q(fm, .5), q(fm, .9)), "full": (q(fu, .5), q(fu, .9)), "right": res[key]["right"], "shown": res[key]["shown"],
                             "words_p50": q([g[1] for g in gs], .5), "words_p90": q([g[1] for g in gs], .9)})
        whys = Counter(g[3]["why"] for g in ghosts_of(per) if g[3])
        print(f"{'':30s} ended by: " + " · ".join(f"{k} {v}" for k, v in whys.most_common()))
    if a.out: Path(a.out).write_text(json.dumps(rows_out, indent=1))


def likely(a):
    """Is the sure part (running chance >= likely) right more often than the lighter tail? Per later word shown."""
    items, rows, W, M, gate, sel = setup(a.path)
    for lk in (0.2, 0.3, 0.5):
        pol = ModelPolicy(W, gate, "sentence", likely=lk)
        stats = {"sure": [0, 0], "light": [0, 0]}
        for (i, pos), row in rows.items():
            text = items[i]["text"]; before = text[:pos]
            g, _ = pol(row, before, items[i]["src"])
            if not g or not pol.info: continue
            sure = pol.info["sure"]
            ws = re.findall(r"\s*\S+ ?", g); at, cut, ok = pos, 0, True
            for w in ws:
                cut += len(w)
                part = "sure" if cut <= sure + 1 else "light"
                good = ok and (text[at:].startswith(w) or text[at:].startswith(w.rstrip()))
                stats[part][0] += 1; stats[part][1] += good
                ok = good; at += len(w)
        print(f"likely {lk}: " + " · ".join(f"{k} words {v[0]}, right in a row {100 * v[1] / max(1, v[0]):.0f}%" for k, v in stats.items()))


# ---------------------------------------------------------------- futures with his key gaps

class Futures:
    """Replay wrapper: the live answer at each ask, with its time taken from what the engine prepared in the gaps.

    After an answer shows (at `lat` ms after the key), the engine works through, one after the other: the look-ahead
    for the whole ghost ("next"), then K futures for other first letters (bench/branches.py letters_next: the model's own
    next letter first, then his likely words), each costing a fresh run of this key (`depth` "full": to the end of
    the ghost, "word": to its first word). The next ask comes after his real key gaps (one per key between the two asks:
    letters typed and Tabs). It is answered at 0 ms when its text was prepared by then. `join` (the long-round fix):
    work for exactly that text still running at the key is waited for (up to 600 ms) instead of being stopped and done
    again. Before the fix (`join` False) such work was stopped at the key."""

    def __init__(self, pol, coster, W, gaps, k=2, join=True, depth="full", seed=7):
        import random
        self.pol, self.coster, self.W, self.gaps, self.k, self.join, self.depth = pol, coster, W, gaps, k, join, depth
        self.rng = random.Random(seed)
        self.items, self.prev, self.info = [], None, None
        self.n = Counter()

    def __setattr__(self, k, v):
        if k == "text" and hasattr(self.__dict__.get("pol"), "text"): self.pol.text = v
        object.__setattr__(self, k, v)

    def gap(self, src):
        g = self.gaps.get("ai" if src == "claude" else "chat") or self.gaps["all"]
        return self.rng.choice(g)

    def cost(self, row, before, src):
        """(ms, tokens) of one prepared answer like this key's."""
        g, ms = self.coster(row, before, src)
        info = self.coster.info
        toks = [t for t in row["toks"] if t[0]]
        if not toks: return 0.0, 0
        if self.depth == "word" or not g or not info:
            ms = row["toks"][decision(row["toks"])][3] if info is None else info["first_ms"]
        return ms, sum(1 for t in toks if t[3] <= ms)

    def __call__(self, row, before, src):
        import branches
        g, ms = self.pol(row, before, src)
        self.info = getattr(self.pol, "info", None)
        c_ms, c_tok = self.cost(row, before, src)
        lat, how = (ms if g else c_ms), "fresh"
        if self.prev is not None:
            old, og = self.prev
            if before.startswith(old) and before != old:
                typed = before[len(old):]
                common = 0
                while common < min(len(og), len(typed)) and og[common] == typed[common]: common += 1
                keys = max(1, len(re.findall(r"\S+", og[:common])) + len(typed) - common)
            else:
                keys = 1
            E = sum(self.gap(src) for _ in range(keys))
            for key, start, fin, tok, kind in self.items:
                done = fin <= E
                if key == before and done: lat, how = 0.0, "hit"
                elif key == before and self.join and start < E and fin - E <= 600: lat, how = fin - E, "join"
                spent = tok if done or (key == before and how == "join") else (0 if start >= E else tok * (E - start) / max(1e-9, fin - start))
                self.n["tok_work"] += spent
                if key != before or how == "fresh": self.n["tok_waste"] += spent
        self.n[how] += 1; self.n["asks"] += 1
        if how == "fresh": self.n["tok_answer"] += c_tok
        self.n["lat_sum"] += lat
        # what this gap prepares: the look-ahead for the whole ghost, then the futures
        t, items = lat, []
        if g:
            items.append((before + g, t, t + c_ms, c_tok, "next")); t += c_ms
        for ch in branches.letters_next(row, before, self.W, self.k + 1):
            if len([i for i in items if i[4] == "future"]) >= self.k: break
            if g and g.startswith(ch): continue
            items.append((before + ch, t, t + c_ms, c_tok, "future")); t += c_ms
        self.items, self.prev = items, (before, g)
        return g, (1 if how == "hit" else max(1, lat))


def futures_bench(a):
    sys.path.insert(0, str(ROOT / "bench/models")); import twotier
    items, rows, W, M, gate, sel = setup(a.path)
    lines = Path(a.log).read_text(errors="replace").splitlines()
    gaps = {k: twotier.parse_gaps(lines, None if k == "all" else k)[0] for k in ("all", "ai", "chat")}
    print(f"key gaps from app.log: {len(gaps['all'])} (ai {len(gaps['ai'])}, chat {len(gaps['chat'])}); deciles all "
          f"{[round(x) for x in twotier.deciles(gaps['all'])]}")
    letters = sum(len(it["text"]) for it in items)
    cfgs = [("round five as live: 2 futures, word ghosts, no join", "word", 2, False, "full")]
    for k in range(0, 5):
        cfgs.append((f"sentence, K {k}, join", "sentence", k, True, "full"))
    cfgs.append(("sentence, K 2, no join", "sentence", 2, False, "full"))
    cfgs.append(("sentence, K 4, futures to the first word only", "sentence", 4, True, "word"))
    print("cfg | asks | answered at 0 ms | joined | fresh | mean ms to the answer | tokens of prepared work per ask | of it unused | model tokens per letter of text | saved/1k")
    for name, mode, k, join, depth in cfgs:
        model = ModelPolicy(W, gate, mode)
        coster = ModelPolicy(W, dict(gate, th={"ai": 0.0, "chat": 0.0}), mode)
        f = Futures(Live(W, M, gate, sel, model), coster, W, gaps, k=k, join=join, depth=depth)
        res, per = measure.replay(items, rows, f)
        n = f.n; A = max(1, n["asks"])
        tok_all = n["tok_work"] + n["tok_answer"]
        saved = 100 * sum(r["saved"] for r in per) / max(1, sum(r["letters"] for r in per))
        print(f"{name:48s} | {A} | {100 * n['hit'] / A:4.1f}% | {100 * n['join'] / A:4.1f}% | {100 * n['fresh'] / A:4.1f}% | "
              f"{n['lat_sum'] / A:5.0f} | {n['tok_work'] / A:5.1f} | {n['tok_waste'] / A:5.1f} | {tok_all / max(1, letters):4.2f} | {10 * saved:.0f}", flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("live"); p.add_argument("--days", type=int, default=7); p.add_argument("--log", default=str(ROOT / "data/app.log"))
    p = sub.add_parser("attrib"); p.add_argument("path")
    p = sub.add_parser("runs"); p.add_argument("paths", nargs="+")
    p = sub.add_parser("ends"); p.add_argument("paths", nargs="+"); p.add_argument("--same", action="store_true")
    p = sub.add_parser("table"); p.add_argument("path"); p.add_argument("--only", default=None); p.add_argument("--out", default=None); p.add_argument("--grid", action="store_true")
    p = sub.add_parser("likely"); p.add_argument("path")
    p = sub.add_parser("futures"); p.add_argument("path"); p.add_argument("--log", default=str(ROOT / "data/app.log"))
    a = ap.parse_args()
    {"live": live, "attrib": attrib, "runs": runs, "ends": ends, "table": table, "likely": likely, "futures": futures_bench}[a.cmd](a)
