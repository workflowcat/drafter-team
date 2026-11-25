"""The one replay (round four, 2026-11-14; the Codex design review's "measurement contract"). Every typing bench scores
through `replay()`: bench/typescore.py and bench/lengths.py keep their own printouts on top of it.

A simulated Andrii types each held-out line key by key. When no grey text is up, the policy is asked at that key; what
it returns is shown (a new ghost). While he types the same letters the ghost stays (type-through, costs nothing, not
a new ghost); Tab takes the next grey word when it is exactly his; anything else drops it.

Measured, per app (claude = AI apps, beeper = chats) and per language (uk / en by the line's letters):
  keys       key spots where a new ghost could be asked (no ghost up)
  shown      new ghosts;  coverage = shown / keys
  right      first word exactly his at first display, with a word-boundary check: a ghost word "plan" is wrong when
             he wrote "planning" (the ghost's word must end where his word ends)
  wrong/1k   wrong first words per 1,000 typed letters
  saved      net letters saved: letters Tab put in minus one key per Tab, share of all letters (the old `saved`)
  taken      new ghosts he took at least one word of (typescore's old `right%`)
  new ms     engine time for a new ghost (p50 / p90 / p99); type-through updates are not in it
  late       new ghosts that would come after his next key at `gap_ms` between keys (then not shown at that key)

Confidence: 95% intervals by resampling whole lines (bootstrap), since the spots of one line are not independent.
Dates: `split()` cuts held lines into calibration and test by the date he sent them (data/typed.jsonl), after
grouping versions of one message (a line and the same line longer or shorter, a dictated and a typed copy).
"""
import json, random, re, statistics, sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
from gatecore import next_word
WORDCH = re.compile(r"[\w'’-]")
CYR = re.compile(r"[А-Яа-яІіЇїЄєҐґ]")
LAT = re.compile(r"[A-Za-z]")


def lang(text):
    return "uk" if len(CYR.findall(text)) > len(LAT.findall(text)) else "en"


def first_right(ghost, truth):
    """The ghost's first word is exactly his, the word boundary included."""
    w = next_word(ghost)
    if not w.strip() or not truth.startswith(w.rstrip()): return False
    end = len(w.rstrip())
    if w.rstrip()[-1:] and WORDCH.match(w.rstrip()[-1]) and end < len(truth) and WORDCH.match(truth[end]): return False
    return True


def replay(items, rows, policy, gap_ms=None, tab_cost=1, only=None):
    """-> {key: stats} for key in ("claude", "beeper", "claude/en", ...), plus per-line records for intervals."""
    per = []
    for i, it in enumerate(items):
        if only and it["src"] != only: continue
        text = it["text"]
        s = {"src": it["src"], "lang": lang(text), "letters": len(text), "keys": 0, "shown": 0, "right": 0, "saved": 0,
             "saved5": 0, "tabs": 0, "taken": 0, "late": 0, "ms": [], "by": defaultdict(lambda: [0, 0, 0]),
             "run": defaultdict(lambda: [0, 0, 0, 0, 0])}
        pos, ghost, took, big = 1, "", False, False
        if hasattr(policy, "text"): policy.text = text
        while pos < len(text):
            if not ghost:
                row = rows.get((i, pos))
                if row is None: pos += 1; continue
                s["keys"] += 1
                g, ms = policy(row, text[:pos], it["src"])
                g = clean(text[:pos], g)
                if g and gap_ms is not None and ms > gap_ms:      # came after his next key: not shown here
                    s["late"] += 1; g = ""
                if g:
                    ghost, took = g, False
                    n = letters(g); big = n >= 5
                    s["shown"] += 1; s["ms"].append(ms)
                    ok = first_right(g, text[pos:])
                    s["right"] += ok
                    b = s["by"][bucket(n)]; b[0] += 1; b[1] += ok; b[2] += text[pos:].startswith(g.rstrip())
                    # words of the ghost right in a row from its start: what Tab, Tab, Tab takes before a wrong word
                    ws = re.findall(r"\s*\S+\s?", g); k, at = 0, pos
                    for w in ws:
                        if text[at:].startswith(w) or (w is ws[-1] and text[at:].startswith(w.rstrip())): k += 1; at += len(w)
                        else: break
                    rb = s["run"][bucket(n)]; rb[0] += 1; rb[1] += len(ws); rb[2] += k >= 2; rb[3] += k >= 3; rb[4] += len(ws) - k
                    # long round: each ghost's words right in a row and words shown, with what the policy says of it
                    s.setdefault("ghosts", []).append((k, len(ws), n, getattr(policy, "info", None)))
            if ghost:
                w = next_word(ghost)
                if w.strip() and text[pos:].startswith(w):
                    s["saved"] += len(w) - tab_cost; s["saved5"] += (len(w) - tab_cost) if big else 0; s["tabs"] += 1
                    if not took: s["taken"] += 1; took = True
                    pos += len(w); ghost = ghost[len(w):]
                    continue
                if text[pos] == ghost[0]:
                    ghost = ghost[1:]; pos += 1; continue
                ghost = ""; pos += 1
                continue
            pos += 1
        per.append(s)
    return summarise(per), per


