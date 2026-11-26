"""The user's writing as one dated corpus (round three, 2026-11-13; the user: "whatever gets us to better speed and accuracy").
Local only: reads files on this Mac, writes data/corpus.jsonl and data/corpus-counts.json (data/ is never in git).

    .venv/bin/python bench/corpus.py            # build, print counts per source
    .venv/bin/python bench/corpus.py --dry-run  # counts only

Sources, in the order that wins a duplicate (the same line sent, dictated and kept in a session file counts once):
  typed    data/typed.jsonl: what the user sent with Return while Drafter was on (dictated when it matches a take)
  take     data/takes.jsonl: their voice takes, the cleaned text (never `raw`), empty ones dropped
  cc       the user's own prompts in Claude Code sessions (~/.claude/projects/*/*.jsonl, top level only: no subagents)
  codex    their own messages in Codex sessions (~/.codex/sessions/**/*.jsonl)
  beeper   messages the user sent: data/my-messages.json and data/beeper-sent.jsonl (their side only, kept up to date from the
           local Beeper app, read-only, by `beeper_sync`; lines signed "Claude:" are an agent's and stay out)
  vault    notes the user wrote themselves in the vault (frontmatter `origin: kit` only: agent text would teach an agent's voice),
           split into paragraphs; never .obsidian, .claude, System/old, nor any people/private or Entities/Private
           scope (AGENTS.md: never read people/private). Read only.
  fb       the user's Facebook posts (the vault's raw archive), split into paragraphs
  import   anyone's own writing, brought in by hand (team round, 25 November 2026): data/import/*.jsonl (one
           {"text", "t", "app"} per line; only "text" is needed), *.txt and *.md split into paragraphs, plus every
           folder in the config's corpus.folders (.md and .txt, read only). Only your own words belong there.
Not used: the clipboard as text the user wrote (it only filters out pastes), anything from the network. The vault has no
chat exports with the user's side (checked 2026-11-14); their chats come from Beeper.

Each row: {"src", "t" (unix seconds, 0 when unknown), "app", "text", "dictated"}. A prompt or typed line that matches
a take is marked dictated (typed vs dictated is not recorded in the session files). Who reads it: bench/make_train.py
(training lines, weighted per source), engine/memory.py (phrase memory) and engine/words.py (word finisher)."""
import argparse, glob, json, os, re, sys, time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = Path(os.environ.get("DRAFTER_SRC_DATA") or DATA)   # where the user's files are read from (a worktree points it at the live data/)
HOME = Path.home()
OUT = DATA / "corpus.jsonl"
COUNTS = DATA / "corpus-counts.json"
ORDER = ("typed", "take", "cc", "codex", "beeper", "vault", "fb", "import")
sys.path.insert(0, str(ROOT / "engine"))
import local, integrations
# Each source is opt-in (open-source round, 2026-11-14): typed lines and takes by default; Claude Code and Codex sessions
# when the local config's `corpus` says so; Beeper and the vault when their integration is on; Facebook
# when social.facebook_archive names the export. sources() says which; --sources prints it.
VAULT = Path(os.environ.get("DRAFTER_VAULT") or local.setting("vault", "path") or "/nonexistent/vault")
ORIGIN = local.setting("vault", "origin") or ""     # frontmatter `origin:` of notes the user wrote themselves
VAULT_SKIP = re.compile(r"(^|/)(\.obsidian|\.claude|\.git|\.trash)(/|$)|^System/old(/|$)|(^|/)people/private(/|$)|^Entities/Private(/|$)", re.I)
FB = Path(local.expand(local.config()["social"].get("facebook_archive") or "") or "/nonexistent/fb.json")
MAX_CHARS = 600
# Training weight per source (bench/make_train.py --corpus): copies of each line, a fraction is a chance. Picked on held-out
# typed lines from AI apps (docs/rounds/2026-11-13-typing.md, round three). data/corpus-weights.json overrides.
# Per-source sampling for the nightly retrain's training lines (bench/make_train.py). Round three (13-14 November,
# docs/rounds/2026-11-13-typing.md "Layers trained on other writing"): takes add fillers and cost right first words, and
# 60,000 Beeper lines would drown the user's prompts, so chats 0.1 and takes 0, the mix bench/weights/train_sweep.py trains.
# Was beeper 1 and take 0.5 until 14 November: about 60,000 of the 70,000 training lines would have been chats.
WEIGHTS = {"typed": 2, "take": 0, "cc": 1, "codex": 1, "beeper": 0.1, "vault": 0.5, "fb": 0.5, "import": 1}
WORD = re.compile(r"[\w'’-]+", re.U)
RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")
# Not the user's own words: harness wrappers, agent briefs pasted in, interrupted turns
SKIP_HEAD = re.compile(r"^(<|\[|/|!|#|Background \(from|Reply with|Caveat:|This session|Another Claude|Do what the system prompt|"
                       r"Base directory for this skill|Continue the conversation|This session is being continued)")
