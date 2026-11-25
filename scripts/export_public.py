"""Make the public copy of Drafter in a new folder (open-source round, 2026-11-14). scripts/export-public.sh calls this.

    scripts/export-public.sh <empty-or-new-folder> [--commit "Name <email>"]

1. Copies the committed tree (HEAD, never uncommitted edits) minus what scripts/public_files.py leaves out: docs other
   than the eight public pages, the owner's AGENTS.md (AGENTS.public.md takes its name), .claude/ except the agent
   roles, worktrees.
2. Scans every copied text file: the owner's deny-list (required: $DRAFTER_DENY or data/public-deny.txt), home folder
   paths, email addresses, the private hosts (the deny-list's entries with a dot, so no host is named in this
   public file), and the Aleph port on any line that does not name the optional Aleph
   integration. Any hit fails loudly with the file and line, never the list itself.
3. `git init -b main` in the copy and stages everything, then runs tests/test_no_private.py and every test file there.
4. With --commit, makes the one commit with that author and the Claude co-author line. No remote, no push.
"""
import argparse, os, re, shutil, subprocess, sys, tarfile, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))
import public_files
import test_no_private as nopriv

ALEPH_PORT = re.compile(r"8797")
MESSAGE = """Drafter: an offline writing helper for macOS

Grey ghost text at the caret in any app from a small model on this Mac, voice on Right Option, call and long-note
recording, and a personal layer trained on your own writing. Local by default; a cloud model only when you connect one.

Co-Authored-By: Claude <noreply@anthropic.com>
"""


def die(msg):
    print(f"export-public: FAILED: {msg}", file=sys.stderr)
    sys.exit(1)


def copy_tree(target):
    """HEAD's files that public_files keeps, under their public names."""
    keep = public_files.files(ROOT)
    with tempfile.TemporaryDirectory() as tmp:
        tar = Path(tmp) / "head.tar"
        subprocess.run(["git", "-C", str(ROOT), "archive", "--format=tar", "-o", str(tar), "HEAD"], check=True)
        with tarfile.open(tar) as t: t.extractall(Path(tmp) / "head", filter="data")
        head = Path(tmp) / "head"
        n = 0
        for src, dst in keep:
            s = head / src
            if not s.exists() and not s.is_symlink(): continue      # tracked but not committed yet: left out
            d = target / dst
            d.parent.mkdir(parents=True, exist_ok=True)
            if s.is_symlink(): os.symlink(os.readlink(s), d)
            else: shutil.copy2(s, d)
            n += 1
    return n


def scan(target):
    deny = nopriv.deny_file()
    if deny is None or not deny.exists():
        die("no deny-list: set DRAFTER_DENY or put data/public-deny.txt in place (one name per line)")
    words = nopriv.deny_words(deny)
    if not words: die("the deny-list is empty")
    rx = re.compile(r"(?<![\w])(" + "|".join(re.escape(w) for w in sorted(words, key=len, reverse=True)) + r")(?![\w])", re.I)
    hosts = [w for w in words if "." in w and " " not in w]
    if not hosts: die("the deny-list names no private host (an entry with a dot, like a domain)")
    hrx = re.compile("|".join(re.escape(h) for h in hosts), re.I)
    found = {"deny-list name": [], "home path": [], "email": [], "private host": [], "Aleph port outside Aleph": []}
    for f in sorted(p for p in target.rglob("*") if p.is_file() and ".git" not in p.relative_to(target).parts):
        rel = f.relative_to(target)
        names_ok = str(rel) in public_files.NAME_TABLES
        if nopriv.BINARY.search(f.name):
            data = f.read_bytes().decode("latin-1")
            if rx.search(data) or nopriv.HOME_PATH.search(data): found["deny-list name"].append(f"{rel} (binary)")
            continue
        try: text = f.read_text()
        except UnicodeDecodeError: die(f"{rel}: not text and not a known binary type")
        for i, line in enumerate(text.splitlines(), 1):
            at = f"{rel}:{i}"
            if rx.search(line) and not names_ok: found["deny-list name"].append(at)
            if nopriv.HOME_PATH.search(line): found["home path"].append(at)
            for m in nopriv.EMAIL.finditer(line):
                if m.group(0).lower() not in nopriv.SAFE_EMAILS and not nopriv.SAFE_DOMAINS.match(m.group(1)):
                    found["email"].append(at)
            if hrx.search(line): found["private host"].append(at)
            if ALEPH_PORT.search(line) and "aleph" not in line.lower(): found["Aleph port outside Aleph"].append(at)
    bad = {k: v for k, v in found.items() if v}
    if bad:
        for k, v in bad.items():
            print(f"  {k}: {len(v)}", file=sys.stderr)
            for at in v[:20]: print(f"    {at}", file=sys.stderr)
        die("private text in the copy (above); fix it in the private repo and export again")
    return len(words), len(hosts)


def run(cmd, cwd, **kw):
    r = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, **kw)
    if r.returncode: die(f"{' '.join(map(str, cmd))}\n{r.stdout[-3000:]}{r.stderr[-3000:]}")
    return r.stdout


def main():
    ap = argparse.ArgumentParser(description="Make the public copy of Drafter in a new folder.")
    ap.add_argument("target", type=Path)
    ap.add_argument("--commit", metavar="AUTHOR", help='"Name <email>": make the one commit with this author')
    a = ap.parse_args()
    target = a.target.expanduser().resolve()
    if target == ROOT or ROOT in target.parents: die("the target must be outside this checkout")
    if target.exists() and any(target.iterdir()): die(f"{target} exists and is not empty")
    target.mkdir(parents=True, exist_ok=True)

    n = copy_tree(target)
    print(f"copied {n} files into {target}")
    words, hosts = scan(target)
    print(f"scan: clean (deny-list of {words} entries, {hosts} of them hosts; home paths, emails, the Aleph port)")

    run(["git", "init", "-q", "-b", "main"], target)
    run(["git", "add", "-A"], target)
    py = sys.executable
    env = {**os.environ, "DRAFTER_DENY": str(nopriv.deny_file())}
    run([py, "-B", "tests/test_no_private.py"], target, env=env)
    out = run(["zsh", "scripts/run_tests.sh", py], target, env=env, timeout=1800)
    print(out.strip().splitlines()[-1])

    if a.commit:
        m = re.fullmatch(r"\s*(.+?)\s*<([^>]+)>\s*", a.commit)
        if not m: die('--commit takes "Name <email>"')
        name, email = m.groups()
        cenv = {**os.environ, "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
                "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email}
        run(["git", "-c", "commit.gpgsign=false", "commit", "-q", "-F", "-"], target, env=cenv, input=MESSAGE)
        print(run(["git", "log", "--format=%h %an <%ae> %s", "-1"], target).strip())
    size = sum(p.stat().st_size for p in target.rglob("*") if p.is_file() and ".git" not in p.relative_to(target).parts)
    print(f"done: {n} files, {size / 1e6:.1f} MB, branch main, no remote")


if __name__ == "__main__":
    main()