BUCKETS = ((0, 5, "<5"), (5, 10, "5-9"), (10, 15, "10-14"), (15, 20, "15-19"), (20, 10**6, "20+"))


def bucket(n):
    return next(b for lo, hi, b in BUCKETS if lo <= n < hi)


def letters(s):
    return sum(1 for c in s if not c.isspace())


def q(xs, p):
    return sorted(xs)[min(len(xs) - 1, int(len(xs) * p))] if xs else 0


def total(lines):
    t = {k: sum(l[k] for l in lines) for k in ("letters", "keys", "shown", "right", "saved", "saved5", "tabs", "taken", "late")}
    ms = [m for l in lines for m in l["ms"]]
    by, run = defaultdict(lambda: [0, 0, 0]), defaultdict(lambda: [0, 0, 0, 0, 0])
    for l in lines:
        for b, v in l["by"].items():
            for j in range(3): by[b][j] += v[j]
        for b, v in l["run"].items():
            for j in range(5): run[b][j] += v[j]
    order = lambda d: {b: tuple(v) for b, v in sorted(d.items(), key=lambda x: [b for *_, b in BUCKETS].index(x[0]))}
    return {
        "lines": len(lines), "letters": t["letters"], "keys": t["keys"], "shown": t["shown"],
        "coverage": round(100 * t["shown"] / max(1, t["keys"]), 1),
        "right": round(100 * t["right"] / max(1, t["shown"]), 1), "wrong": t["shown"] - t["right"],
        "wrong_1k": round(1000 * (t["shown"] - t["right"]) / max(1, t["letters"]), 1),
        "saved": round(100 * t["saved"] / max(1, t["letters"]), 1), "saved5": round(100 * t["saved5"] / max(1, t["letters"]), 1),
        "taken": round(100 * t["taken"] / max(1, t["shown"]), 1), "tabs": t["tabs"], "late": t["late"],
        "ms_p50": round(statistics.median(ms)) if ms else 0, "ms_p90": round(q(ms, .9)), "ms_p99": round(q(ms, .99)),
        "by": order(by), "run": order(run),
    }


def summarise(per):
    out = {}
    for key in {l["src"] for l in per} | {f"{l['src']}/{l['lang']}" for l in per}:
        out[key] = total([l for l in per if l["src"] == key or f"{l['src']}/{l['lang']}" == key])
    return out


def interval(per, key, metric, n=1000, seed=7):
    """95% interval of a metric for `key` by resampling whole lines."""
    lines = [l for l in per if l["src"] == key or f"{l['src']}/{l['lang']}" == key]
    if not lines: return (0, 0)
    rnd, vals = random.Random(seed), []
    for _ in range(n):
        vals.append(total([lines[rnd.randrange(len(lines))] for _ in lines])[metric])
    vals.sort()
    return vals[int(.025 * n)], vals[int(.975 * n)]


def paired(per_a, per_b, key, metric, n=1000, seed=7):
    """95% interval of (b - a) for the same lines, resampled together."""
    a = [l for l in per_a if l["src"] == key or f"{l['src']}/{l['lang']}" == key]
    b = [l for l in per_b if l["src"] == key or f"{l['src']}/{l['lang']}" == key]
    if not a or len(a) != len(b): return (0, 0)
    rnd, vals = random.Random(seed), []
    for _ in range(n):
        idx = [rnd.randrange(len(a)) for _ in a]
        vals.append(total([b[j] for j in idx])[metric] - total([a[j] for j in idx])[metric])
    vals.sort()
    return round(vals[int(.025 * n)], 1), round(vals[int(.975 * n)], 1)


def clean(before, text):
    """engine/server.py clean() and the app's 'never two spaces' (bench/typescore.py had this)."""
    if not text.strip(): return ""
    text = re.sub(r"[ \t]{2,}", " ", text)
    if before.endswith((" ", "\n")): text = text.lstrip(" ")
    text = re.split(r"###|\[", text)[0].rstrip("\n")
    last = before.splitlines()[-1] if before.splitlines() else ""
    m = re.search(r"\d{3,}", text)
    if m and not re.search(r"\d", last): text = text[: m.start()].rstrip()
    if len(text.strip()) >= 4 and text.strip() in last: return ""
    if before[-1:].isspace(): text = text.lstrip(" ")
    return text


def norm(t):
    return re.sub(r"\s+", " ", t or "").strip().casefold()


