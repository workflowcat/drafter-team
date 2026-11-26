"""Phrase memory: the user's own sentences, so a phrase the user has written before comes back in a few milliseconds, before
(and instead of) the model.

    .venv/bin/python engine/memory.py build      # writes data/phrases.jsonl (local only, never in git)
    .venv/bin/python engine/memory.py try "можемо поговорити кор"

Sources, all read-only and local: messages the user sent in Beeper, what the user typed to Claude in Claude
Code / the Claude app (their prompts, not pasted text or messages from other sessions), and what the user sent while Drafter was
on (data/typed.jsonl). Nothing from skipped apps or password fields ever gets there.
"""
import glob, json, os, re, subprocess, sys, threading, time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
OUT = DATA / "phrases.jsonl"
END = re.compile(r"[.!?…\n)]")
WORD = re.compile(r"[\w'’-]+", re.U)


def clean(t):
    t = re.sub(r"<br\s*/?>", "\n", t or ""); t = re.sub(r"<[^>]+>", "", t)
    return "\n".join(l.strip() for l in t.splitlines() if l.strip())


def beeper(after="2025-09-01T00:00:00Z", limit=4000):
    import integrations   # optional integration (engine/integrations.py)
    if not integrations.available("beeper"): return []
    try:
        out = subprocess.run([__import__("people").beeper_bin(), "messages", "search", "--sender", "me", "--after", after, "--limit", str(limit), "--json",
                              "-q", "--read-only", "--full"], capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL,
                             env={**os.environ, "BEEPER_READONLY": "1"}).stdout
        rows = json.loads(out)["data"]
    except Exception as e:
        print("beeper:", e); return []
    return [clean(m["text"]) for m in rows if m.get("type") == "TEXT" and m.get("text") and not clean(m["text"]).lower().startswith("клод:")]


SKIP_PROMPT = re.compile(r"^(<|\[|Background \(from|Reply with|Caveat:|This session|Another Claude|Do what the system prompt)|```|<cross-session")


def claude_prompts(days=60):
    """The user's own typed prompts: user turns with plain text, from a person (userType external), not pasted walls."""
    since = time.time() - days * 86400
    files = [f for f in glob.glob(str(Path.home() / ".claude/projects/*/*.jsonl")) if os.path.getmtime(f) > since]
    out = []
    for f in files:
        try:
            with open(f, errors="ignore") as h:
                for line in h:
                    if '"type":"user"' not in line or '"userType":"external"' not in line: continue
                    try: d = json.loads(line)
                    except Exception: continue
                    c = (d.get("message") or {}).get("content")
                    if not isinstance(c, str) or d.get("isMeta") or d.get("isSidechain"): continue
                    if d.get("entrypoint") not in (None, "cli", "claude-desktop", "claude-vscode"): continue   # headless runs are not typing
                    c = c.strip()
                    if 12 <= len(c) <= 600 and not SKIP_PROMPT.search(c): out.append(c)
        except Exception:
            continue
    return out


def typed():
    try: return [json.loads(l)["text"] for l in (DATA / "typed.jsonl").read_text().splitlines() if l.strip()]
    except Exception: return []


def build(output=None):
    output = Path(output) if output is not None else OUT
    t = time.time()
    seen, rows = set(), []
    for src, items in (("beeper", beeper()), ("claude", claude_prompts()), ("typed", typed())):
        n = 0
        for x in items:
            x = x.strip()
            if len(WORD.findall(x)) < 3 or x in seen: continue
            seen.add(x); rows.append({"src": src, "text": x}); n += 1
        print(f"{src}: {n}")
    output.parent.mkdir(parents=True, exist_ok=True)
    tmp = output.with_suffix(".tmp")
    tmp.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n"); tmp.replace(output)
    print(f"{len(rows)} phrases -> {output} in {time.time() - t:.1f}s")


CORPUS = DATA / "corpus.jsonl"


def from_corpus(sources):
    """The user's lines from data/corpus.jsonl in these sources, plus what the user sent after it was built (data/typed.jsonl);
    None when there is no corpus yet (the old sources then)."""
    try:
        built = CORPUS.stat().st_mtime
        rows = [json.loads(l) for l in CORPUS.read_text().splitlines() if l.strip()]
    except Exception:
        return None
    texts = [r["text"] for r in rows if r.get("src") in sources]
    try: texts += [r["text"] for r in (json.loads(l) for l in (DATA / "typed.jsonl").read_text().splitlines()[-2000:] if l.strip())
                   if (r.get("t") or 0) > built]
    except Exception: pass
    return texts


def vote(conts, max_words=3, agree=0.75):
    """conts: Counter of continuations -> (text, hits of its first word, that word's share of all matches). The first
    word wins by votes; each further word only while 2+ of the matches still on the path, and `agree` of them, share it."""
    total = sum(conts.values())
    if not total: return "", 0, 0.0
    split = [(re.findall(r"\S+\s*", c), n) for c, n in conts.items()]
    lead = Counter()
    for ws, n in split:
        if ws: lead[ws[0].rstrip()] += n
    if not lead: return "", 0, 0.0
    w1, hits = lead.most_common(1)[0]
    path = [(ws, n) for ws, n in split if ws and ws[0].rstrip() == w1]
    # the first word keeps its own spacing: the most common way it was followed (a space, the end of the line)
    first = Counter()
    for ws, n in path: first[ws[0]] += n
    out = [first.most_common(1)[0][0]]
    for j in range(1, max_words):
        nxt = Counter()
        for ws, n in path:
            if len(ws) > j: nxt[ws[j]] += n
        if not nxt: break
        w, c = nxt.most_common(1)[0]
        on = sum(n for _, n in path)
        if c < 2 or c / on < agree: break
        if not out[-1][-1:].isspace(): break
        out.append(w); path = [(ws, n) for ws, n in path if len(ws) > j and ws[j] == w]
    return "".join(out).rstrip(), hits, hits / total


