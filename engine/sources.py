"""His working sources, read into local stores (17 November 2026, Andrii: "all the emails and all the other" sources,
so he does not copy things by hand). Read-only everywhere: nothing here sends, archives, labels or changes a mail,
chat or document.

    .venv/bin/python engine/sources.py run [mail|beeper|drive|obsidian]   # nightly step, also on demand (/sources/run)
    .venv/bin/python engine/sources.py status

Sources (each optional; off or without its tool it is skipped and keeps what it has):
- mail: Gmail through GAM (`print messages`, read-only API), the mailbox in data/workspace.json; spam, trash,
  promotions and social left out. Subject, people, body without quoted replies, links, attachment names.
- beeper: the whole Beeper history through `beeper messages search` (BEEPER_READONLY=1): forward from the cursor,
  then back in time until BEEPER_DAYS.
- drive: Drive files he owns or opened (GAM `print filelist`), titles and links; Google Docs also their text.

Stores: data/sources/<name>.jsonl, one item per line, never in git; cursors, counts and switches in
data/sources.json. Other people's text is stored for context only: no style, corpus, phrase or training reader
reads these stores (tests/test_sources.py checks), and items carry `mine` so a reader can tell.

Item: {id, src, t (unix), title, who: [{name, email}], mine, text, links: [url], files: [name], url, chat}.
Readers: Index (light, mtime-reloaded: topics per person, links and files for "attach what they asked for"),
items(since) for the server journal index.
"""
import calendar
import csv
import email.utils
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
DATA = ROOT / "data"
csv.field_size_limit(1 << 26)   # GAM puts whole mail bodies in one CSV field; long HTML mails passed the 128 KB default

SOURCES = {   # name: (label, note, integration it needs)
    "mail": ("Email (Gmail)", "read-only through GAM", "gam"),
    "beeper": ("Chats (Beeper, full history)", "read-only through the beeper CLI", "beeper"),
    "drive": ("Google Docs and Drive", "titles, links and Docs text, read-only through GAM", "gam"),
    "obsidian": ("Obsidian", "local vault notes, read-only", "obsidian"),
}
CAP = {"mail": 30000, "beeper": 300000, "drive": 8000, "obsidian": 30000}     # items kept per store; the oldest go first
MAIL_DAYS, MAIL_SPAN, MAIL_PAGE, MAIL_RUN = 120, 7 * 86400, 300, 1500
MAIL_FILTER = "-in:spam -in:trash -in:chats -category:promotions -category:social"
BEEPER_DAYS, BEEPER_PAGE, BEEPER_RUN = 365, 2000, 40000
DRIVE_DAYS, DOCS_RUN, DOC_MAX = 180, 40, 20000
INDEX_MAX = {"mail": 30000, "beeper": 40000, "drive": 8000, "obsidian": 30000}   # the light view in the engine keeps the newest of each
TEXT_MAX = 4000
DOC_MIME = "application/vnd.google-apps.document"
URL = re.compile(r"https?://[^\s<>\"')\]]+")
NOISE_URL = re.compile(r"unsubscribe|/track|click\.|list-manage|mailchimp|sendgrid|utm_|/open\?|email\.mg\.|"
                       r"googleusercontent\.com/proxy|\.(png|gif|jpe?g)(\?|$)", re.I)
SIGNED = re.compile(r"^\s*(claude|клод)\s*:", re.I)


def iso(t): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def from_iso(s):
    try: return float(calendar.timegm(time.strptime(str(s)[:19], "%Y-%m-%dT%H:%M:%S")))
    except (ValueError, TypeError): return 0.0


def fold(s): return " ".join(str(s or "").casefold().split())


def atomic(path, text):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f: f.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def links(text):
    out = []
    for u in URL.findall(text or ""):
        u = u.rstrip(".,;:!?")
        if not NOISE_URL.search(u) and u not in out: out.append(u)
    return out[:20]


def strip_quoted(body):
    """A mail body without the quoted thread below it and without '>' lines."""
    out = []
    for line in (body or "").replace("\r\n", "\n").split("\n"):
        s = line.strip()
        if s.startswith(">"): continue
        if re.match(r"^(On .{6,200} wrote:|.{0,120}\d{4}.{0,60}(пише|написав|написала|wrote):?|-{2,}\s*Original Message|"
                    r"-{5,}\s*Forwarded message|From: .+@)", s): break
        out.append(line.rstrip())
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()
    return text[:TEXT_MAX]


