"""Ghost length round (2026-11-13, Andrii: "too slow and not quite accurate... I would autocomplete more if we had
better autocomplete for longer sentences"). Scores show/hide/length rules offline on a typebench recording made with
enough tokens (--tokens 24), through the live gate (data/gate.json) and the live word finisher, with the same
simulated typist as bench/typescore.py, and splits everything by ghost length.

    .venv/bin/python bench/lengths.py data/bench/<label>.jsonl [--grid]

Per app (claude = AI apps, beeper = chats):
  saved     letters Tab put in minus one key per Tab, share of all letters (an ideal typist who always takes a right word)
  saved5    the same, counting only ghosts of 5+ letters when shown (live: he takes a ghost under 5 letters 3% of the
            time, 5-9 letters 30%; app.log 6-13 November), so the part of `saved` he really uses
  shown / right   suggestions shown; share whose first word was his next word
  wrong     shown suggestions whose first word was not his
  by length shown and right per bucket of letters shown (<5, 5-9, 10-14, 15-19, 20+), whole = the whole ghost was his
"""
import argparse, json, re, statistics, sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import typescore as ts
import gatecore
from words import finish_with_source

BUCKETS = ((0, 5, "<5"), (5, 10, "5-9"), (10, 15, "10-14"), (15, 20, "15-19"), (20, 10**6, "20+"))
END = ts.END


def letters(s):
    """Letters a ghost adds: what Tab puts in, spaces left out (gatecore.letters)."""
    return gatecore.letters(s)


def bucket(n):
    return next(b for lo, hi, b in BUCKETS if lo <= n < hi)


def policy(W, knowledge, gate, cap=10, max_words=3, more=0.5, min_letters=0, grow=None, grow_words=6, keep_mid=0,
           words_min=True, tail=None, tail_words=8, settle=False):
    """The live engine (server._complete gated path + model.complete_gated) on recorded tokens, with knobs:
    cap         tokens after the half word (the app sends max_tokens 10)
    max_words / more   sure words after the first: up to max_words while each token >= more
    min_letters hide a ghost that adds fewer letters (0 = live)
    grow        when the sure words add fewer than min_letters: go on past them while each token >= grow, up to
                grow_words words, until min_letters is reached (gatecore.grow); None = just hide
    keep_mid    a ghost that only finishes the word being typed stays under min_letters when that word is at least
                this long (0 = no exception)
    words_min   the word finisher's answer obeys min_letters too
    tail / tail_words  round two: past those words, the lighter tail while each token >= tail, up to tail_words words
                (gatecore.more_words); the server asks for up to min(24, 2 * tail_words + 2) tokens then
    settle      round five: stop as soon as the ghost can no longer change (gatecore.settled), as model.py does now
    """
    th = gate["th"]

    def short(before, out):
        if not min_letters or letters(out) >= min_letters: return False
        if keep_mid:
            heal = re.search(r"[\w'’-]*$", before.split("\n")[-1]).group(0)
            one = re.fullmatch(r"[\w'’-]+[.,!?:;)]*\s?", out or "")
            if heal and one and len(heal) + letters(out) >= keep_mid: return False
        return True

    def pol(row, before, src):
        fallback = lambda: finish_with_source(W, before, gate.get("words", (2, 0.6, 1)), knowledge)[0]
        finish = W.finish(before, 2, 0.5, 1)
        consumed, probability, rejected, count = [], None, False, 0
        limit = max(cap, min(24, 2 * tail_words + 2)) if tail is not None else cap
        threshold = th["ai" if src == "claude" else "chat"]

        def decide():
            features, _ = gatecore.features(consumed, before, src == "claude", finish)
            p = gatecore.score(gate["w"], features) if features else 0
            return p if features and p >= threshold else None
        for tok in row["toks"]:
            consumed.append(tok)
            text = tok[0]
            if not text: continue
            count += 1
            if probability is None and (gatecore.word_done(text) or END.search(text)):
                probability = decide()
                if probability is None: rejected = True; break
            if probability is not None:      # model.complete_gated's stop, step for step
                if END.search(text): break
                if settle:
                    now, _ = gatecore.shape(consumed, more, max_words, grow, grow_words, min_letters, tail, tail_words)
                    if gatecore.settled(text, now, min_letters if grow is not None else 0): break
                is_short = grow is not None and min_letters and letters(
                    gatecore.extend(consumed, gatecore.next_word(text), more, max_words)) < min_letters
                bars = [more] + ([grow] if is_short else []) + ([tail] if tail is not None else [])
                words = max([max_words] + ([grow_words] if is_short else []) + ([tail_words] if tail is not None else []))
                if tail is None and is_short and (tok[1] < grow or len(text.split()) > grow_words): break
                if tail is None and not is_short and (tok[1] < more or len(text.split()) > max_words): break
                if tail is not None and (tok[1] < min(bars) or len(text.split()) > words): break
            if count >= limit: break
        if not rejected and probability is None and consumed and consumed[-1][0]: probability = decide()
        ms = consumed[-1][3] if consumed else 0
        if probability is not None:
            first = gatecore.next_word(consumed[-1][0])
            out = ts.clean(before, gatecore.extend(consumed, first, more, max_words))
            if grow is not None and min_letters and letters(out) < min_letters:
                out = ts.clean(before, gatecore.grow(consumed, out, grow, grow_words, min_letters))
            if tail is not None and out: out = ts.clean(before, gatecore.more_words(consumed, out, tail, tail_words))
            if out and not short(before, out): return out, ms
            if out: return "", ms
        f = fallback()
        if f and words_min and short(before, f): return "", ms
        return f, ms
    return pol


MEM = {"spoke": 0, "right": 0, "model_right": 0, "model_shown": 0}


