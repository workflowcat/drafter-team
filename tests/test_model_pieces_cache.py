"""Disk cache for Model.pieces(): cold build writes atomically, warm load skips token decoding,
fingerprint invalidates on tokenizer change, and corrupt cache falls back cleanly.

Run: .venv/bin/python -B tests/test_model_pieces_cache.py
"""
import ast, hashlib, json, os, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def lift_pieces():
    src = (ROOT / "engine/model.py").read_text()
    tree = ast.parse(src)
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "Model")
    methods = {n.name: n for n in cls.body if isinstance(n, ast.FunctionDef)}
    ns = {"hashlib": hashlib, "json": json, "os": os, "tempfile": tempfile, "Path": Path, "HEAD_CACHE": ""}
    for name in ("_pieces_cache_path", "pieces"):
        mod = ast.Module(body=[methods[name]], type_ignores=[])
        exec(compile(mod, "engine/model.py", "exec"), ns)
    return ns["_pieces_cache_path"], ns["pieces"]


_pieces_cache_path, pieces_fn = lift_pieces()


class FakeTok:
    def __init__(self, vocab):
        self._tokenizer = list(vocab)
        self.vocab_size = len(vocab)
        self.decode_calls = 0

    def decode(self, ids):
        self.decode_calls += 1
        return self._tokenizer[ids[0]]


class FakeModel:
    _pieces_cache_path = _pieces_cache_path
    pieces = pieces_fn

    def __init__(self, repo, vocab, cache_dir):
        self.repo = repo
        self.tok = FakeTok(vocab)
        self.pieces_cache_dir = cache_dir


class PiecesCacheTests(unittest.TestCase):
    def test_cold_build_writes_cache_and_warm_load_skips_full_decode(self):
        vocab = ["hello", " world", "привіт", "\ufffd", "help", "", "123", "alpha"]
        with tempfile.TemporaryDirectory() as tmp:
            m1 = FakeModel("sample/model-3b", vocab, tmp)
            p1 = m1.pieces()
            self.assertEqual(m1.pieces_file, "made")
            self.assertEqual(p1["h"], [(0, "hello"), (4, "help")])
            self.assertEqual(p1["п"], [(2, "привіт")])
            self.assertNotIn("\ufffd", p1)
            # Cold pass decoded all tokens (plus probe tokens)
            self.assertGreaterEqual(m1.tok.decode_calls, len(vocab))

            # Second fresh model instance loads from disk without decoding all tokens
            m2 = FakeModel("sample/model-3b", vocab, tmp)
            p2 = m2.pieces()
            self.assertEqual(m2.pieces_file, "read")
            self.assertEqual(p2, p1)
            # Only fingerprint probes decoded (<= 6), never full vocab loop
            self.assertLessEqual(m2.tok.decode_calls, 6)

    def test_invalidates_on_vocab_or_repo_change(self):
        vocab_a = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
        vocab_b = ["a", "b", "c", "d", "e", "X", "g", "h", "i", "j"]
        with tempfile.TemporaryDirectory() as tmp:
            m1 = FakeModel("sample/model-a", vocab_a, tmp)
            p1 = m1.pieces()
            self.assertEqual(m1.pieces_file, "made")

            m2 = FakeModel("sample/model-a", vocab_b, tmp)
            p2 = m2.pieces()
            self.assertEqual(m2.pieces_file, "made")
            self.assertNotEqual(p1, p2)
            self.assertIn("X", p2)

            m3 = FakeModel("sample/model-b", vocab_a, tmp)
            p3 = m3.pieces()
            self.assertEqual(m3.pieces_file, "made")
            self.assertEqual(p3, p1)

    def test_corrupt_cache_file_falls_back_and_rewrites(self):
        vocab = ["foo", "bar", "baz"]
        with tempfile.TemporaryDirectory() as tmp:
            m1 = FakeModel("sample/model", vocab, tmp)
            m1.pieces()
            files = list(Path(tmp).glob("pieces-*.json"))
            self.assertEqual(len(files), 1)
            files[0].write_text("{corrupt json", encoding="utf-8")

            m2 = FakeModel("sample/model", vocab, tmp)
            p2 = m2.pieces()
            self.assertEqual(m2.pieces_file, "made")
            self.assertEqual(p2["b"], [(1, "bar"), (2, "baz")])

    def test_disabled_cache_dir_builds_in_memory_only(self):
        m = FakeModel("sample/model", ["hi", "there"], "")
        p = m.pieces()
        self.assertIsNone(m.pieces_file)
        self.assertEqual(p["h"], [(0, "hi")])


if __name__ == "__main__":
    unittest.main()