class Memory:
    """All the user's text as one string; a query finds the same words the user has used before and returns what followed."""

    def __init__(self):
        self.lock = threading.Lock()
        self.load()

    # Round three (2026-11-13): from data/corpus.jsonl (bench/corpus.py) when it is there. Voice takes stay out: on held-out
    # typed lines in AI apps they made it speak more and be right less (docs/rounds/2026-11-13-typing.md).
    SOURCES = ("typed", "cc", "codex", "beeper", "fb", "vault", "import")

    def load(self):
        texts = from_corpus(self.SOURCES)
        if texts is None:
            texts = []
            for p in (OUT,):
                try: texts += [json.loads(l)["text"] for l in p.read_text().splitlines() if l.strip()]
                except Exception: pass
            try: texts += [json.loads(l)["text"] for l in (DATA / "typed.jsonl").read_text().splitlines()[-2000:] if l.strip()]
            except Exception: pass
        texts = [re.sub(r"[ \t]{2,}", " ", t) for t in texts]   # the user's double spaces are slips, not style
        with self.lock:
            self.text = "\n" + "\n".join(texts) + "\n"
            self.low = self.text.lower()
            self.n = len(texts)

    def add(self, line):
        line = re.sub(r"[ \t]{2,}", " ", line)
        with self.lock:
            self.text += line + "\n"; self.low += line.lower() + "\n"; self.n += 1

    # "e" (bench/memory_eval.py 2026-10-19): 5 words of context, or 2+ matches with 75% on one whole continuation.
    # "w" (round four, 2026-11-14, tried, not picked): matches vote by their next word ("the deployment today" and
    # "the deployment after lunch" agree on "deployment"). On held-out lines it spoke 19 times instead of 13 with the
    # same 10 right; a stricter bar (3 matches, 85%) spoke 8 times, 4 right. docs/rounds/2026-11-13-typing.md.
    RULE = "e"

    def suggest(self, before, max_words=3, max_chars=32):
        """-> (continuation, hits) or ("", 0). Needs 2+ whole words of context (or 18+ characters) to speak."""
        line = before.split("\n")[-1]
        if not line.strip(): return "", 0
        low = line.lower()
        with self.lock: text, lowered = self.text, self.low
        # context from the longest (5 words) down to 2 words, the half-typed word included
        starts = [m.start() for m in re.finditer(r"(?:^|(?<=\s))\S", low)]
        best = ("", 0)
        for k in range(min(5, len(starts)), 1, -1):
            q = low[starts[-k]:]
            if len(q) < 8: continue
            conts, i = Counter(), 0
            while len(conts) < 60:
                i = lowered.find(q, i)
                if i < 0: break
                ok_left = i == 0 or not lowered[i - 1].isalnum()
                j = i + len(q); i += 1
                if not ok_left: continue
                rest = text[j:j + 120]
                m = END.search(rest)
                cont = rest[: m.end()] if m else rest
                cont = cont.split("\n")[0]
                words = re.findall(r"\S+\s*", cont)
                cont = "".join(words[:max_words]).rstrip() if len(words) > max_words else cont
                if len(cont) > max_chars: cont = cont[:max_chars].rsplit(" ", 1)[0]
                if cont.strip(): conts[cont] += 1
            if not conts: continue
            if self.RULE == "w":
                cont, hits, share = vote(conts, max_words)
                if cont and ((k >= 5) or (hits >= 2 and share >= 0.75)): return cont, hits
                continue
            cont, hits = conts.most_common(1)[0]
            total = sum(conts.values())
            # one clear answer: long context with any hit, or shorter context where most matches agree
            share = hits / total
            if self.RULE == "e": strong = (k >= 5) or (hits >= 2 and share >= 0.75)
            elif self.RULE == "default": strong = (k >= 3 and share >= 0.5) or (k == 2 and hits >= 2 and share >= 0.6)
            elif self.RULE == "b": strong = (k >= 4 and share >= 0.5) or (hits >= 2 and share >= 0.6)
            elif self.RULE == "c": strong = hits >= 2 and share >= 0.6
            elif self.RULE == "d": strong = (k >= 4 and share >= 0.5) or (hits >= 3 and share >= 0.6)
            else: strong = False
            if strong: return cont, hits
            if not best[0]: best = ("", 0)
        return best


if __name__ == "__main__":
    if sys.argv[1:2] == ["build"]:
        import argparse
        parser = argparse.ArgumentParser(description="Build local phrase memory")
        parser.add_argument("--output", type=Path, default=OUT)
        build(parser.parse_args(sys.argv[2:]).output)
    elif sys.argv[1:2] == ["try"]:
        m = Memory(); t = time.perf_counter()
        for q in sys.argv[2:]: print(repr(q), "->", m.suggest(q), f"{(time.perf_counter() - t) * 1000:.1f} ms")
    else: print(__doc__)
