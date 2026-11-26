"""bench/typebench.py with prompt knobs for the models round, in this one process (run it under the guard:
bench/models/shared.py `record`). Every typebench argument passes through; these are added:

    --head rules,words,examples   head parts to keep (default all three: engine/prompt.py head() as it is)
                                  rules = the user's style rules and the per-app style line; words = their words and names;
                                  examples = their example messages
    --ctx-tokens N                keep only the last N tokens of the screen text (cut at a word start); default as is
    --before-tokens N             keep only the last N tokens of the text before the caret; default as is

Knobs typebench has already: --know none (no knowledge pack), no --people (no per-chat lines), --ctx-chars 0 (no
screen text), --boost 0 (no word booster). DRAFTER_MODEL_REVISION pins the cached snapshot of the repo.
engine/prompt.py is not changed: the knobs replace its functions in this process only."""
import os, re, runpy, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
PARTS = ("rules", "words", "examples")


def take(argv, flag, cast=str):
    """Remove `flag value` from argv. -> value or None."""
    if flag not in argv: return None
    i = argv.index(flag)
    v = argv[i + 1]
    del argv[i:i + 2]
    return cast(v)


def cut_tokens(text, n, encode, decode):
    """The last `n` tokens of `text`, starting at a word start (the cut never leaves half a word). n None = all."""
    if n is None or not text: return text
    ids = encode(text)
    if len(ids) <= n: return text
    if n <= 0: return ""
    tail = decode(ids[-n:]).lstrip("\ufffd")        # a cut inside a multi-byte letter decodes to U+FFFD
    if not tail: return ""
    start = len(text) - len(tail)
    if start > 0 and not text[start - 1].isspace():  # the tail starts inside a word: drop that piece
        m = re.search(r"\s", text[start:])
        start = start + m.end() if m else len(text)
    return text[start:]


def head_from(keep, rules, words, examples, n_examples=12, n_words=40):
    """engine/prompt.py head() with some parts left out. keep: set of PARTS. All three -> the same text as head()."""
    parts = []
    if "rules" in keep: parts.append(rules())
    w = words()[:n_words] if "words" in keep else []
    if w: parts.append("Його слова й імена: " + ", ".join(w))
    if "examples" in keep: parts.append("Його повідомлення:\n" + "\n###\n".join(examples()[:n_examples]))
    return ("\n\n".join(parts) + "\n###\n") if parts else "###\n"


def patch(prompt, keep=None, ctx_tokens=None, before_tokens=None):
    """Replace prompt.head / prompt.tail / prompt.STYLE in this process for the knobs; returns the holder that gets
    the model once a Builder is made (for the tokenizer)."""
    holder = {}
    if keep is not None and set(keep) != set(PARTS):
        ex = lambda: prompt.load_json(ROOT / "data" / "style.json", {"examples": []})["examples"]
        prompt.head = lambda n_examples=12, n_words=40: head_from(set(keep), prompt.rules, prompt.words, ex, n_examples, n_words)
        if "rules" not in keep: prompt.STYLE = {}
    if ctx_tokens is not None or before_tokens is not None:
        orig_init, orig_tail = prompt.Builder.__init__, prompt.tail

        def init(self, model, fmt="raw"):
            holder["m"] = model
            orig_init(self, model, fmt)

        def tail(before, app="", title="", context="", mine="", clip="", notes=""):
            m = holder.get("m")
            if m is not None:
                enc = lambda s: m.encode(s)
                dec = lambda ids: m.tok.decode(ids)
                if ctx_tokens is not None: context = cut_tokens(context, ctx_tokens, enc, dec)
                if before_tokens is not None: before = cut_tokens(before, before_tokens, enc, dec)
            return orig_tail(before, app, title, context, mine, clip, notes)

        prompt.Builder.__init__ = init
        prompt.tail = tail
    return holder


def main():
    argv = sys.argv[1:]
    keep = take(argv, "--head")
    keep = [p for p in keep.split(",") if p] if keep is not None else None
    if keep is not None and set(keep) - set(PARTS): raise SystemExit(f"--head parts are {PARTS}")
    ctx_tokens = take(argv, "--ctx-tokens", int)
    before_tokens = take(argv, "--before-tokens", int)
    rev = os.environ.get("DRAFTER_MODEL_REVISION")
    if rev and argv and not argv[0].startswith("-"):
        from huggingface_hub import snapshot_download
        argv[0] = snapshot_download(argv[0], revision=rev, local_files_only=True)
    sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))
    import prompt
    patch(prompt, keep, ctx_tokens, before_tokens)
    sys.argv = [str(ROOT / "bench/typebench.py"), *argv]
    runpy.run_path(str(ROOT / "bench/typebench.py"), run_name="__main__")
    label = argv[argv.index("--label") + 1] if "--label" in argv else None
    if label:   # the knobs go into the recording's meta, so a score can say what it was made with
        import json
        mp = ROOT / "data/bench" / f"{label}.meta.json"
        try:
            meta = json.loads(mp.read_text())
            meta.update({"head": keep or list(PARTS), "ctx_tokens": ctx_tokens, "before_tokens": before_tokens,
                         "revision": rev})
            mp.write_text(json.dumps(meta, indent=1))
        except (OSError, ValueError):
            pass


if __name__ == "__main__":
    main()