CODEISH = re.compile(r"```|Traceback \(most recent|^\s+File \"|^\s*at [\w.$]+\(|\bat .+:\d+:\d+\)|^\s*[{\[]\s*\"|^\$ |"
                     r"^\d{4}-\d\d-\d\dT\d\d:\d\d|^(diff --git|@@ |\+\+\+ |--- )|</?\w+[^>]*>", re.M)


def norm(t):
    return re.sub(r"\s+", " ", t or "").strip()


def key(t):
    return norm(t).casefold()


def paste_like(t, clip=frozenset()):
    """A paste, a log, code or a dump, not a line the user wrote."""
    if len(t) > MAX_CHARS or CODEISH.search(t): return True
    lines = [l for l in t.splitlines() if l.strip()]
    if len(lines) > 6: return True
    if lines and sum(1 for l in lines if len(WORD.findall(l)) <= 2) > max(2, len(lines) // 2): return True   # list or table dump
    letters = sum(c.isalpha() for c in t)
    if letters < 0.55 * len(t.replace(" ", "")): return True   # paths, numbers, ids
    k = key(t)
    return k in clip or (len(k) >= 40 and any(k in c for c in clip if len(c) > len(k)))


def rows_jsonl(p):
    try:
        with open(p, errors="ignore") as h:
            for l in h:
                if l.strip():
                    try: yield json.loads(l)
                    except Exception: continue
    except FileNotFoundError:
        return


def typed():
    for r in rows_jsonl(SRC / "typed.jsonl"):
        yield r.get("t") or 0, r.get("app") or "", r.get("text") or ""


def takes():
    for r in rows_jsonl(SRC / "takes.jsonl"):
        t = (r.get("text") or "").strip()
        if t: yield r.get("t") or 0, r.get("app") or "", t


def iso(s):
    """ISO time with Z -> unix seconds."""
    from datetime import datetime
    try: return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception: return 0


def cc(files=None):
    """The user's prompts: top-level user turns from a person, plain text (a string or one text block)."""
    files = files if files is not None else glob.glob(str(HOME / ".claude/projects/*/*.jsonl"))
    for f in files:
        for d in rows_jsonl(f):
            if d.get("type") != "user" or d.get("isMeta") or d.get("isSidechain") or d.get("userType", "external") != "external": continue
            if d.get("entrypoint") not in (None, "cli", "claude-desktop", "claude-vscode"): continue   # headless runs are not typing
            if d.get("toolUseResult") is not None: continue
            c = (d.get("message") or {}).get("content")
            if isinstance(c, list):
                if len(c) != 1 or not isinstance(c[0], dict) or c[0].get("type") != "text": continue
                c = c[0].get("text")
            if isinstance(c, str): yield iso(d.get("timestamp") or ""), "Claude Code", c


def codex(files=None):
    files = files if files is not None else glob.glob(str(HOME / ".codex/sessions/**/*.jsonl"), recursive=True)
    for f in files:
        for d in rows_jsonl(f):
            p = d.get("payload") or {}
            if d.get("type") != "response_item" or p.get("type") != "message" or p.get("role") != "user": continue
            c = p.get("content") or []
            if len(c) != 1 or c[0].get("type") != "input_text": continue
            yield iso(d.get("timestamp") or ""), "Codex", c[0].get("text") or ""


BEEPER_CACHE = DATA / "beeper-sent.jsonl"


def beeper_fetch(after, before, limit=5000):
    """The user's sent messages between two ISO times from the local Beeper app, read-only."""
    import subprocess
    sys.path.insert(0, str(ROOT / "engine"))
    import people
    out = subprocess.run([people.beeper_bin(), "messages", "search", "--sender", "me", "--after", after, "--before", before,
                          "--limit", str(limit), "--json", "-q", "--read-only", "--full"], capture_output=True, text=True,
                         timeout=600, stdin=subprocess.DEVNULL, env={**os.environ, "BEEPER_READONLY": "1"}).stdout
    return json.loads(out)["data"]


def beeper_sync(since="2024-01-01T00:00:00Z", step_days=14):
    """Bring data/beeper-sent.jsonl up to date: from its newest message (or `since`) to now, two weeks per call (a
    call returns at most 5,000). Keeps id, time, chat and text of the user's own TEXT messages only. -> new rows."""
    from datetime import datetime, timedelta, timezone
    have, last = set(), since
    for r in rows_jsonl(BEEPER_CACHE):
        have.add(r["id"]); last = max(last, r["ts"])
    start = datetime.fromisoformat(last.replace("Z", "+00:00")) - timedelta(days=1)
    now, new = datetime.now(timezone.utc), []
    while start < now:
        end = min(start + timedelta(days=step_days), now)
        try: msgs = beeper_fetch(start.isoformat().replace("+00:00", "Z"), end.isoformat().replace("+00:00", "Z"))
        except Exception as e:
            print("beeper:", type(e).__name__); break
        if len(msgs) >= 4900 and end - start > timedelta(hours=6):   # a full answer may have left messages out: halve
            step_days /= 2; continue
        step_days = 14 if len(msgs) < 2000 else step_days
        for m in msgs:
            if m.get("isSender") and m.get("type") == "TEXT" and not m.get("isDeleted") and m.get("text") and m["id"] not in have:
                have.add(m["id"]); new.append({"id": m["id"], "ts": m.get("timestamp") or "", "chat": m.get("chatID"), "text": m["text"]})
        start = end
    if new:
        with open(BEEPER_CACHE, "a") as h: h.write("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in new))
    return len(new)


def beeper():
    try: d = json.loads((SRC / "my-messages.json").read_text())
    except Exception: d = {}
    for m in (d.get("data") if isinstance(d, dict) else d) or []:
        if m.get("isSender") and m.get("type") == "TEXT" and not m.get("isDeleted") and m.get("text"):
            yield iso(m.get("timestamp") or ""), "Beeper", m["text"]
    for r in rows_jsonl(BEEPER_CACHE):
        yield iso(r.get("ts") or ""), "Beeper", r.get("text") or ""


def paragraphs(text):
    """Writing split into pieces a line long or so: paragraphs, long ones cut at sentence ends under MAX_CHARS."""
    for para in re.split(r"\n\s*\n", text):
        para = para.strip()
        if not para: continue
        if len(para) <= MAX_CHARS: yield para; continue
        piece = ""
        for sent in re.split(r"(?<=[.!?…])\s+", para):
            if piece and len(piece) + len(sent) + 1 > MAX_CHARS: yield piece; piece = ""
            piece = (piece + " " + sent).strip()
        if piece: yield piece


FRONT = re.compile(r"\A---\n(.*?)\n---\n", re.S)


def kit_note(text):
    """-> (created date or "", body) for a note whose frontmatter says origin: <ORIGIN> (the user's own), else None."""
    m = FRONT.match(text)
    if not ORIGIN or not m or not re.search(r"(?m)^origin:\s*[\"']?" + re.escape(ORIGIN) + r"[\"']?\s*$", m.group(1)): return None
    if re.search(r"(?m)^type:\s*template", m.group(1)): return None
    c = re.search(r"(?m)^created:\s*[\"']?(\d{4}-\d\d-\d\d)", m.group(1))
    return (c.group(1) if c else ""), text[m.end():]


def vault():
    for p in VAULT.rglob("*.md"):
        rel = p.relative_to(VAULT).as_posix()
        if VAULT_SKIP.search(rel) or "/templates/" in rel: continue
        try: note = kit_note(p.read_text(errors="ignore"))
        except Exception: continue
        if not note: continue
        t = iso(note[0] + "T12:00:00Z") if note[0] else p.stat().st_mtime
        for para in paragraphs(note[1]):
            if para.startswith(("#", "![[", "|", "- [", "> [!")): continue   # headings, embeds, tables, tasks, callouts
            yield t, "Obsidian", re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", para)


def fb():
    try: posts = json.loads(FB.read_text())
    except Exception: return
    for post in posts:
        for para in paragraphs(post.get("text") or ""):
            yield post.get("ts") or 0, "Facebook", para


def import_folders():
    """data/import/ and the config's corpus.folders."""
    out = [SRC / "import"]
    for p in (local.config().get("corpus") or {}).get("folders") or []:
        if isinstance(p, str) and p.strip(): out.append(Path(os.path.expanduser(p.strip())))
    return [p for p in out if p.is_dir()]


def imported():
    for folder in import_folders():
        for p in sorted(folder.rglob("*")):
            if not p.is_file() or any(part.startswith(".") for part in p.relative_to(folder).parts): continue
            if p.suffix == ".jsonl" and folder == SRC / "import":
                for r in rows_jsonl(p):
                    if isinstance(r.get("text"), str): yield r.get("t") or p.stat().st_mtime, r.get("app") or "Import", r["text"]
            elif p.suffix in (".md", ".txt"):
                try: text = p.read_text(errors="ignore")
                except OSError: continue
                text = FRONT.sub("", text, count=1)
                for para in paragraphs(text):
                    if para.startswith(("#", "![[", "|", "> [!")): continue
                    yield p.stat().st_mtime, "Notes", para


READERS = {"typed": typed, "take": takes, "cc": cc, "codex": codex, "beeper": beeper, "vault": vault, "fb": fb, "import": imported}


def sources():
    """The sources this Mac's config allows, in ORDER."""
    c = local.config().get("corpus") or {}
    on = {"typed": c.get("typed", True) is True, "take": c.get("takes", True) is True,
          "cc": c.get("claude_code") is True, "codex": c.get("codex") is True,
          "beeper": integrations.available("beeper"),
          "vault": bool(os.environ.get("DRAFTER_VAULT")) or (integrations.available("vault") and bool(ORIGIN)),
          "fb": FB.is_file(), "import": bool(import_folders())}
    return [s for s in ORDER if on.get(s)]


def clip_keys():
    out = set()
    for r in rows_jsonl(SRC / "clipboard.jsonl"):
        k = key(r.get("text") or "")
        if len(k) >= 20: out.add(k)
    return frozenset(out)


class Takes:
    """Is this line a take the user dictated? Same text, or one holds the other (a take edited before sending)."""
    def __init__(self, texts):
        self.keys = {key(t) for t in texts if len(key(t)) >= 12}
        self.heads = {k[:40] for k in self.keys if len(k) >= 40}

    def __call__(self, t):
        k = key(t)
        return k in self.keys or (len(k) >= 40 and k[:40] in self.heads)


def build(readers=None, clip=None, dry=False, out=OUT, counts_out=COUNTS):
    readers = readers or {s: READERS[s] for s in sources()}
    clip = clip_keys() if clip is None else clip
    take_texts = [t for _, _, t in readers["take"]()] if "take" in readers else []
    dictated = Takes(take_texts)
    seen, rows, counts = {}, [], {}
    drop_ru = "ru" not in (local.user("languages") or [])
    for src in ORDER:
        if src not in readers: continue
        c = Counter()
        for t, app, text in readers[src]():
            text = (text or "").strip()
            if src in ("cc", "codex"):
                if SKIP_HEAD.search(text): c["wrapper"] += 1; continue
                if text.lower().startswith(("claude:", "клод:")): c["wrapper"] += 1; continue
            if src != "take" and paste_like(text, clip): c["paste"] += 1; continue
            if src == "take" and len(text) > 4 * MAX_CHARS: c["paste"] += 1; continue
            if src == "beeper" and text.lower().startswith(("claude:", "клод:", "«claude:", "«клод:")): c["wrapper"] += 1; continue
            if len(WORD.findall(text)) < 3: c["short"] += 1; continue
            if drop_ru and RUSSIAN.search(text): c["russian"] += 1; continue   # Russian lines stay out unless "ru" is in user.languages
            k = key(text)
            if k in seen: c["same as " + seen[k]] += 1; continue
            seen[k] = src
            d = src == "take" or (src in ("typed", "cc", "codex") and dictated(text))
            rows.append({"src": src, "t": round(t or 0), "app": app, "text": text, "dictated": d})
            c["kept"] += 1; c["words"] += len(WORD.findall(text)); c["dictated"] += d
        counts[src] = dict(c)
    if not dry:
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".tmp")
        tmp.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)); tmp.replace(out)
        counts_out.write_text(json.dumps({"built": round(time.time()), "sources": counts}, indent=1))
    return rows, counts


