"""The decision gate: a tiny model that says how likely the next grey word is right, so Drafter shows only what he
would take (GitHub Copilot's "contextual filter" idea). Trained on bench/typebench.py recordings of the fresh replay
set: every position is one example, label = the model's next word is exactly what he wrote. Scored with held-out
folds (by line, no leak) through the same simulated typist as bench/typescore.py.

    .venv/bin/python bench/gate.py data/bench/<label>.jsonl [--save]     # --save writes data/gate.json for the engine
"""
import json, math, re, sys, zlib
from pathlib import Path
from retrain_state import last_retrain

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import typescore as ts
import ngram

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import gatecore as gc
from words import finish_with_source
NAMES = gc.NAMES
BOOST = {"boost30.jsonl": 0.3, "boost50.jsonl": 0.5, "boost15.jsonl": 0.15, "people30.jsonl": 0.3}   # recording -> booster share it ran with


def features(row, before, src, W=None):
    line = before.split("\n")[-1]
    finish = W.finish(before, 2, 0.5, 1) if W and re.search(r"[\w'’-]$", line) else ""
    f, w = gc.features(row["toks"], before, src == "claude", finish)
    return f, ts.clean(before, w)


def dataset(items, rows, W):
    X, y, keys = [], [], []
    for (i, pos), row in rows.items():
        text = items[i]["text"]; before = text[:pos]
        f, w = features(row, before, items[i]["src"], W)
        if f is None: continue
        X.append(f); y.append(float(text[pos:].startswith(w))); keys.append((i, pos))
    return np.array(X), np.array(y), keys


def fit(X, y, l2=1.0, steps=400):
    """Plain logistic regression (Newton steps), so the engine can run it with a dot product."""
    w = np.zeros(X.shape[1])
    for _ in range(steps):
        p = 1 / (1 + np.exp(-X @ w))
        g = X.T @ (p - y) + l2 * np.r_[0, w[1:]]
        H = (X * (p * (1 - p))[:, None]).T @ X + l2 * np.diag(np.r_[0, np.ones(len(w) - 1)])
        step = np.linalg.solve(H, g); w -= step
        if np.abs(step).max() < 1e-6: break
    return w


def held_out(items, X, y, keys, k=5):
    """P(right) for every example from a model that never saw its line."""
    # zlib.crc32, not hash(): Python's string hash changes every run, and so did these scores (by ~0.3 points)
    fold = np.array([zlib.crc32(items[i]["text"].encode()) % k for i, _ in keys])
    out = np.zeros(len(y))
    for f in range(k):
        w = fit(X[fold != f], y[fold != f])
        out[fold == f] = 1 / (1 + np.exp(-X[fold == f] @ w))
    return {key: p for key, p in zip(keys, out)}


def policy_from(P, items, rows, W, th, more=0.5, max_words=3, ngram_fallback=True, words_first=False, knowledge=None):
    """Show the model's words when the gate says the next one is right with P >= th (and further words while every
    token stays >= `more`); else the instant word finisher when it is clear; else nothing."""
    def pol(row, before, src):
        if words_first and W:
            f = finish_with_source(W, before, (2, 0.6, 1), knowledge)[0]
            if f: return f, 0.3
        key = row.get("_key")
        p = P.get(key)
        if p is not None and p >= th:
            toks = row["toks"]
            out = gc.extend(toks, ts.next_word(toks[-1][0]), more, max_words)
            # engine time: up to the token after the last shown word (it tells the word is whole)
            ms = next((t[3] for t in toks if t[0] and len(t[0]) > len(out.rstrip())), toks[-1][3])
            return out, ms
        # gate said no: the engine stopped right after the first word
        toks = row["toks"]
        w = ts.next_word(toks[-1][0]) if toks else ""
        ms = next((t[3] for t in toks if t[0] and len(t[0]) > len(w.rstrip())), toks[-1][3] if toks else 0)
        if ngram_fallback and W:
            f = finish_with_source(W, before, (2, 0.6, 1), knowledge)[0]
            if f: return f, ms
        return "", ms
    return pol


