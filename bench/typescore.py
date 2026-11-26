"""Score show/hide rules on recordings from bench/typebench.py, offline (no model).

A simulated user types each fresh line letter by letter. A grey suggestion stays while the user types the same letters
(as in the app) and is asked again when the user types something else. When the next grey word is exactly what the user
wrote, the user presses Tab (one key) and it goes in. Scores per app:
  saved   - letters Tab put in, minus the Tab presses, as a share of all letters
  shown   - suggestions that appeared;  right - share of them the user took at least one word of (the user's trust in it)
  ms      - key to grey text for what was shown (engine time only: prefill + tokens up to the last shown word)

    .venv/bin/python bench/typescore.py data/bench/<label>.jsonl [policy ...]
Policies: current (what the app does today), word (only finish the word being typed), gate (bench/gate.py model).
"""
import hashlib, json, math, re, statistics, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
from gatecore import next_word
SETS = ROOT / "data/bench/sets"     # every fresh set a recording was made on, by its fingerprint (bench/make_fresh.py)


def set_sha(path):
    return hashlib.sha1(Path(path).read_bytes()).hexdigest()[:12]


def meta(path):
    """What a recording was made with (typebench writes <label>.meta.json): set, its fingerprint, booster, people."""
    try: return json.loads(Path(str(path)[: -len(".jsonl")] + ".meta.json").read_text())
    except Exception: return {}


def set_for(path, set_path=None):
    """The fresh set a recording belongs to. The retrain draws a new set each week (data/replay-fresh.json), so a
    recording is scored on its own (kept in data/bench/sets/); one from before the meta files uses the current set."""
    if set_path: return ROOT / set_path
    m = meta(path)
    if not m.get("set_sha"): return ROOT / "data/replay-fresh.json"
    for cand in (ROOT / m.get("set", "data/replay-fresh.json"), SETS / f"{m['set_sha']}.json"):
        if cand.exists() and set_sha(cand) == m["set_sha"]: return cand
    raise SystemExit(f"{path}: made on fresh set {m['set_sha']}, which is gone (data/bench/sets/)")
END = re.compile(r"[.!?…)\n]")


def load(path, set_path=None):
    rows = {}
    for l in Path(path).read_text().splitlines():
        try: r = json.loads(l)
        except ValueError: continue          # a line still being written
        rows[(r["i"], r["pos"])] = r
    items = json.loads(set_for(path, set_path).read_text())
    n = max(i for i, _ in rows)            # the last line may be unfinished: score whole lines only
    rows = {k: v for k, v in rows.items() if k[0] < n} if n < len(items) - 1 else rows
    return items[: n if n < len(items) - 1 else n + 1], rows


def clean(before, text):
    """engine/server.py clean() and the app's 'never two spaces'."""
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


def is_new_word(piece):
    return not piece[:1].isalnum() and piece[:1] not in ("'", "’", "-")


def current(row, before, src, bars=(0.3, 0.45, 0.6), max_tokens=10):
    """engine/model.py complete() with the app's per-app settings (app/Keys.swift length())."""
    max_words, soft, soft_from = (3, 0.25, 1) if src == "claude" else (4, 0.2, 2)
    heal, toks = row["heal"], row["toks"]
    sure, strict_end, n, healed_at, text, last_ms = "", None, 0, None, "", 0
    for text, p, p2, ms, piece in toks:
        n += 1
        new_word = is_new_word(piece)
        words = len(text.split())
        bw, bn, bf = bars
        bar = bw if not new_word else (bn if words <= 1 else bf)
        soft_ok = bool(soft) and words >= soft_from and p >= soft and (new_word or strict_end is not None)
        if p < bar and soft_ok and strict_end is None: strict_end = len(sure)
        if p < bar and not soft_ok:
            t = sure
            if t and piece[:1].isalnum() and not t[-1:].isspace():
                t = t[: max(t.rfind(" "), 0)] if " " in t.strip() else ("" if not heal else t)
            return t.rstrip(), ms   # it took this token to see it was unsure
        last_ms = ms
        if heal and not text: continue
        if healed_at is None: healed_at = n - 1 if heal else 0
        sure = text
        if len(text.split()) > max_words:
            return " ".join(text.split(" ")[: max_words + (1 if text.startswith(" ") else 0)]), ms
        m = END.search(text)
        if m: return text[: m.end()].rstrip("\n"), ms
        if n - healed_at >= max_tokens:
            if strict_end is not None:
                cut = text.rfind(" ")
                text = text[:cut] if cut > strict_end else text
            return text, ms
    return text, last_ms