def with_memory(pol, M, min_letters=5):
    """server._complete: the phrase memory answers first and the model is not asked; it obeys min_letters too."""
    def p(row, before, src):
        said, _ = M.suggest(before)
        out = ts.clean(before, said) if said else ""
        if out and letters(out) >= min_letters:
            truth = p.text[len(before):]
            MEM["spoke"] += 1; MEM["right"] += bool(ts.next_word(out).strip()) and truth.startswith(ts.next_word(out))
            g, _ = pol(row, before, src)     # what the model would have shown here, for the same points
            if g: MEM["model_shown"] += 1; MEM["model_right"] += truth.startswith(ts.next_word(g)) and bool(ts.next_word(g).strip())
            return out, 6
        return pol(row, before, src)
    p.text = ""
    return p


def memory_from(lines, rule="e"):
    sys.path.insert(0, str(ROOT / "engine"))
    import memory, threading
    M = memory.Memory.__new__(memory.Memory)
    M.lock = threading.Lock()
    texts = [re.sub(r"[ \t]{2,}", " ", t) for t in lines]
    M.text = "\n" + "\n".join(texts) + "\n"; M.low = M.text.lower(); M.n = len(texts)
    M.RULE = rule
    return M


def simulate(items, rows, pol):
    """bench/measure.py replay(), in this bench's shape (round four: one replay for every bench)."""
    import measure
    res, _ = measure.replay(items, rows, pol)
    return {k: {"saved": v["saved"], "saved5": v["saved5"], "shown": v["shown"], "right": v["right"], "wrong": v["wrong"],
                "ms_p50": v["ms_p50"], "by": v["by"], "run": v["run"]} for k, v in res.items() if "/" not in k}


def show(name, res):
    for k, v in sorted(res.items()):
        by = " ".join(f"{b}:{n}/{r}/{w}" for b, (n, r, w) in v["by"].items())
        print(f"{name:44s} {k:6s} saved {v['saved']:4.1f}% saved5 {v['saved5']:4.1f}% shown {v['shown']:4d} right {v['right']:4.1f}% "
              f"wrong {v['wrong']:4d} ms {v['ms_p50']:3d} | {by}", flush=True)
        if RUNS:   # per bucket: shown, words shown, first 2 right, first 3 right, words after the first wrong one
            print(" " * 52 + "runs | " + " ".join(f"{b}:{n} w{ws} 2r{r2} 3r{r3} bad{bad}" for b, (n, ws, r2, r3, bad) in v["run"].items()), flush=True)


RUNS = False
POLICIES = {
    "live (cap 10, 3 words, more 0.5)": {},
    "min 5": {"min_letters": 5},
    "min 5, keep long mid-word (8+)": {"min_letters": 5, "keep_mid": 8},
    "min 5, grow 0.3": {"min_letters": 5, "grow": 0.3},
    "min 5, grow 0.2": {"min_letters": 5, "grow": 0.2},
    "min 5, grow 0.1": {"min_letters": 5, "grow": 0.1},
    "min 5, grow 0.05 (picked)": {"min_letters": 5, "grow": 0.05},
    "min 5, grow 0": {"min_letters": 5, "grow": 0.0},
}


def grid():
    out = {}
    for mw in (3, 5, 8):
        for more in (0.5, 0.4, 0.3):
            for cap in (10, 16, 24):
                if mw == 3 and cap > 10: continue
                out[f"min 5 grow 0.05, words {mw} more {more} cap {cap}"] = {"min_letters": 5, "grow": 0.05, "max_words": mw, "more": more, "cap": cap,
                                                                             "grow_words": max(6, mw)}
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path")
    ap.add_argument("--grid", action="store_true")
    ap.add_argument("--know", default="data/know.json")
    ap.add_argument("--gate", default="data/gate.json")
    ap.add_argument("--only", default=None, help="a JSON dict of knobs: score just that")
    ap.add_argument("--runs", action="store_true", help="also words right in a row per length bucket")
    ap.add_argument("--src", default=None, help="score only these items (claude or beeper)")
    ap.add_argument("--words", default=None, help="word finisher from data/corpus.jsonl, these sources (comma list)")
    ap.add_argument("--memory", default=None, help="phrase memory first, from data/corpus.jsonl, these sources (comma list)")
    ap.add_argument("--memory-rule", default="e")
    ap.add_argument("--newest-first", action="store_true", help="phrase memory: the newest line wins a tie")
    a = ap.parse_args()
    items, rows = ts.load(a.path)
    RUNS = a.runs
    if a.src:   # keep the item numbers the recording uses
        rows = {k: v for k, v in rows.items() if items[k[0]]["src"] == a.src}
    knowledge = ts.knowledge_for(a.path, a.know)
    import ngram
    from retrain_state import last_retrain
    cut = last_retrain(ROOT)
    W = ngram.Words(ngram.corpus_from(cut, a.words.split(",")) if a.words else ngram.corpus(cut))
    M = memory_from(ngram.corpus_from(cut, a.memory.split(","), a.newest_first), a.memory_rule) if a.memory else None
    gate = json.loads((ROOT / a.gate).read_text())
    pols = {"only": json.loads(a.only)} if a.only else (grid() if a.grid else POLICIES)
    for name, knobs in pols.items():
        pol = policy(W, knowledge, gate, **knobs)
        if M: pol = with_memory(pol, M, knobs.get("min_letters", 0) or 1)
        for k in MEM: MEM[k] = 0
        show(name, simulate(items, rows, pol))
        if M: print(f"{'':44s} memory spoke {MEM['spoke']}, first word right {MEM['right']}; the model at those points: "
                    f"shown {MEM['model_shown']}, right {MEM['model_right']}", flush=True)