def groups(texts):
    """Versions of one message share a group: the same text, or one a start of the other (40+ letters)."""
    gid, heads = {}, {}
    for t in texts:
        k = norm(t)
        h = k[:40] if len(k) >= 40 else k
        gid[t] = heads.setdefault(h, len(heads))
    return gid


def dates(items, typed_path=None):
    """When he sent each held line (data/typed.jsonl `t`), else 0; versions of one message take the earliest."""
    typed_path = Path(typed_path or ROOT / "data/typed.jsonl")
    sent = {}
    try:
        for l in typed_path.read_text().splitlines():
            if l.strip():
                r = json.loads(l); k = norm(r.get("text"))[:40]
                if k and (k not in sent or r.get("t", 0) < sent[k]): sent[k] = r.get("t", 0)
    except FileNotFoundError:
        pass
    g = groups([it["text"] for it in items])
    first = {}
    for it in items:
        t = sent.get(norm(it["text"])[:40], 0)
        if t: first[g[it["text"]]] = min(first.get(g[it["text"]], t), t)
    return [first.get(g[it["text"]], 0) for it in items], [g[it["text"]] for it in items]


def split(items, share=0.5, typed_path=None):
    """-> (calibration indices, test indices): the earlier `share` of message groups by date, then the later ones.
    Undated lines (Beeper replies) go by their order in the set, which make_fresh writes oldest first."""
    when, gid = dates(items, typed_path)
    order = sorted(range(len(items)), key=lambda i: (when[i] or 0, i))
    by_group = []
    for i in order:
        if gid[i] not in by_group: by_group.append(gid[i])
    cut = set(by_group[: int(len(by_group) * share)])
    return [i for i in range(len(items)) if gid[i] in cut], [i for i in range(len(items)) if gid[i] not in cut]


def show(name, res, keys=None):
    for k in sorted(keys or res):
        if k not in res: continue
        v = res[k]
        print(f"{name:40s} {k:10s} keys {v['keys']:5d} shown {v['shown']:4d} cover {v['coverage']:4.1f}% right {v['right']:4.1f}% "
              f"wrong/1k {v['wrong_1k']:5.1f} saved {v['saved']:4.1f}% taken {v['taken']:4.1f}% new ms {v['ms_p50']}/{v['ms_p90']}/{v['ms_p99']}"
              + (f" late {v['late']}" if v['late'] else ""), flush=True)


def live_policy(path, gate_path="data/gate.json", memory=True, knobs=None):
    """What the live engine does on a recording: phrase memory first, then the gated model with the picked length
    rule and the AI-app tail (bench/lengths.py policy), the word finisher as fallback. Word lists dated before the cut."""
    import sys
    sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
    import lengths, ngram, typescore as ts
    from retrain_state import last_retrain
    cut = last_retrain(ROOT)
    import memory as mem
    W = ngram.Words(ngram.corpus_from(cut, words_sources()))
    gate = json.loads((ROOT / gate_path).read_text())
    knobs = knobs or {"min_letters": 5, "grow": 0.05, "tail": 0.3, "tail_words": 8}   # tail 0.2 before round five
    pol = lengths.policy(W, ts.knowledge_for(path), gate, **knobs)
    if memory:
        M = lengths.memory_from(ngram.corpus_from(cut, mem.Memory.SOURCES))
        pol = lengths.with_memory(pol, M, knobs.get("min_letters") or 1)
    return pol


def words_sources():
    import sys
    sys.path.insert(0, str(ROOT / "engine"))
    import words
    return words.Words.SOURCES


if __name__ == "__main__":
    import argparse, sys
    sys.path.insert(0, str(ROOT / "bench"))
    import typescore as ts
    ap = argparse.ArgumentParser(description="The one replay: live policy on a typebench recording")
    ap.add_argument("path")
    ap.add_argument("--gap", type=float, default=None, help="ms between his keys: a ghost slower than that is late")
    ap.add_argument("--no-memory", action="store_true")
    ap.add_argument("--gate", default="data/gate.json")
    a = ap.parse_args()
    items, rows = ts.load(a.path)
    pol = live_policy(a.path, a.gate, not a.no_memory)
    res, per = replay(items, rows, pol, gap_ms=a.gap)
    cal, test = split(items)
    print(f"{Path(a.path).stem}: {len(items)} lines; dated split {len(cal)} calibration / {len(test)} test")
    show("all", res)
    for k in sorted(k for k in res if "/" not in k):
        print(f"{'':40s} {k:10s} 95%: right {interval(per, k, 'right')} saved {interval(per, k, 'saved')} wrong/1k {interval(per, k, 'wrong_1k')}")
    tset = set(test)
    show("test half (later dates)", summarise([p for j, p in zip([i for i, it in enumerate(items)], per) if j in tset]) if len(per) == len(items) else {})
