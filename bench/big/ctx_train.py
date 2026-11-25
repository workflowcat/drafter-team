"""Big-model round (2026-11-15), item C: his layer trained on what he was answering. Each of his lines comes with the
screen text that stood above it (data/typed.jsonl `context`), in exactly the form the engine builds at typing time
(engine/prompt.py `tail`, after engine/server.py `normal_space` and `window` cut the screen text, CTX_CHARS), and the
loss is on his line only (the prompt is masked), to its real end. The rest of the mix is bench/corpus.py WEIGHTS (the
mix fixed on 14 November), in the same `tail` form without screen text.

    .venv/bin/python -B bench/big/ctx_train.py build --out data/bench/big/work/ctx-<tag> [--ctx-weight 2] [--no-ctx]
    (--no-ctx: the same rows, seed and split with the screen text left out: the control for the context layer)
    (training: bench/big/run.py train, which runs `train` below under the guard)

Strict time split: only lines dated before the held set's cut (the last retrain, before every held line) are used;
rows whose screen text holds a held line are left out too. No head (rules, his words, examples) in the training rows,
as for the live layer: the head is the same at every key and is not trained on.

The prompt/completion rows are read by mlx-lm's CompletionsDataset, which would wrap them in a chat template; `train`
replaces its `process` with plain text: the ids of prompt + line tokenised as one string (as the engine does), the
masked part the shared start with the prompt tokenised alone, and the end-of-text token after his line."""
import argparse, ast, json, random, re, sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
for p in (ROOT / "bench", ROOT / "engine"):
    if str(p) not in sys.path: sys.path.insert(0, str(p))
DATA = ROOT / "data"


def engine_cut():
    """engine/server.py normal_space and window (taken from the file, not imported: importing it loads the model)
    and CTX_CHARS. -> function(context) -> the screen text the prompt gets."""
    src = (ROOT / "engine/server.py").read_text()
    tree = ast.parse(src)
    fns = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in ("normal_space", "window")]
    import threading
    ns = {"re": re, "WINDOWS_LOCK": threading.Lock(), "WINDOWS": {}}
    exec(compile(ast.Module(body=fns, type_ignores=[]), "server.py", "exec"), ns)
    m = re.search(r'CTX_CHARS = int\(os.environ.get\("DRAFTER_CTX_CHARS", "(\d+)"\)\)', src)
    size = int(m.group(1))
    # remember=False: a line seen once has no anchor, so the window is the last `size` characters started at a line
    return lambda ctx: ns["window"](("train",), ns["normal_space"](ctx or "").strip(), size, remember=False)


def contexts(before):
    """{corpus key of a sent line (bench/corpus.py key): the screen text above it} for typed rows dated before
    `before`. By text, not time: the corpus keeps a line once (a typed line can sit there as a Claude Code prompt)."""
    import corpus as C
    out = {}
    for l in (DATA / "typed.jsonl").read_text(errors="ignore").splitlines():
        if not l.strip(): continue
        try: r = json.loads(l)
        except ValueError: continue
        if (r.get("t") or 0) < before and (r.get("context") or "").strip(): out[C.key(r.get("text") or "")] = r["context"]
    return out


