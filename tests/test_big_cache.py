"""Big-model round (2026-11-15): the copy after the screen text and the head cache file, with fake caches and a fake
model (no weights loaded). Made-up text only.

    .venv/bin/python -B tests/test_big_cache.py
"""
import os, sys, tempfile, types, unittest
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
os.environ.setdefault("DRAFTER_CAP_GB", "1.0")
import mlx.core as mx
import model as M
import prompt as P


class Layer:
    """A cache layer that only remembers the tokens read into it; cannot be cut back (like Gemma's or Qwen3.5's)."""
    def __init__(self): self.toks = []

    @property
    def offset(self): return len(self.toks)

    @property
    def state(self): return mx.array(self.toks or [0])


class FakeNet:
    """Reads tokens into each layer and counts how many it read."""
    def __init__(self): self.read = 0

    def __call__(self, x, cache=None):
        ids = x.tolist()[0]
        self.read += len(ids)
        for c in cache: c.toks += ids
        return mx.zeros((1, len(ids), 4))


def stand_in(trim=False):
    m = M.Model.__new__(M.Model)
    m.model, m.cache, m.ids, m.rebuilds = FakeNet(), None, [], 0
    m.snapshot, m.marks, m.screen, m.mark_hits = None, OrderedDict(), None, 0
    m.swaps = 0
    m.parked, m.dist, m.tw, m.head_file, m.repo, m.adapter = OrderedDict(), None, None, None, "fake/repo", None
    return m


def fake_generate(prompt, model, max_tokens=0, prompt_cache=None, **kw):
    """the head prefill of Model._warm: read the prompt, make nothing"""
    model(prompt[None], cache=prompt_cache)
    return iter(())


class Patched:
    def __init__(self, trim=False, head_dir=None):
        self.trim, self.head_dir, self.old = trim, head_dir, {}

    def __enter__(self):
        new = dict(make_prompt_cache=lambda model: [Layer(), Layer()], can_trim_prompt_cache=lambda c: self.trim,
                   trim_prompt_cache=lambda c, n: n, HEAD_CACHE=self.head_dir or "", generate_step=fake_generate)
        for k, v in new.items(): self.old[k] = getattr(M, k); setattr(M, k, v)
        return self

    def __exit__(self, *a):
        for k, v in self.old.items(): setattr(M, k, v)


def warm(m, head):
    """The head read and the copy after it, as Model._warm makes for a cache that cannot be cut back."""
    m.cache = M.make_prompt_cache(None)
    m._read(head)
    m.ids = list(head)
    m.snapshot = (M.copy.deepcopy(m.cache), list(head))


class CharTok:
    """One token per character, except "\\n\\n" which is one token (so a boundary can join)."""
    def encode(self, s, add_special_tokens=False):
        out, i = [], 0
        while i < len(s):
            if s[i:i + 2] == "\n\n": out.append(-10); i += 2
            else: out.append(ord(s[i])); i += 1
        return out


class StableIds(unittest.TestCase):
    def builder(self):
        tok = CharTok()
        m = types.SimpleNamespace(encode=tok.encode, bos=lambda: [])
        P.head = lambda n_examples=12, n_words=40: "made-up head\n###\n"
        return P.Builder(m, "raw")

    def test_ids_unchanged_and_stable_ends_after_screen_text(self):
        b = self.builder()
        ids, heal = b.ids("Hello there fri", app="Beeper", context="We met at noon.")
        ids2, heal2, stable = b.ids_stable("Hello there fri", app="Beeper", context="We met at noon.")
        self.assertEqual((ids, heal), (ids2, heal2))
        s = P.tail("", "Beeper", "", "We met at noon.")
        self.assertEqual(stable, len(b.head_ids) + len(s) - 1)
        # the same stable part at every key of this screen
        for typed in ("H", "Hello", "Hello there", "Hello there friend, see"):
            i, _, st = b.ids_stable(typed, app="Beeper", context="We met at noon.")
            self.assertEqual(i[:st], ids[:stable])
            self.assertLess(st, len(i))

    def test_joined_token_is_not_split(self):
        b = self.builder()
        # the stable text ends in "\n"; a line starting with "\n" joins it into one "\n\n" token
        ids, _, stable = b.ids_stable("\nnext line", app="Claude", context="Text above.")
        s_ids = CharTok().encode(P.tail("", "Claude", "", "Text above."))
        self.assertEqual(stable, len(b.head_ids) + len(s_ids) - 2)
        self.assertEqual(ids, b.ids("\nnext line", app="Claude", context="Text above.")[0])

    def test_no_app_no_context_is_the_head(self):
        b = self.builder()
        ids, _, stable = b.ids_stable("just typing")
        self.assertEqual(stable, len(b.head_ids))