def simulate(items, rows, policy, src=None, tab_cost=1):
    """bench/measure.py replay(), in this bench's shape; `right%` here is the share of shown ghosts the user took at least
    one word of (measure's `taken`), as before, so the retrain's comparison keeps its meaning."""
    import measure
    res, _ = measure.replay(items, rows, policy, tab_cost=tab_cost, only=src)
    return {k: {"saved%": v["saved"], "tabs": v["tabs"], "shown": v["shown"], "right%": v["taken"], "first%": v["right"],
                "ms_p50": v["ms_p50"], "ms_p90": v["ms_p90"]} for k, v in res.items() if "/" not in k}


def show(name, res):
    print(f"{name:28s} " + " | ".join(f"{k}: saved {v['saved%']}% · {v['tabs']} tabs · shown {v['shown']} · right {v['right%']}% · {v['ms_p50']}/{v['ms_p90']} ms"
                                      for k, v in sorted(res.items())))


def knowledge_for(recording, path="data/know.json"):
    """Do not silently score recorded booster tokens against another knowledge pack."""
    sys.path.insert(0, str(ROOT / "engine"))
    from know import Pack
    p = None if path == "none" else ROOT / path
    actual = set_sha(p) if p is not None and p.exists() else None
    recorded = meta(recording)
    if recorded.get("know_sha") != actual:
        raise ValueError("knowledge differs from the recording; record again with --know PATH|none")
    pack = Pack(p); pack.reload()
    return pack


def live_policy(W, knowledge, config):
    """The live gate feature, extension and word/knowledge fallback on recorded tokens."""
    sys.path.insert(0, str(ROOT / "engine"))
    import gatecore
    from words import finish_with_source
    def policy(row, before, src):
        fallback = lambda: finish_with_source(W, before, config.get("words", (2, 0.6, 1)), knowledge)[0]
        if config.get("words_first"):
            f = fallback()
            if f: return f, 0
        finish = W.finish(before, 2, 0.5, 1)
        consumed, probability, rejected, count = [], None, False, 0
        more, max_words = config.get("more", 0.5), config.get("max_words", 3)
        threshold = config["th"]["ai" if src == "claude" else "chat"]
        def decide():
            features, _ = gatecore.features(consumed, before, src == "claude", finish)
            p = gatecore.score(config["w"], features) if features else 0
            return p if features and p >= threshold else None
        # Stop at precisely the live complete_gated boundary, including a low-probability
        # token after the first word. Later recorded tokens cannot rescue that suggestion.
        for tok in row["toks"]:
            consumed.append(tok)
            text = tok[0]
            if not text: continue
            count += 1
            if probability is None and (gatecore.word_done(text) or END.search(text)):
                probability = decide()
                if probability is None: rejected = True; break
            if probability is not None and (tok[1] < more or len(text.split()) > max_words or END.search(text)): break
            if count >= row.get("max_tokens", 8): break
        if not rejected and probability is None and consumed and consumed[-1][0]: probability = decide()
        ms = consumed[-1][3] if consumed else 0
        if probability is not None:
            out = clean(before, gatecore.extend(consumed, gatecore.next_word(consumed[-1][0]), more, max_words))
            if out: return out, ms
        return fallback(), ms
    return policy


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path")
    ap.add_argument("policies", nargs="*", default=["gate"])
    ap.add_argument("--know", default="data/know.json")
    ap.add_argument("--gate", default="data/gate.json")
    a = ap.parse_args()
    items, rows = load(a.path)
    knowledge = knowledge_for(a.path, a.know)
    import ngram
    from retrain_state import last_retrain
    W = ngram.Words(ngram.corpus(last_retrain(ROOT)))
    for p in a.policies:
        if p == "current": show("current", simulate(items, rows, current))
        elif p == "word":
            from words import finish_with_source
            show("word + knowledge", simulate(items, rows, lambda r,b,s: (finish_with_source(W,b,knowledge=knowledge)[0], 0)))
        elif p == "gate":
            config = json.loads((ROOT / a.gate).read_text())
            if float(config.get("boost", 0)) != float(meta(a.path).get("boost", 0)):
                raise SystemExit("gate boost differs from recording")
            show("live gate + knowledge", simulate(items, rows, live_policy(W, knowledge, config)))
        else: raise SystemExit("unknown policy: " + p)
