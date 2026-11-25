"""scripts/hide_bad_drafts.py on made-up rows in a temp folder: the shapes, dry run writes nothing, apply and undo,
the stores are never touched; and the rules test in Swift (tests/draft_capture_rules.swift).

    .venv/bin/python -B tests/test_hide_bad_drafts.py
"""
from pathlib import Path
import contextlib, io, json, shutil, subprocess, sys, tempfile, time, unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import hide_bad_drafts as h  # noqa: E402

NAV = ("HomeAboutPricingBlogCareersContact Sign in Log in Subscribe to our newsletter Privacy Terms of use "
       "Cookie settings All rights reserved Example Store Products Solutions Resources Company")


def rows(now):
    d = [
        {"t": now - 3000, "text": NAV, "app": "Dia"},                                                   # A
        {"t": now - 2900, "text": "ord " + "слово " * 400, "app": "Claude"},                           # B (cut)
        {"t": now - 2000, "text": "can we move the call to monday", "app": "Beeper"},                  # C (again below)
        {"t": now - 1990, "text": "can we move the call to monday", "app": "Beeper"},
        {"t": now - 1000, "text": "я думаю що варто перен", "app": "Claude"},                             # D (prefix, cut)
        {"t": now - 900, "text": "я думаю що варто перенести зустріч", "app": "Claude"},
        {"t": now - 100, "text": "a clean draft of three words", "app": "Slack"},
    ]
    s = [{"t": now - 50, "text": "a sent line of my own", "app": "Beeper"}]
    return d, s


def run(*args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = h.main(list(args))
    return code, out.getvalue()


class Hide(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="drafter-hide-"))
        self.now = time.time()
        d, s = rows(self.now)
        (self.dir / "drafts.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in d))
        (self.dir / "typed.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in s))
        self.before = {p.name: p.read_bytes() for p in self.dir.iterdir()}

    def tearDown(self):
        shutil.rmtree(self.dir)

    def test_shapes(self):
        d, s = rows(self.now)
        got = h.classify(h.load(self.dir / "drafts.jsonl", "draft") + h.load(self.dir / "typed.jsonl", "sent"))
        self.assertEqual(got[("draft", d[0]["t"])], {"A"})
        self.assertEqual(got[("draft", d[1]["t"])], {"B"})
        self.assertEqual(got[("draft", d[2]["t"])], {"C"})
        self.assertEqual(got[("draft", d[4]["t"])], {"D"})
        for r in (d[3], d[5], d[6]):
            self.assertNotIn(("draft", r["t"]), got)
        self.assertNotIn(("sent", s[0]["t"]), got)

    def test_dry_run_writes_nothing_and_prints_numbers_only(self):
        code, out = run("--data", str(self.dir))
        self.assertEqual(code, 0)
        self.assertIn("would hide: 2 rows (shapes CD)", out)   # C and D by default; A and B not
        self.assertFalse((self.dir / "drafts-hidden.json").exists())
        for word in ("monday", "зустріч", "Pricing", "слово"):
            self.assertNotIn(word, out)

    def test_apply_undo(self):
        run("--data", str(self.dir), "--apply")
        side = json.loads((self.dir / "drafts-hidden.json").read_text())["hidden"]
        self.assertEqual(sorted(e["shape"] for e in side), ["C", "D"])
        run("--data", str(self.dir), "--apply", "--shapes", "ACD")                     # A after a look by hand
        side = json.loads((self.dir / "drafts-hidden.json").read_text())["hidden"]
        self.assertEqual(len(side), 3)
        self.assertTrue(all(set(e) == {"kind", "t", "shape", "by"} for e in side))   # ids only, no text
        run("--data", str(self.dir), "--apply")                                       # twice: no doubles
        self.assertEqual(len(json.loads((self.dir / "drafts-hidden.json").read_text())["hidden"]), 3)
        # an entry someone else wrote survives the undo
        j = json.loads((self.dir / "drafts-hidden.json").read_text())
        j["hidden"].append({"kind": "draft", "t": 1.0, "by": "hand"})
        (self.dir / "drafts-hidden.json").write_text(json.dumps(j))
        code, out = run("--data", str(self.dir), "--undo")
        self.assertIn("removed 3 entries, 1 left", out)
        # the stores are byte for byte as they were
        for name in ("drafts.jsonl", "typed.jsonl"):
            self.assertEqual((self.dir / name).read_bytes(), self.before[name])

    def test_b_is_never_hidden(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                run("--data", str(self.dir), "--apply", "--shapes", "BCD")
        self.assertFalse((self.dir / "drafts-hidden.json").exists())

    def test_history_reads_the_sidecar(self):
        src = (ROOT / "app/History.swift").read_text()
        self.assertIn('appendingPathComponent("drafts-hidden.json")', src)
        self.assertIn("DraftHide.drop(rows", src)

    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler required")
    def test_swift_rules(self):
        with tempfile.TemporaryDirectory(prefix="drafter-rules-") as d:
            b = subprocess.run(["swiftc", "-module-cache-path", str(Path(d) / "cache"), "-parse-as-library",
                                str(ROOT / "app/DraftCaptureRules.swift"), str(ROOT / "tests/draft_capture_rules.swift"),
                                "-o", str(Path(d) / "check")], capture_output=True, text=True, timeout=300)
            self.assertEqual(b.returncode, 0, b.stderr[-2000:])
            r = subprocess.run([str(Path(d) / "check")], capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
