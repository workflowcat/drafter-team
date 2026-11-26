"""Nothing private in the tracked files (scripts/public_files.py): no home folder path, no real email address, and
no name from your own deny-list. The deny-list is an untracked local file, so the list itself never goes into git:
$DRAFTER_DENY, else data/public-deny.txt in this checkout or in the main checkout of a worktree. One entry per line,
# for comments; matched as whole words, case-insensitive. Without a list that check is skipped.

    .venv/bin/python -B tests/test_no_private.py
"""
import os, re, subprocess, sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import public_files

HOME_PATH = re.compile(r"(?<![\w$}.])/(?:Users|home)/(?!Shared\b|runner\b)[A-Za-z][\w.-]*")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)")
# made-up domains used by tests and previews; anthropic.com only for the commit trailer address
SAFE_DOMAINS = re.compile(r"^(example\.(com|net|org|test)|[\w-]+\.example(\.\w+)?|x\.ua|x\.y|users\.noreply\.github\.com|anthropic\.com)$", re.I)
SAFE_EMAILS = {"noreply@anthropic.com"}
BINARY = re.compile(r"\.(png|jpg|jpeg|gif|icns|woff2?|ttf|otf|gz|zip|wav|pcm)$", re.I)


def texts(root=ROOT):
    for src in public_files.files(root):
        if BINARY.search(src): continue
        try: yield src, (root / src).read_text(errors="ignore")
        except (OSError, UnicodeDecodeError): continue


def deny_file():
    if os.environ.get("DRAFTER_DENY"): return Path(os.environ["DRAFTER_DENY"])
    own = ROOT / "data/public-deny.txt"
    if own.exists(): return own
    try:
        common = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True).stdout.strip()
        main = Path(common).parent / "data/public-deny.txt"
        return main if main.exists() else None
    except Exception:
        return None


def deny_words(path):
    return [l.strip() for l in path.read_text().splitlines() if l.strip() and not l.lstrip().startswith("#")]


def hits(pattern_for_line, root=ROOT, skip=()):
    out = []
    for src, text in texts(root):
        if src in skip: continue
        for i, line in enumerate(text.splitlines(), 1):
            for m in pattern_for_line(line):
                out.append(f"{src}:{i}: {m}")
    return out


class NoPrivate(unittest.TestCase):
    def test_no_home_paths(self):
        found = hits(lambda l: HOME_PATH.findall(l))
        self.assertEqual(found, [], "home folder paths in tracked files:\n" + "\n".join(found[:30]))

    def test_no_real_email_addresses(self):
        found = hits(lambda l: [m.group(0) for m in EMAIL.finditer(l)
                                if m.group(0).lower() not in SAFE_EMAILS and not SAFE_DOMAINS.match(m.group(1))])
        self.assertEqual(found, [], "email addresses in tracked files:\n" + "\n".join(found[:30]))

    def test_no_name_from_the_deny_list(self):
        path = deny_file()
        if path is None: self.skipTest("no deny-list (set DRAFTER_DENY or put data/public-deny.txt in place)")
        words = deny_words(path)
        if not words: self.skipTest("the deny-list is empty")
        rx = re.compile(r"(?<![\w])(" + "|".join(re.escape(w) for w in sorted(words, key=len, reverse=True)) + r")(?![\w])", re.I)
        found = hits(lambda l: rx.findall(l), skip=public_files.NAME_TABLES)
        # the report names the file and line only, never the list itself in bulk
        self.assertEqual(found, [], f"{len(found)} deny-list hits in tracked files:\n" + "\n".join(found[:30]))


if __name__ == "__main__":
    unittest.main()
