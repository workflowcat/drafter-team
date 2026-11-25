"""The public docs stay true: every doc link in README.md resolves, every file path a public doc names exists, and the
privacy page's table of features that can send text matches engine/cloud.py (scripts/cloud_table.py).

    .venv/bin/python -B tests/test_public_docs.py
"""
import re, sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import cloud_table, public_files

PAGES = sorted(public_files.PUBLIC_DOCS)
LINK = re.compile(r"\]\(([^)#\s]+)(?:#[^)]*)?\)")
# a path in backticks: has a slash or a known extension; placeholders (<name>, *, ...) and data/ (made at run time) skip
CODE = re.compile(r"`([^`\s]+)`")
EXT = re.compile(r"\.(py|swift|sh|md|json|txt|plist|html)$")


def named_paths(text):
    for m in CODE.finditer(text):
        p = m.group(1).rstrip(".,:;")
        if not ("/" in p or EXT.search(p)) or re.search(r"[<>*{}$]|\.\.\.|^https?:|^~|^/|^-", p): continue
        if p.startswith(("data/", ".worktrees/", "127.0.0.1")) or p.count(".") > 3: continue
        if "/" not in p and not re.search(r"\.(py|swift|sh)$", p): continue   # brief.md, transcript.txt: files a run writes
        yield p


class Docs(unittest.TestCase):
    def test_every_public_page_exists(self):
        for p in PAGES: self.assertTrue((ROOT / p).is_file(), p)

    def test_readme_links_resolve(self):
        readme = (ROOT / "README.md").read_text()
        links = [l for l in LINK.findall(readme) if not l.startswith(("http:", "https:", "mailto:"))]
        self.assertTrue(any(l.startswith("docs/") for l in links))
        for l in links: self.assertTrue((ROOT / l).exists(), l)
        for p in PAGES: self.assertIn(p, links, f"README does not link {p}")

    def test_paths_named_in_docs_exist(self):
        missing = []
        for page in ["README.md"] + PAGES:
            text = (ROOT / page).read_text()
            for p in named_paths(text):
                if not ((ROOT / p).exists() or (ROOT / page).parent.joinpath(p).exists()):
                    missing.append(f"{page}: {p}")
            for l in LINK.findall(text):
                if not l.startswith(("http:", "https:", "mailto:")) and not (ROOT / page).parent.joinpath(l).exists():
                    missing.append(f"{page}: link {l}")
        self.assertEqual(missing, [])

    def test_privacy_table_matches_cloud(self):
        text = (ROOT / "docs/privacy.md").read_text()
        a, b = text.index(cloud_table.START) + len(cloud_table.START), text.index(cloud_table.END)
        self.assertEqual(text[a:b].strip(), cloud_table.table(), "run: python3 scripts/cloud_table.py --write")
        self.assertEqual(set(cloud_table.WHAT), set(cloud_table.cloud.OWNERS))


if __name__ == "__main__":
    unittest.main()
