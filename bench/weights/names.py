"""Item B4, the evidence: how much of his writing is words the tokenizer splits into many pieces. Loads the tokenizer
only (no model), reads his word counts (data/myword-counts.json, built by the word finisher) and prints numbers.

    .venv/bin/python -B bench/weights/names.py [--top 300]
A word is counted as the model sees it mid-sentence (with a leading space). The counts are lower case, so names come
from his dictionary (data/words.json: the names and terms the prompt head lists), matched to the counts in lower case.
Output: data/bench/weights/names.json: share of his word uses by token count, the same for the top words and for the
dictionary names, and the decode steps a single-token form would save."""
import argparse, json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C


def tokenizer():
    from huggingface_hub import snapshot_download
    from transformers import AutoTokenizer
    return AutoTokenizer.from_pretrained(snapshot_download(C.BASE, local_files_only=True))


def stats(counts, n_tokens, top=300, names=()):
    """counts {word: uses}, n_tokens(word) -> numbers: uses by token count, steps saved if each word were one token."""
    by = {}
    steps = saved = 0
    for w, c in counts.items():
        k = n_tokens(w)
        b = "4+" if k >= 4 else str(k)
        by[b] = by.get(b, 0) + c
        steps += c * k
        saved += c * (k - 1)
    total = sum(counts.values()) or 1
    head = sorted(counts, key=lambda w: -counts[w])[:top]
    many = [w for w in head if n_tokens(w) >= 3]
    names = [w for w in names if w and " " not in w]
    name_uses = {w: counts.get(w.lower(), 0) for w in names}
    return {"words": len(counts), "uses": total,
            "uses_by_tokens_pct": {b: round(100 * v / total, 1) for b, v in sorted(by.items())},
            "tokens_per_word": round(steps / total, 2), "steps_saved_if_one_token_pct": round(100 * saved / max(steps, 1), 1),
            f"top{top}_with_3plus_tokens": len(many),
            f"top{top}_3plus_uses_pct": round(100 * sum(counts[w] for w in many) / total, 2),
            "names": len(names), "names_3plus_tokens": sum(1 for w in names if n_tokens(w) >= 3),
            "name_uses_pct": round(100 * sum(name_uses.values()) / total, 2),
            "name_3plus_uses_pct": round(100 * sum(c for w, c in name_uses.items() if n_tokens(w) >= 3) / total, 2),
            "name_tokens_mean": round(sum(n_tokens(w) for w in names) / max(len(names), 1), 2)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=300)
    a = ap.parse_args()
    counts = json.loads((C.DATA / "myword-counts.json").read_text())
    counts = {w: int(c) for w, c in counts.items() if isinstance(c, (int, float)) and c > 0}
    tok = tokenizer()
    memo = {}
    n = lambda w: memo.setdefault(w, len(tok.encode(" " + w, add_special_tokens=False)))
    try: names = [w["text"] if isinstance(w, dict) else w for w in json.loads((C.DATA / "words.json").read_text())["words"]]
    except (OSError, ValueError, KeyError): names = []
    res = stats(counts, n, a.top, names)
    p = C.write("names", res)
    print(json.dumps(res, indent=1)); print(f"-> {p}")


if __name__ == "__main__":
    main()