class Marks(unittest.TestCase):
    HEAD = list(range(100, 110))
    SCREEN = list(range(200, 240))

    def test_second_key_reads_only_the_typed_line(self):
        with Patched(trim=False):
            m = stand_in(); warm(m, self.HEAD)
            m.model.read = 0
            stable = len(self.HEAD) + len(self.SCREEN)
            ids1 = self.HEAD + self.SCREEN + [1, 2, 3]
            tail = m._feed(ids1, stable)
            self.assertEqual(tail, [1, 2, 3])
            self.assertEqual(m.model.read, len(self.SCREEN))         # the screen text was read once, for the copy
            self.assertEqual(m.cache[0].toks, self.HEAD + self.SCREEN)
            m.cache[0].toks += tail + [77, 78]; m.cache[1].toks += tail + [77, 78]; m.ids = ids1 + [77, 78]
            m.model.read = 0
            ids2 = self.HEAD + self.SCREEN + [1, 2, 3, 4]
            tail = m._feed(ids2, stable)
            self.assertEqual(tail, [1, 2, 3, 4])
            self.assertEqual(m.model.read, 0)                           # nothing read again from the head
            self.assertEqual(m.cache[0].toks, self.HEAD + self.SCREEN)   # the copy, not the speculation
            self.assertEqual(m.mark_hits, 1)
            # the copy itself is untouched by what the key reads next
            m.cache[0].toks += [9]
            self.assertEqual(m.marks[None][0][0].toks, self.HEAD + self.SCREEN)

    def test_new_screen_text_makes_a_new_copy(self):
        with Patched(trim=False):
            m = stand_in(); warm(m, self.HEAD)
            stable = len(self.HEAD) + len(self.SCREEN)
            m._feed(self.HEAD + self.SCREEN + [1], stable); m.ids.append(5)
            other = list(range(300, 330))
            m.model.read = 0
            tail = m._feed(self.HEAD + other + [1], len(self.HEAD) + len(other))
            self.assertEqual(tail, [1])
            self.assertEqual(m.model.read, len(other))                  # from the head copy, not from nothing
            self.assertEqual(m.marks[None][1], self.HEAD + other)

    def test_marks_kept_per_screen_and_capped(self):
        with Patched(trim=False):
            m = stand_in(); warm(m, self.HEAD)
            for k in range(M.MARKS + 2):
                m.screen = f"app · window {k}"
                scr = list(range(1000 * (k + 1), 1000 * (k + 1) + 5))
                m._feed(self.HEAD + scr + [1], len(self.HEAD) + 5); m.ids.append(5)
            self.assertEqual(len(m.marks), M.MARKS)
            self.assertNotIn("app · window 0", m.marks)

    def test_trimmable_cache_ignores_stable(self):
        """The live Qwen3 path: the cache is cut back, no copy is made, the tail is what it was without stable."""
        with Patched(trim=True):
            m = stand_in(); m.cache = M.make_prompt_cache(None); m._read(self.HEAD); m.ids = list(self.HEAD)
            ids = self.HEAD + self.SCREEN + [1, 2]
            a = m._feed(list(ids), len(self.HEAD) + len(self.SCREEN))
            self.assertEqual(a, self.SCREEN + [1, 2])
            self.assertEqual(len(m.marks), 0)
            m2 = stand_in(); m2.cache = M.make_prompt_cache(None); m2._read(self.HEAD); m2.ids = list(self.HEAD)
            self.assertEqual(m2._feed(list(ids)), a)

    def test_no_stable_is_the_old_way(self):
        with Patched(trim=False):
            m = stand_in(); warm(m, self.HEAD)
            m.ids = self.HEAD + [5, 6]; m.cache[0].toks += [5, 6]
            tail = m._feed(self.HEAD + self.SCREEN + [1])
            self.assertEqual(tail, self.SCREEN + [1])
            self.assertEqual(len(m.marks), 0)

    def test_switch_keeps_marks_and_warm_clears_them(self):
        with Patched(trim=False):
            m = stand_in(); warm(m, self.HEAD)
            m.screen = "a"
            m._feed(self.HEAD + self.SCREEN + [1], len(self.HEAD) + len(self.SCREEN))
            m._switch("b")
            self.assertIn("a", m.marks)
            m._switch("a")
            self.assertIn("a", m.marks)
            m.head_ids = self.HEAD
            m._warm(self.HEAD)
            self.assertEqual(len(m.marks), 0)