def build(out_dir, before, held_texts, ctx_weight=None, max_tokens=1024, encode=None, seed=3, no_ctx=False):
    """Write train.jsonl / valid.jsonl of {"prompt", "completion"}. -> counts (numbers only)."""
    import corpus as C
    import prompt as P
    from held import norm, Held
    from make_train import APP_TAG
    is_held = Held(list(held_texts))
    held_keys = [norm(t)[:60] for t in held_texts if len(norm(t)) >= 20]
    cut = engine_cut()
    ctx = contexts(before)
    weights = C.weights()
    rows, n = [], Counter()
    for r in C.load(C.OUT, before=before):
        t = norm(r["text"])
        if is_held(t) or len(t) < 8 or not weights.get(r["src"]): continue
        app = APP_TAG.get(r["src"]) or r.get("app") or "Claude"
        c = ctx.get(C.key(r["text"]))
        if c and any(k in norm(c) for k in held_keys):
            n["ctx_holds_held_line"] += 1; c = None
        shown = cut(c) if c else ""
        prompt = P.tail("", app, "", shown, "")
        if encode and len(encode(prompt + t)) > max_tokens:
            n["too_long"] += 1; continue
        if no_ctx: prompt = P.tail("", app, "", "", "")     # the control: same row, no screen text
        w = float(weights[r["src"]])
        if shown and ctx_weight is not None: w = float(ctx_weight)
        rows.append({"src": r["src"] + ("+ctx" if shown else ""), "w": w, "prompt": prompt, "completion": t})
        n[r["src"] + ("+ctx" if shown else "")] += 1
    random.Random(seed).shuffle(rows)
    k = max(60, len(rows) // 20)
    valid, rest = rows[:k], rows[k:]
    rnd, train = random.Random(seed), []
    for r in rest:
        train += [r] * (int(r["w"]) + (rnd.random() < r["w"] - int(r["w"])))
    random.Random(seed + 1).shuffle(train)
    out = Path(out_dir); out.mkdir(parents=True, exist_ok=True)
    dump = lambda rs: "".join(json.dumps({"prompt": r["prompt"], "completion": r["completion"]}, ensure_ascii=False) + "\n" for r in rs)
    (out / "valid.jsonl").write_text(dump(valid)); (out / "train.jsonl").write_text(dump(train))
    per = Counter(r["src"] for r in train)
    info = {"distinct": dict(n), "train": len(train), "valid": len(valid), "train_per_source": dict(per), "before": before,
            "ctx_weight": ctx_weight, "no_ctx": no_ctx}
    (out / "info.json").write_text(json.dumps(info, indent=1))
    return info


def plain_process(tokenizer, prompt, completion, mask):
    """(ids, offset) of prompt + completion as one text, the end-of-text token after it; offset = tokens of the prompt
    that stay the same when it is tokenised alone (the masked part)."""
    ids = tokenizer.encode(prompt + completion)
    eos = tokenizer.eos_token_id
    if not ids or ids[-1] != eos: ids = ids + [eos]
    if not mask: return ids, 0
    p = tokenizer.encode(prompt)
    k = 0
    for a, b in zip(p, ids):
        if a != b: break
        k += 1
    return ids, min(k, len(ids) - 1)


def train(argv):
    """mlx_lm.lora with prompt/completion rows read as plain text (see plain_process). argv: mlx_lm.lora arguments."""
    from mlx_lm.tuner import datasets as D

    def process(self, d):
        return plain_process(self.tokenizer, d[self.prompt_key], d[self.completion_key], self.mask_prompt)
    D.CompletionsDataset.process = process
    import runpy
    sys.argv = ["mlx_lm.lora", *argv]
    runpy.run_module("mlx_lm.lora", run_name="__main__")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "train":
        return train(sys.argv[2:])
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["build"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--set", default="data/bench/weights/held-137.json")
    ap.add_argument("--ctx-weight", type=float, default=None)
    ap.add_argument("--no-ctx", action="store_true")
    ap.add_argument("--tokenizer", default="mlx-community/Qwen3-1.7B-4bit", help="for the length cap only")
    a = ap.parse_args()
    from retrain_state import last_retrain
    import held
    before = last_retrain(ROOT)
    held_texts = list(held.texts()) + [x["text"] for x in json.loads((ROOT / a.set).read_text())]
    from transformers import AutoTokenizer
    from huggingface_hub import snapshot_download
    tok = AutoTokenizer.from_pretrained(snapshot_download(a.tokenizer, local_files_only=True))
    info = build(ROOT / a.out, before, held_texts, a.ctx_weight, encode=lambda s: tok.encode(s, add_special_tokens=False), no_ctx=a.no_ctx)
    print(json.dumps(info, indent=1))


if __name__ == "__main__":
    main()
