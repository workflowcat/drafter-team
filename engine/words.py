"""Instant word finisher (2026-10-31): finishes the word being typed from Andrii's own writing, with no model, in
well under a millisecond. The word he most often wrote after the same one or two words decides, and only when it is
clear. On the fresh replay set (bench/ngram.py, lines written after the last retrain) it was right 77% of the times
it spoke in Claude and 63% in Beeper, against ~30% for the model's own next word.

Sources (local only): data/phrases.jsonl (his Beeper, Voice Notes and Claude lines), data/typed.jsonl, data/drafts.jsonl,
the shared dictionary (names keep their spelling), and every line he sends while Drafter runs (`add`).
"""
import bisect, json, os, re, threading
from sys import intern
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
WORD = re.compile(r"[\w'’-]+")
RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")
EN_KEYS = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
UK_KEYS = "'йцукенгшщзхїфівапролджєячсмитьбю."
TO_UK = dict(zip(EN_KEYS, UK_KEYS))
TO_EN = {b: a for a, b in TO_UK.items()}



def finish_with_source(W, before, config=(2, 0.6, 1), knowledge=None):
    """Shared live/replay fallback. His writing always gets first choice."""
    word = W.finish(before, *config)
    if word: return word, "words"
    word = ""
    if knowledge is not None:
        with W.lock:
            word = knowledge.finish(before, W.own_folded, W.own_prefix)
    return word, "know" if word else ""


def know_only(W, before, knowledge=None):
    """A name from the names / knowledge pack for the word being typed, his own words left out (2026-11-16): with the
    selector on, his words go through the selector and finish_with_source never ran, so no name was ever offered
    (/health know.offered stayed 0). The server offers this when the model has nothing for the spot."""
    if knowledge is None: return ""
    with W.lock:
        return knowledge.finish(before, W.own_folded, W.own_prefix) or ""


def boost_targets(W, before, heal, k=8, knowledge=None, context="", title=""):
    """One distribution, one model mixing share. Reserve 20% of existing mass for matching capitalized half words.
    Without screen matches the previous word distribution is unchanged.
    """
    own = W.dist(before, k)
    names = knowledge.targets(before, context, title) if knowledge is not None else []
    lead = heal if heal else ("" if not before or before[-1].isspace() else " ")
    if not names: return [(lead + rest, p) for rest, p in own if lead + rest]
    # Keep the old total probability mass (or one when no own targets exist).
    mass = sum(p for _, p in own) if own else 1.0
    mixed = Counter()
    for rest, p in own: mixed[lead + rest] += p * 0.8
    for name, p in names: mixed[lead + name] += p * mass * 0.2
    return sorted(mixed.items(), key=lambda x: (-x[1], x[0]))


def _dist(a, b):
    """Damerau (optimal string alignment) distance: a swap of two letters counts as one."""
    d = [[i + j if i * j == 0 else 0 for j in range(len(b) + 1)] for i in range(len(a) + 1)]
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] != b[j - 1]))
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]: d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[-1][-1]


class One:
    """A table that saw one word (n times), read like a Counter with one key, in ~50 bytes instead of ~200 (engine
    memory round, 2026-11-17: 284k of the 345k two-word tables and most spellings hold one word). Words.add turns it
    back into a Counter when a second word comes."""
    __slots__ = ("w", "n")

    def __init__(self, w, n): self.w, self.n = w, n
    def items(self): return ((self.w, self.n),)
    def values(self): return (self.n,)
    def keys(self): return (self.w,)
    def __iter__(self): return iter((self.w,))
    def __len__(self): return 1
    def __contains__(self, w): return w == self.w
    def __getitem__(self, w): return self.n if w == self.w else 0      # a Counter's 0 for a word it never saw
    def get(self, w, default=None): return self.n if w == self.w else default
    def most_common(self, k=None): return [(self.w, self.n)] if k is None or k >= 1 else []
    def __repr__(self): return f"One({self.w!r}, {self.n})"