def people(field):
    return [{"name": n.strip().strip('"'), "email": e.lower()} for n, e in email.utils.getaddresses([field or ""]) if "@" in e]


# ---- state and stores --------------------------------------------------------------------------------------------

class State:
    def __init__(self, path=None):
        self.path = Path(path) if path else DATA / "sources.json"
        self.lock = threading.Lock()
        self.running = set()

    def read(self):
        try: d = json.loads(self.path.read_text())
        except (OSError, ValueError): d = {}
        return {n: {"enabled": True, "cursor": {}, "count": 0, "updated": 0, "error": "", **(d.get(n) or {})} for n in SOURCES}

    def update(self, name, **kw):
        with self.lock:
            d = self.read(); d[name].update(kw)
            atomic(self.path, json.dumps(d, ensure_ascii=False, indent=1) + "\n")
            return d[name]


def store_path(name, folder=None): return Path(folder or DATA / "sources") / f"{name}.jsonl"


def read_store(path):
    rows = {}
    try:
        with Path(path).open() as f:
            for line in f:
                try: r = json.loads(line)
                except ValueError: continue
                if isinstance(r, dict) and r.get("id"): rows[r["id"]] = r
    except FileNotFoundError: pass
    return rows


def write_store(path, rows, cap):
    """New and changed items in; over the cap the oldest go. Whole file rewritten atomically."""
    keep = sorted(rows.values(), key=lambda r: r.get("t") or 0)[-cap:]
    atomic(path, "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in keep))
    return len(keep)


# ---- runners (tests pass their own) ------------------------------------------------------------------------------

def gam_run(args, timeout=600):
    import local
    gam = str(Path(local.setting("gam", "bin") or "/nonexistent/gam").expanduser())
    p = subprocess.run([gam, *args], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout,
                       preexec_fn=lambda: os.nice(10))
    if p.returncode: raise RuntimeError(f"gam exit {p.returncode}")
    return p.stdout


def beeper_run(args, timeout=300):
    import people as ppl
    env = {**os.environ, "BEEPER_READONLY": "1"}
    p = subprocess.run([ppl.beeper_bin(), *args, "--json", "-q", "--read-only", "--full"], capture_output=True, text=True,
                       stdin=subprocess.DEVNULL, timeout=timeout, env=env, preexec_fn=lambda: os.nice(10))
    if p.returncode: raise RuntimeError(f"beeper exit {p.returncode}")
    return json.loads(p.stdout)["data"]


def account(workspace=None):
    try: a = json.loads(Path(workspace or DATA / "workspace.json").read_text()).get("account", "").strip()
    except (OSError, ValueError, AttributeError): return ""
    return a if re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", a) else ""


# ---- mail --------------------------------------------------------------------------------------------------------

def mail_rows(text, me):
    me = (me or "").lower()
    for r in csv.DictReader(io.StringIO(text.lstrip("﻿"))):
        mid = (r.get("id") or "").strip()
        if not mid: continue
        try: t = email.utils.parsedate_to_datetime(r.get("Date") or "").timestamp()
        except (TypeError, ValueError): t = 0.0
        frm, to = people(r.get("From")), people(r.get("To")) + people(r.get("Cc"))
        body = strip_quoted(r.get("Body") or "")
        try: n = int(r.get("Attachments") or 0)
        except ValueError: n = 0
        files = [r.get(f"Attachments.{i}.name") for i in range(n) if r.get(f"Attachments.{i}.name")]
        files = [f for f in files if not re.search(r"\.(ics|p7s|asc)$|^image\d+\.", f, re.I)]
        yield {"id": "mail:" + mid, "src": "mail", "t": t, "title": " ".join((r.get("Subject") or "").split())[:200],
               "who": [p for p in frm + to if p["email"] != me], "mine": any(p["email"] == me for p in frm),
               "text": body, "links": links(body), "files": files, "chat": r.get("threadId") or mid,
               "url": f"https://mail.google.com/mail/u/0/#all/{mid}"}


def ingest_mail(state, *, run=gam_run, me=None, folder=None, now=None):
    me = me or account()
    if not me: raise RuntimeError("no mailbox in data/workspace.json")
    now = now or time.time()
    cur = state.read()["mail"]["cursor"]
    a = float(cur.get("after") or now - MAIL_DAYS * 86400)
    span = float(cur.get("span") or MAIL_SPAN)
    path = store_path("mail", folder); rows = read_store(path); got = 0
    try:
        while a < now - 60 and got < MAIL_RUN:
            b = min(now, a + span)
            out = run(["user", me, "print", "messages", "query", f"after:{int(a)} before:{int(b)} {MAIL_FILTER}",
                       "max_to_print", str(MAIL_PAGE), "showbody", "showattachments", "headers", "From,To,Cc,Subject,Date"])
            page = list(mail_rows(out, me))
            if len(page) >= MAIL_PAGE and span > 3600:     # newest first and cut: a narrower window, nothing skipped
                span = max(3600, span / 4); continue
            for r in page: rows[r["id"]] = r
            got += len(page); a = b; span = min(MAIL_SPAN, span * 2)
    finally:   # a failed window (GAM exit 60 seen on 17 November) keeps every window read before it
        count = write_store(path, rows, CAP["mail"])
        state.update("mail", cursor={"after": a, "span": span}, count=count)
    return got


# ---- beeper ------------------------------------------------------------------------------------------------------

def beeper_rows(msgs, titles):
    for m in msgs:
        if m.get("isDeleted") or not (m.get("text") or "").strip() or not m.get("id"): continue
        text = re.sub(r"<[^>]+>", "", re.sub(r"<br\s*/?>", "\n", m["text"])).strip()[:TEXT_MAX]
        chat = m.get("chatID") or ""
        mine = bool(m.get("isSender")) and not SIGNED.match(text)
        yield {"id": f"beeper:{chat}:{m['id']}", "src": "beeper", "t": from_iso(m.get("timestamp")),
               "title": titles.get(chat, ""), "who": [] if m.get("isSender") else [{"name": " ".join((m.get("senderName") or "").split()), "email": ""}],
               "mine": mine, "text": text, "links": links(text), "files": [a.get("fileName") for a in (m.get("attachments") or [])
               if isinstance(a, dict) and a.get("fileName")], "chat": chat, "kind": (m.get("type") or "").lower(), "url": ""}


def beeper_pages(run, after, before, budget):
    """Messages in [after, before], newest first, page by page backwards: -> (messages, oldest time reached, done)."""
    out, b, seen = [], before, set()
    while len(out) < budget:
        page = run(["messages", "search", "--after", iso(after), "--before", iso(b), "--limit", str(BEEPER_PAGE)])
        new = [m for m in page if m.get("id") and m["id"] not in seen]
        seen.update(m["id"] for m in new); out += new
        if len(page) < BEEPER_PAGE or not new: return out, after, True
        oldest = min(from_iso(m.get("timestamp")) for m in new)
        if oldest >= b: return out, after, True
        b = oldest
    return out, b, False


def ingest_beeper(state, *, run=beeper_run, folder=None, now=None):
    now = now or time.time()
    cur = state.read()["beeper"]["cursor"]
    try: titles = {c["id"]: c.get("title") or "" for c in run(["chats", "list", "--limit", "500"]) if c.get("id")}
    except Exception: titles = {}
    path = store_path("beeper", folder); rows = read_store(path); got = 0
    after = float(cur.get("after") or now - 3 * 86400)
    oldest = float(cur.get("oldest") or after)
    new_after = after
    try:
        # forward: from the cursor to now (an hour of overlap; ids dedupe)
        msgs, reached, done = beeper_pages(run, after - 3600, now, BEEPER_RUN)
        for r in beeper_rows(msgs, titles): rows[r["id"]] = r
        got += len(msgs)
        new_after = now if done else after     # a cut forward read: the next run starts from the same cursor
        # back in time until BEEPER_DAYS
        horizon = now - BEEPER_DAYS * 86400
        if oldest > horizon and got < BEEPER_RUN:
            msgs, reached, done = beeper_pages(run, max(horizon, oldest - 30 * 86400), oldest, BEEPER_RUN - got)
            for r in beeper_rows(msgs, titles): rows[r["id"]] = r
            got += len(msgs)
            oldest = max(horizon, oldest - 30 * 86400) if done else reached
    finally:   # a failed page keeps what came before it; the cursors move only past what is stored
        count = write_store(path, rows, CAP["beeper"])
        state.update("beeper", cursor={"after": new_after, "oldest": oldest}, count=count)
    return got


# ---- drive -------------------------------------------------------------------------------------------------------

def drive_rows(text, me):
    me = (me or "").lower()
    for r in csv.DictReader(io.StringIO(text.lstrip("﻿"))):
        fid = (r.get("id") or "").strip()
        if not fid or (r.get("mimeType") or "").endswith(".folder"): continue
        owner = (r.get("owners.0.emailAddress") or "").lower()
        yield {"id": "drive:" + fid, "src": "drive", "t": from_iso(r.get("modifiedTime")), "title": r.get("name") or "",
               "who": [] if owner == me or not owner else [{"name": r.get("owners.0.displayName") or "", "email": owner}],
               "mine": owner == me, "text": "", "links": [], "files": [r.get("name") or ""], "chat": "",
               "url": r.get("webViewLink") or "", "mime": r.get("mimeType") or "", "fid": fid}


def ingest_drive(state, *, run=gam_run, me=None, folder=None, now=None, tmp=None):
    me = me or account()
    if not me: raise RuntimeError("no account in data/workspace.json")
    now = now or time.time()
    cur = state.read()["drive"]["cursor"]
    after = iso(float(cur.get("after") or now - DRIVE_DAYS * 86400))
    out = run(["user", me, "print", "filelist", "anyowner", "query",
               f"modifiedTime > '{after}' and trashed = false and ('me' in owners or viewedByMeTime > '{after}')",
               "fields", "id,name,mimetype,modifiedtime,webviewlink,owners"])
    path = store_path("drive", folder); rows = read_store(path); got = 0
    for r in drive_rows(out, me):
        old = rows.get(r["id"])
        if old and old.get("t") == r["t"]: continue
        if old and old.get("text_t") == r["t"]: r["text"], r["text_t"] = old.get("text", ""), old["text_t"]
        rows[r["id"]] = r; got += 1
    # Docs text: the newest docs whose text is older than the doc, at most DOCS_RUN per run
    todo = sorted((r for r in rows.values() if r.get("mime") == DOC_MIME and r.get("text_t") != r["t"]),
                  key=lambda r: -r["t"])[:DOCS_RUN]
    with tempfile.TemporaryDirectory(dir=tmp) as d:
        for r in todo:
            try:
                run(["user", me, "get", "drivefile", "id", r["fid"], "format", "txt", "targetfolder", d,
                     "targetname", "doc.txt", "overwrite", "true"])
                f = Path(d) / "doc.txt"
                r["text"] = f.read_text(errors="replace").lstrip("﻿")[:DOC_MAX] if f.exists() else ""
                r["links"] = links(r["text"]); r["text_t"] = r["t"]
                if f.exists(): f.unlink()
            except Exception as e:
                print("sources: doc text:", type(e).__name__, flush=True)
    newest = max([from_iso(after)] + [r["t"] for r in rows.values()])
    count = write_store(path, rows, CAP["drive"])
    state.update("drive", cursor={"after": newest}, count=count)
    return got


def ingest_obsidian(state):
    import obsidian
    data = state.path.parent
    n = obsidian.sync(data)
    state.update("obsidian", count=len(obsidian.cached_notes(data)))
    from local_search import LocalSearchIndex
    index = LocalSearchIndex(data_dir=data)
    try: index.sync()
    finally: index.close()
    return n


INGEST = {"mail": ingest_mail, "beeper": ingest_beeper, "drive": ingest_drive, "obsidian": ingest_obsidian}


def available(name):
    import integrations
    if name == "obsidian":
        import obsidian
        return obsidian.enabled(DATA)
    return integrations.available(SOURCES[name][2])


def run(names=None, state=None, check=available, ingest=None):
    """Each named (or every enabled) source once; one source's failure never stops the others. -> {name: count or error}."""
    state = state or STATE
    ingest = ingest or INGEST
    d = state.read(); out = {}
    for name in names or list(SOURCES):
        if name not in SOURCES or not d[name]["enabled"]: continue
        if name == "obsidian":
            import obsidian
            if not obsidian.enabled(state.path.parent): continue
        if name in state.running: out[name] = "running"; continue
        if name != "obsidian" and not check(name):
            state.update(name, error=f"{SOURCES[name][2]} is off or not answering"); out[name] = "unavailable"; continue
        state.running.add(name)
        try:
            n = ingest[name](state)
            state.update(name, updated=time.time(), error=""); out[name] = n
        except Exception as e:
            state.update(name, error=f"{type(e).__name__}: {str(e)[:120]}"); out[name] = "error"
        finally: state.running.discard(name)
    return out


def status(state=None):
    state = state or STATE
    d = state.read()
    import obsidian
    if not obsidian.enabled(state.path.parent):
        d["obsidian"].update(enabled=False, count=0, error="")
    return {"sources": [{"name": n, "label": SOURCES[n][0], "note": SOURCES[n][1], "enabled": d[n]["enabled"],
                         "count": d[n]["count"], "updated": d[n]["updated"], "error": d[n]["error"],
                         "running": n in state.running} for n in SOURCES]}


def run_in_background(names=None, state=None):
    threading.Thread(target=run, args=(names, state), daemon=True, name="sources").start()
    return {"started": True}


STATE = State()


# ---- readers -----------------------------------------------------------------------------------------------------

def items(since=0, names=None, folder=None, include_theirs=True):
    """Every stored item newer than `since` (unix), oldest first per source: the server journal index's input.
    include_theirs=False keeps only his own items."""
    for name in names or list(SOURCES):
        if name == "obsidian":
            import obsidian
            data = Path(folder).parent if folder else DATA
            rows = obsidian.cached_notes(data)
        else: rows = read_store(store_path(name, folder)).values()
        for r in sorted(rows, key=lambda r: r.get("t") or 0):
            if (r.get("t") or 0) >= since and (include_theirs or r.get("mine")): yield r


class Index:
    """SQLite-backed light view for whom.py and the attach finder. Store refreshes
    stay in the background by default; sync=True is deterministic for tests.
    The legacy rows dictionary is materialized only when a caller asks for it.
    """

    def __init__(self, folder=None, state=None, sync=False):
        self.folder, self.state, self.sync = folder, state, sync
        self.stamps, self._rows = {}, {}
        self.lock, self.loading, self.checked = threading.Lock(), False, 0.0
        self._local, self._ready = None, False

    def _index(self):
        if self._local is None:
            from local_search import LocalSearchIndex
            folder = Path(self.folder) if self.folder is not None else DATA / "sources"
            # A custom flat store gets its own cache, never a shared /tmp/cache or
            # the real data directory. A conventional sources/ uses its parent.
            data = folder.parent if folder.name == "sources" else folder
            self._local = LocalSearchIndex(data_dir=data)
        return self._local

    @property
    def rows(self):
        with self.lock:
            for name in self.stamps:
                if name not in self._rows:
                    self._rows[name] = self._index().source_rows(name)
            return self._rows

    @rows.setter
    def rows(self, value):
        self._rows = value

    def _changed(self):
        enabled = self.state.read() if self.state else {n: {"enabled": True} for n in SOURCES}
        out = {}
        for name in SOURCES:
            try: st = store_path(name, self.folder).stat(); stamp = (st.st_mtime_ns, st.st_size)
            except FileNotFoundError: stamp = None
            if not enabled[name]["enabled"]: stamp = "off"
            if name == "obsidian":
                import obsidian
                data = Path(self.folder).parent if self.folder else DATA
                stamp = (stamp, str(obsidian.vault_path(data))) if obsidian.enabled(data) else "off"
            if stamp != self.stamps.get(name, 0): out[name] = stamp
        return out

    def _reload(self, changed):
        try:
            if not changed: return
            enabled = self.state.read() if self.state else {n: True for n in SOURCES}
            result = self._index().sync(sources_dir=self.folder or DATA / "sources", enabled=enabled)
            if "error" in result: return
            with self.lock:
                for name, stamp in changed.items():
                    self._rows.pop(name, None)
                    self.stamps[name] = stamp
                self._ready = True
        finally: self.loading = False

    def _load(self):
        if self.sync: self._reload(self._changed()); return self
        if self.loading or time.time() - self.checked < 30: return self
        self.checked = time.time()
        changed = self._changed()
        if changed:
            self.loading = True
            threading.Thread(target=self._reload, args=(changed,), daemon=True, name="sources-index").start()
        return self

    def topics(self, emails=(), names=(), n=3):
        """Recent mail subjects and group titles, with the existing per-person rules."""
        self._load()
        return self._index().topics(emails, names, n) if self._ready else {"mail": [], "chats": []}

    def find(self, query, who=(), n=8, since=0):
        """Links and files matching title, file name, link text or the first lines."""
        self._load()
        return self._index().find_links_files(query, who, n, since) if self._ready else []

    def stats(self):
        self._load()
        counts = self._index().stats()["src"] if self._ready else {}
        return {name: counts.get(name, 0) for name, stamp in self.stamps.items() if name != "obsidian" or counts.get(name, 0)}


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["status"]:
        for s in status()["sources"]:
            print(f"{s['name']:7} {'on ' if s['enabled'] else 'off'} {s['count']:7} items, updated "
                  f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(s['updated'])) if s['updated'] else 'never'}"
                  + (f", error: {s['error']}" if s['error'] else ""))
    elif args[:1] == ["run"]:
        print("sources:", run(args[1:] or None))
    else:
        print(__doc__)