if __name__ == "__main__":
    path = sys.argv[1]
    know_path = sys.argv[sys.argv.index("--know") + 1] if "--know" in sys.argv else "data/know.json"
    knowledge = ts.knowledge_for(path, know_path)
    items, rows = ts.load(path)
    for k, r in rows.items(): r["_key"] = k
    cut = last_retrain(ROOT)
    W = ngram.Words(ngram.corpus(cut))
    X, y, keys = dataset(items, rows, W)
    print(f"{len(y)} examples, {y.mean() * 100:.0f}% right as recorded")
    P = held_out(items, X, y, keys)
    ts.show("current", ts.simulate(items, rows, ts.current))
    ts.show("ngram only (2, 0.6)", ts.simulate(items, rows, lambda r, b, s: (W.finish(b, 2, 0.6, 1), 0)))
    for th in ([] if "--save" in sys.argv else (0.4, 0.5, 0.6, 0.7, 0.8)):
        ts.show(f"gate {th} + ngram", ts.simulate(items, rows, policy_from(P, items, rows, W, th, knowledge=knowledge)))
        ts.show(f"gate {th} alone", ts.simulate(items, rows, policy_from(P, items, rows, W, th, ngram_fallback=False)))
        ts.show(f"words first, gate {th}", ts.simulate(items, rows, policy_from(P, items, rows, W, th, words_first=True, knowledge=knowledge)))
    if "--save" in sys.argv:
        w = fit(X, y)
        th = saved_th(ROOT / "data/gate.json")
        # picked 2026-10-31 on the fresh set: th 0.4 for AI apps and chats, sure words after the first at 0.5, up to 3;
        # the word finisher speaks when the gate says no (2 hits, 60% share, from the first letter)
        (ROOT / "data/gate.json").write_text(json.dumps({"names": NAMES, "w": [round(float(v), 4) for v in w], "from": Path(path).name,
            "th": th, "more": 0.5, "max_words": 3, "words": [2, 0.6, 1], "words_first": False,
            # the word booster's share (typebench --boost): the gate learns on what the model says with it, so the two
            # go together; a recording made without it saves 0
            "boost": ts.meta(path).get("boost", BOOST.get(Path(path).name, 0.0))}, indent=1))
        print("saved data/gate.json:", dict(zip(NAMES, np.round(w, 2))))


def saved_th(path, default=None):
    """The thresholds data/gate.json holds now: a refit keeps them (Argon 25: the weekly retrain's --save put back
    0.4 over a threshold set by hand). -> {"ai": th, "chat": th}"""
    out = dict(default or {"ai": 0.4, "chat": 0.4})
    try:
        old = json.loads(Path(path).read_text()).get("th") or {}
        out.update({k: float(old[k]) for k in ("ai", "chat") if isinstance(old.get(k), (int, float))})
    except Exception:
        pass
    return out


def summary(path, th=0.4):
    """{app: {"saved", "right", "shown"}} for the running policy (gate th + word finisher) on held-out folds, for
    bench/retrain.py to compare two layers."""
    items, rows = ts.load(path)
    for k, r in rows.items(): r["_key"] = k
    W = ngram.Words(ngram.corpus(last_retrain(ROOT)))
    X, y, keys = dataset(items, rows, W)
    res = ts.simulate(items, rows, policy_from(held_out(items, X, y, keys), items, rows, W, th, knowledge=ts.knowledge_for(path, ts.meta(path).get("know", "none"))))
    return {a: {"saved": v["saved%"], "right": v["right%"], "shown": v["shown"]} for a, v in res.items()}


def sweep(path):
    items, rows = ts.load(path)
    for k, r in rows.items(): r["_key"] = k
    W = ngram.Words(ngram.corpus(last_retrain(ROOT)))
    X, y, keys = dataset(items, rows, W)
    P = held_out(items, X, y, keys)
    for th in (0.35, 0.4, 0.45):
        for more in (0.3, 0.5, 0.7):
            for mw in (2, 3, 4):
                ts.show(f"th {th} more {more} words {mw}", ts.simulate(items, rows, policy_from(P, items, rows, W, th, more, mw)))