class HeadFile(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.saved = {}

        def save(path, cache, meta):
            Path(path).write_text("x"); self.saved[Path(path).name] = ([list(c.toks) for c in cache], dict(meta))

        def load(path, return_metadata=False):
            toks, meta = self.saved[Path(path).name]
            cache = []
            for t in toks:
                l = Layer(); l.toks = list(t); cache.append(l)
            return (cache, meta) if return_metadata else cache
        self.io = dict(save_prompt_cache=save, load_prompt_cache=load)
        self.old = {k: getattr(M, k) for k in self.io}
        for k, v in self.io.items(): setattr(M, k, v)

    def tearDown(self):
        for k, v in self.old.items(): setattr(M, k, v)
        self.dir.cleanup()

    def renamed(self):
        """the saved file under its final name (the save wrote a .tmp file then moved it)"""
        for k in list(self.saved):
            if ".tmp." in k: self.saved[k.replace(".tmp.", ".")] = self.saved.pop(k)

    def test_made_then_read_same_cache(self):
        head = list(range(50, 70))
        with Patched(trim=True, head_dir=self.dir.name):
            m = stand_in(); m._warm(head)
            self.assertEqual(m.head_file, "made")
            self.renamed()
            made = [list(c.toks) for c in m.cache]
            m2 = stand_in(); m2.model.read = 0; m2._warm(head)
            self.assertEqual(m2.head_file, "read")
            self.assertEqual(m2.model.read, 0)
            self.assertEqual([list(c.toks) for c in m2.cache], made)
            self.assertEqual(m2.ids, head)

    def test_other_head_or_layer_is_not_read(self):
        head = list(range(50, 70))
        with Patched(trim=True, head_dir=self.dir.name):
            m = stand_in(); m._warm(head); self.renamed()
            m2 = stand_in(); m2._warm(head + [71])
            self.assertEqual(m2.head_file, "made")                      # another head: another key, prefilled
            m3 = stand_in(); m3.repo = "fake/other"; m3._warm(head)
            self.assertEqual(m3.head_file, "made")

    def test_broken_or_stale_file_falls_back(self):
        head = list(range(50, 70))
        with Patched(trim=True, head_dir=self.dir.name):
            m = stand_in(); m._warm(head); self.renamed()
            name = next(iter(self.saved))
            toks, meta = self.saved[name]
            self.saved[name] = (toks, dict(meta, key="stale"))
            m2 = stand_in(); m2._warm(head)
            self.assertNotEqual(m2.head_file, "read")
            self.assertEqual(m2.cache[0].toks, head)
            self.saved.clear()                                          # file there, load raises
            Path(self.dir.name, name).write_text("broken")
            m3 = stand_in(); m3._warm(head)
            self.assertEqual(m3.cache[0].toks, head)

    def test_off_when_empty(self):
        with Patched(trim=True, head_dir=""):
            m = stand_in(); m._warm(list(range(5)))
            self.assertIsNone(m.head_file)
            self.assertEqual(self.saved, {})


if __name__ == "__main__":
    unittest.main()