def weights():
    try: return {**WEIGHTS, **json.loads((DATA / "corpus-weights.json").read_text())}
    except Exception: return dict(WEIGHTS)


def load(path=OUT, before=None, srcs=None):
    """Rows of the corpus, optionally only those dated before `before` (unix seconds) and from `srcs`."""
    out = []
    for r in rows_jsonl(path):
        if srcs is not None and r["src"] not in srcs: continue
        if before is not None and (r.get("t") or 0) >= before: continue
        out.append(r)
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-beeper", action="store_true", help="skip bringing the user's Beeper messages up to date")
    ap.add_argument("--sources", action="store_true", help="print the sources this Mac's config allows and stop")
    a = ap.parse_args()
    if a.sources: print(" ".join(sources())); sys.exit(0)
    if "beeper" not in sources(): a.no_beeper = True
    t0 = time.time()
    if not a.no_beeper: print(f"beeper: {beeper_sync()} new messages")
    rows, counts = build(dry=a.dry_run)
    for s, c in counts.items():
        print(f"{s}: kept {c.get('kept', 0)}, words {c.get('words', 0)}, dictated {c.get('dictated', 0)}, "
              f"dropped {sum(v for k, v in c.items() if k not in ('kept', 'words', 'dictated'))} "
              f"({', '.join(f'{k} {v}' for k, v in c.items() if k not in ('kept', 'words', 'dictated'))})")
    print(f"{len(rows)} rows{' (dry run)' if a.dry_run else ' -> ' + str(OUT)} in {time.time() - t0:.1f}s")