def _counter(table, key):
    """table[key] as a Counter that can count (a One becomes a Counter again)."""
    t = table[key]
    if t.__class__ is One: t = table[key] = Counter({t.w: t.n})
    return t


class Words:
    def __init__(self):
        self.lock = threading.Lock()
        self.uni, self.bi, self.tri = Counter(), defaultdict(Counter), defaultdict(Counter)
        self.own = Counter()  # real observations only; dictionary seed weights do not count as usage
        # Knowledge lookups, accumulated once while loading and updated with each new sent line.
        self.own_folded, self.own_prefix = Counter(), Counter()
        self.case = defaultdict(Counter)       # lowercase word -> how he spelled it
        self.inner_case = defaultdict(Counter)  # case observed away from sentence starts
        self.vocab = []

    def add(self, line, rebuild=True):
        with self.lock:
            for sent in re.split(r"[\n.!?]+", line or ""):
                # one string object per word everywhere (engine memory round, 2026-11-17): each table kept the copy
                # from the line that first used it, so a word lived in memory once per table and per word pair
                raw = [intern(w) for w in WORD.findall(sent) if not RUSSIAN.search(w)]
                ws = [intern(w.lower()) for w in raw]
                for k, w in enumerate(ws):
                    if w not in self.uni and rebuild: bisect.insort(self.vocab, w)
                    self.uni[w] += 1; self.own[w] += 1; _counter(self.case, w)[raw[k]] += 1
                    folded = w.casefold()
                    self.own_folded[folded] += 1
                    for end in range(1, len(folded) + 1): self.own_prefix[folded[:end]] += 1
                    if k >= 1:
                        _counter(self.bi, ws[k - 1])[w] += 1
                        _counter(self.inner_case, w)[raw[k]] += 1
                    if k >= 2: _counter(self.tri, (ws[k - 2], ws[k - 1]))[w] += 1

    # Round three (2026-11-13): every source of data/corpus.jsonl (bench/corpus.py) when it is there; on held-out typed
    # lines in AI apps it was right more often and wrong less than the old sources (docs/rounds/2026-11-13-typing.md)
    SOURCES = ("typed", "take", "cc", "codex", "beeper", "vnotes", "fb", "vault", "import")

    def load(self):
        lines = []
        try:
            built = (DATA / "corpus.jsonl").stat().st_mtime
            lines += [r["text"] for r in (json.loads(l) for l in (DATA / "corpus.jsonl").read_text().splitlines() if l.strip())
                      if r.get("src") in self.SOURCES]
            files = ("typed.jsonl", "drafts.jsonl") if not lines else ("drafts.jsonl",)
            if lines:   # what he sent after the corpus was built (as memory.from_corpus); /typed adds the rest live
                try: lines += [r["text"] for r in (json.loads(l) for l in (DATA / "typed.jsonl").read_text().splitlines() if l.strip())
                               if (r.get("t") or 0) > built]
                except Exception: pass
        except Exception:
            files = ("typed.jsonl", "drafts.jsonl")
        if not lines:
            try: lines += [json.loads(l)["text"] for l in (DATA / "phrases.jsonl").read_text().splitlines() if l.strip()]
            except Exception: pass
        for f in files:
            try: lines += [json.loads(l)["text"] for l in (DATA / f).read_text().splitlines() if l.strip()]
            except Exception: pass
        lines = [l for l in lines if not RUSSIAN.search(l)]
        for l in lines: self.add(l, rebuild=False)
        try:
            for w in json.loads((ROOT / "data/words.json").read_text()).get("words", []):
                t = w["text"] if isinstance(w, dict) else w
                if t and " " not in t and len(t) >= 2:
                    self.uni[t.lower()] += 2; _counter(self.case, t.lower())[t] += 5
                    _counter(self.inner_case, t.lower())[t] += 5
        except Exception: pass
        self.vocab = sorted(self.uni)
        self.compact()
        return len(lines)

    def compact(self):
        """Tables holding one word become One (same answers, a quarter of the memory). -> how many."""
        n = 0
        with self.lock:
            for table in (self.tri, self.bi, self.case, self.inner_case):
                for key, t in table.items():
                    if t.__class__ is Counter and len(t) == 1:
                        (w, c), = t.items()
                        table[key] = One(w, c); n += 1
        return n

    def export(self, path, min_count=3):
        """His words (3+ times: a typo in a left draft and the sent line would be 2) for the app's autocorrect and layout fix: data/mywords.txt, one per line."""
        with self.lock:
            ws = sorted(w for w, n in self.uni.items() if n >= min_count and len(w) >= 2)
            counts = {w: n for w, n in self.own.items() if n >= 5}
        # whole file or nothing: the app reads it every minute, and a half-written file made it forget his words
        path = Path(path)
        tmp = Path(str(path) + ".tmp")
        tmp.write_text("\n".join(ws) + "\n")
        os.replace(tmp, path)
        # Counts for own-word autocorrect ranking; no text/history leaves the Mac.
        tmp_counts = Path(str(path.with_name("myword-counts.json")) + ".tmp")
        tmp_counts.write_text(json.dumps(counts, ensure_ascii=False))
        os.replace(tmp_counts, path.with_name("myword-counts.json"))
        return len(ws)

    def _with_prefix(self, pre):
        i = bisect.bisect_left(self.vocab, pre)
        while i < len(self.vocab) and self.vocab[i].startswith(pre):
            if len(self.vocab[i]) > len(pre): yield self.vocab[i]
            i += 1

    def finish(self, before, min_count=2, min_share=0.6, min_prefix=1):
        """-> the rest of the word being typed, or ''."""
        line = before.split("\n")[-1]
        m = re.search(r"[\w'’-]+$", line)
        if not m: return ""
        typed = m.group(0)
        if len(typed) < min_prefix or RUSSIAN.search(typed): return ""
        pre = typed.lower()
        prev = [w.lower() for w in WORD.findall(re.split(r"[.!?]", line[: m.start()])[-1])]
        with self.lock:
            tables = [t for t in ((self.tri.get(tuple(prev[-2:])) if len(prev) >= 2 else None),
                                  (self.bi.get(prev[-1]) if prev else None)) if t] + [None]
            for table in tables:   # two words before, one word before, then the word alone
                if table is None:
                    c = Counter({w: self.uni[w] for w in self._with_prefix(pre)})
                    total = sum(c.values()) + self.uni.get(pre, 0)
                else:
                    c = Counter({w: n for w, n in table.items() if w.startswith(pre) and len(w) > len(pre)})
                    total = sum(n for w, n in table.items() if w.startswith(pre))
                if not c: continue
                w, n = c.most_common(1)[0]
                if n >= min_count and n / max(1, total) >= min_share:
                    return self._spell(typed, w)
                if table is not None and sum(c.values()) >= min_count: return ""   # the context knows, but it is unclear
        return ""

    def candidate(self, before):
        """The word being typed as his writing would finish it, with what the word gate reads (round four, 2026-11-14):
        -> {"rest", "level" (2 two words before, 1 one, 0 the word alone), "n" (times seen), "share", "second" (share of
        the runner-up), "total", "prefix" (letters typed)} or None. The same tables and order as finish(), no bars."""
        line = before.split("\n")[-1]
        m = re.search(r"[\w'’-]+$", line)
        if not m: return None
        typed = m.group(0)
        if RUSSIAN.search(typed): return None
        pre = typed.lower()
        prev = [w.lower() for w in WORD.findall(re.split(r"[.!?]", line[: m.start()])[-1])]
        with self.lock:
            levels = [(2, self.tri.get(tuple(prev[-2:])) if len(prev) >= 2 else None), (1, self.bi.get(prev[-1]) if prev else None), (0, None)]
            for level, table in levels:
                if level and not table: continue
                if table is None:
                    c = Counter({w: self.uni[w] for w in self._with_prefix(pre)})
                    total = sum(c.values()) + self.uni.get(pre, 0)
                else:
                    c = Counter({w: n for w, n in table.items() if w.startswith(pre) and len(w) > len(pre)})
                    total = sum(n for w, n in table.items() if w.startswith(pre))
                if not c: continue
                (w, n), *rest = c.most_common(2)
                return {"rest": self._spell(typed, w), "level": level, "n": n, "share": n / max(1, total),
                        "second": (rest[0][1] / max(1, total)) if rest else 0.0, "total": total, "prefix": len(typed)}
        return None

    def _parse(self, before):
        line = before.split("\n")[-1]
        m = re.search(r"[\w'’-]+$", line)
        typed = m.group(0) if m else ""
        prev = [w.lower() for w in WORD.findall(re.split(r"[.!?]", line[: len(line) - len(typed)])[-1])]
        return typed, typed.lower(), prev

    def _cands(self, pre, prev):
        """(words that may come next, the one- and two-word tables) - under self.lock."""
        t1 = self.bi.get(prev[-1]) if prev else None
        t2 = self.tri.get(tuple(prev[-2:])) if len(prev) >= 2 else None
        cand = set()
        for t in (t1, t2):
            if t: cand.update(w for w in t if w.startswith(pre) and w != pre)
        if pre:
            cand.update(sorted(self._with_prefix(pre), key=lambda w: -self.uni[w])[:40])

        return cand, t1, t2

    def _wb(self, cand, t1, t2):
        """Witten-Bell: his words alone, then one word before, then two."""
        n_all = sum(self.uni.values()) or 1
        tables = [(t, sum(t.values()), len(t)) for t in (t1, t2) if t]
        out = {}
        for w in cand:
            p = self.uni[w] / n_all
            for t, n, T in tables:
                p = (t.get(w, 0) + T * p) / (n + T)
            out[w] = p
        return out

    def dist(self, before, k=8):
        """His own next words at the caret (2026-11-01, the word booster), for mixing into the model's guess: Witten-Bell
        from the two words before through one to all his words, kept to words that start with the letters typed (then
        shares among those). -> [(the rest of the word as he spells it, p)], best first. At a word start it needs at
        least one word before it on the line. Bare prefixes are not completions; mid-word shares reserve
        one observation for an unseen completion, so a lone rare word never gets certainty.
        (Weighting the words of the chat on screen higher was tried the same day: no better, bench/people_fresh.py.)"""
        typed, pre, prev = self._parse(before)
        if RUSSIAN.search(pre) or (not pre and not prev): return []
        with self.lock:
            cand, t1, t2 = self._cands(pre, prev)
            if not cand: return []
            all_ps = self._wb(cand | ({pre} if pre in self.uni else set()), t1, t2)
            ps = {w: all_ps[w] for w in cand}
            if pre:   # given the letters typed: shares among the words that start with them
                # Reserve unseen-word evidence instead of making a singleton a certainty. Include the
                # bare prefix in the denominator: it competes with extensions but is never boosted.
                z = sum(all_ps.values()) or 1
                support = sum(self.uni[w] for w in cand)
                confidence = support / (support + 1)
                ps = {w: v / z * confidence for w, v in ps.items()}
            out = []
            for w, p in sorted(ps.items(), key=lambda x: -x[1])[:k]:
                forms = self.inner_case[w] if prev else self.case[w]
                spelled = forms.most_common(1)[0][0] if forms else w
                rest = (spelled if spelled.startswith(typed) else w)[len(pre):] if pre else spelled
                if typed and len(typed) > 1 and typed.isupper(): rest = rest.upper()
                out.append((rest, round(p, 4)))
            return out

    def fix(self, before, min_len=4, min_count=5, margin=3):
        """The word being typed, fixed before it ends (2026-11-01, Cursor Tab and Copilot "next edit": a ghost that
        replaces, not only adds). When no word he wrote starts with what he typed, and one word he writes often is a
        letter away (a typo, a missed, extra or swapped letter; the first letter is taken as right) or the same keys in
        the other layout: -> {"old": typed, "new": the fixed word (finished when the finisher is sure), "kind"}.
        None otherwise. The app also asks the Mac's spellchecker and drops it when the word can still be right."""
        line = before.split("\n")[-1]
        m = re.search(r"[\w'’-]+$", line)
        if not m: return None
        typed = m.group(0)
        if len(typed) < min_len or RUSSIAN.search(typed) or any(c.isdigit() or c == "_" for c in typed): return None
        low = typed.lower()
        with self.lock:
            if self.uni.get(low, 0) >= 2 or any(self.uni[w] >= 2 for w in self._with_prefix(low)): return None
            new, kind = "", ""
            # the other layout: ghbd -> прив, руддщ -> hello
            if re.fullmatch(r"[a-z'`]+", low): conv, k = "".join(TO_UK.get(c, c) for c in low), "layout uk"
            elif re.fullmatch(r"[а-яіїєґ'.]+", low): conv, k = "".join(TO_EN.get(c, c) for c in low), "layout en"
            else: conv, k = "", ""
            if conv and (self.uni.get(conv, 0) >= 3 or any(self.uni[w] >= 3 for w in self._with_prefix(conv))):
                new, kind = conv, k
            else:
                # one letter away from the start of a word he writes often
                L, cands = len(low), Counter()
                i = bisect.bisect_left(self.vocab, low[0])
                while i < len(self.vocab) and self.vocab[i].startswith(low[0]):
                    w = self.vocab[i]; i += 1
                    n = self.uni[w]
                    if n < min_count or len(w) < L - 1 or RUSSIAN.search(w): continue
                    for k in (L, L + 1, L - 1):
                        if 2 <= k <= len(w) and abs(len(w[:k]) - L) <= 1 and _dist(low, w[:k]) == 1:
                            cands[w[:k]] += n; break
                if not cands: return None
                top = cands.most_common(2)
                if len(top) > 1 and top[1][1] * margin > top[0][1]: return None
                new, kind = top[0][0], "typo"
                # the letter that made the word unknown may start a word he has not written yet (тред, sqlite, a new
                # ending): wait two more letters, unless the last two are swapped (завтар). 300 of his sent lines,
                # 2026-11-01: 25 words fired on, 14 of them wrong, nearly all on that first unknown letter. Live log
                # 6-13 November (one-letter wait): 405 ghosts, 30 taken, 226 gone at the next letters as the word went
                # another way or he fixed it himself; a typo keeps matching its word, a new word drifts away from it.
                def starts(p): return self.uni.get(p, 0) >= 2 or any(self.uni[w] >= 2 for w in self._with_prefix(p))
                if starts(low[:-1]) or starts(low[:-2]):
                    if not (len(new) == L and new[:-2] == low[:-2] and new[-2:] == low[-1:-3:-1]): return None
        # finished only when he clearly writes one word from there (a wrong ending is worse than a half word)
        rest = self.finish(before[: len(before) - len(typed)] + new, 2, 0.7, 1)
        word = new + rest
        if typed[0].isupper(): word = word[0].upper() + word[1:]
        return {"old": typed, "new": word, "kind": kind}

    def _spell(self, typed, w):
        """The rest of the word as he spells it: a name keeps its form when it fits what he typed."""
        form = self.case[w].most_common(1)[0][0] if self.case.get(w) else w
        if form.startswith(typed): return form[len(typed):]
        rest = w[len(typed):]
        return rest.upper() if typed.isupper() and len(typed) > 1 else rest
