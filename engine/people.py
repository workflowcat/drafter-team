"""Per-person memory (2026-11-01, Andrii: "per-person memory of past replies"). In a Beeper chat the model also reads
his own older messages in THAT chat (names, projects, "ти" or "ви", how he writes to this person), above the screen
(prompt.tail "mine"): on the fresh Beeper replies letters saved went 11.3% -> 12.4%. Weighting that chat's words
higher in the word booster was tried too and did nothing (his writing overall already holds them).

Which chat is on screen: the Beeper window title never changes, so the lines of the chat above the caret are matched
against fingerprints (6-byte hashes) of each chat's recent lines. The other person's text is never stored, only those
fingerprints; his own messages per chat are kept in data/people.json (local only, like data/phrases.jsonl).

Who a chat is with (2026-11-16): each chat also keeps the display names of the other people who wrote there
(`who`, at most WHO_KEPT, most messages first) and its title when Beeper lists it, so engine/whom.py can match the
chat to the names reference. Names only, never their text.

Built from the Beeper CLI (read only, BEEPER_READONLY=1) in the background: at start when the file is older than
REFRESH, then every REFRESH; lines he sends while Drafter runs are added at once (/typed). Messages signed
"Claude:" are Claude's, not his, and stay out.
"""
import calendar, hashlib, json, os, re, subprocess, threading, time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
PATH = DATA / "people.json"
ENV = {**os.environ, "BEEPER_READONLY": "1"}
# launchd starts the nightly with PATH=/usr/bin:/bin:/usr/sbin:/sbin, where the npm-installed `beeper` is missing:
# the retrain of 8 November drew no Beeper lines and stopped at people_fresh.py ("No such file or directory: 'beeper'")
BEEPER_DIRS = ("~/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin")


def beeper_bin(path=None):
    """The `beeper` CLI: from PATH, else from the usual install folders; 'beeper' when none has it (the error names it)."""
    import shutil
    dirs = [path if path is not None else os.environ.get("PATH", "")] + [os.path.expanduser(d) for d in BEEPER_DIRS]
    return shutil.which("beeper", path=os.pathsep.join(d for d in dirs if d)) or "beeper"


REFRESH = 1800          # seconds between Beeper reads
KEEP = 600              # his lines kept per chat
MARK_LINES = 80         # the last messages of a chat whose lines are fingerprinted
MAX_EMPTY_MARKS = 4096  # retain recent collision protection without unbounded tombstones
MIN_MARK = 8            # shorter lines ("ок", "дякую!") are in every chat and say nothing
WHO_KEPT = 3            # other people's display names kept per chat
BACKFILL = 40           # known chats without `who` read again per refresh, until all have it
SIGNED = re.compile(r"^\s*(claude|клод)\s*:", re.I)


def signed(t):
    return bool(SIGNED.match(t or ""))


def clean(t):
    t = re.sub(r"<br\s*/?>", "\n", t or ""); t = re.sub(r"<[^>]+>", "", t)
    return "\n".join(l.strip() for l in t.splitlines() if l.strip())


def mark(line):
    s = re.sub(r"\s+", " ", (line or "").strip().lower())
    if len(s) < MIN_MARK: return ""
    return hashlib.blake2b(s.encode(), digest_size=6).hexdigest()


def find(marks, context, min_votes=2, last=None):
    """The chat whose lines fill the screen above the caret, or None: at least two lines of it (one when it is the
    chat found last time, so the prompt does not flip as the screen scrolls), and twice as many as any other chat."""
    votes = Counter()
    for l in [l for l in (context or "").splitlines() if l.strip()][-40:]:
        c = marks.get(mark(l))
        if c: votes[c] += 1
    if not votes: return None
    top = votes.most_common(2)
    if top[0][1] < (1 if top[0][0] == last else min_votes) or (len(top) > 1 and top[1][1] * 2 > top[0][1]): return None
    return top[0][0]


def earlier(mine, context, n=12, line_max=160, total=700):
    """His older messages in a chat for the prompt: the latest n that are not on screen already, newest last."""
    # Compare full messages before shortening them for the prompt. Bench contexts label our lines "Я:".
    normalize = lambda t: " ".join(t.lower().split())
    lines = [normalize(re.sub(r"^\s*Я:\s*", "", l)) for l in (context or "").splitlines() if l.strip()]
    screen = "\n" + "\n".join(lines) + "\n"
    out, size = [], 0
    for t in reversed(mine):
        full = clean(t)
        message = "\n".join(normalize(l) for l in full.splitlines())
        t = " ".join(full.split())
        if not t or "\n" + message + "\n" in screen: continue
        # The screen/bench may cut a long message too. Do not repeat a prompt-sized
        # prefix that is already visible, even if its final word was cut in half.
        if len(t) > line_max and any(l.startswith(t[:line_max].lower()) for l in lines): continue
        t = t[:line_max]
        if size + len(t) > total or len(out) >= n: break
        out.append(t); size += len(t) + 1
    return "\n".join(reversed(out))


def note_who(c, hist, listed=None):
    """The chat's other people (display names, most messages first) and its title, into chat record `c`."""
    names = Counter(" ".join((h.get("senderName") or "").split()) for h in hist if not h.get("isSender"))
    names.pop("", None)
    old = list(c.get("who") or [])
    c["who"] = [n for n, _ in names.most_common(WHO_KEPT)] or old
    if len(names) > 1: c["group"] = True
    if listed:
        title, group = listed
        if title: c["title"] = title
        if group: c["group"] = True


def beeper(*a, timeout=90):
    out = subprocess.run([beeper_bin(), *a, "--json", "-q", "--read-only", "--full"], capture_output=True, text=True, stdin=subprocess.DEVNULL,
                         timeout=timeout, env=ENV, preexec_fn=lambda: os.nice(10)).stdout
    return json.loads(out)["data"]


class People:
    def __init__(self, path=PATH):
        self.path, self.lock = Path(path), threading.Lock()
        self.chats, self.marks, self.t, self.dirty, self.tried = {}, {}, 0.0, False, 0.0
        self.blocks, self.last = {}, None     # chat -> (when, his older lines for the prompt); the chat found last
        try:
            d = json.loads(self.path.read_text())
            self.chats, self.marks, self.t = d.get("chats", {}), d.get("marks", {}), d.get("t", 0.0)
        except Exception: pass

    # -- reading ---------------------------------------------------------------------------------------------------
    def chat_for(self, context):
        with self.lock: return find(self.marks, context, last=self.last)

    def block(self, context, ttl=3600, min_lines=3, remember=True):
        """His older messages in the chat on screen, for the prompt (prompt.tail "mine"), or "". Fixed per chat for
        ttl seconds, so the prompt above the screen stays the same and the cache keeps it; lines he sends meanwhile
        are on the screen anyway."""
        with self.lock:
            chat = find(self.marks, context, last=self.last)
            if not chat: return ""
            if remember: self.last = chat
            b = self.blocks.get(chat)
            if b and time.time() - b[0] < ttl:
                mine = b[1]
            else:
                mine = list((self.chats.get(chat) or {}).get("mine", []))
                self.blocks[chat] = (time.time(), mine)
        # Recheck the current screen even when using an hour-old snapshot of older messages.
        return earlier(mine, context) if len(mine) >= min_lines else ""

    def info(self, chat):
        """-> {"who": [their display names], "title", "group", "mine": [his lines]} for a chat id, or None."""
        with self.lock:
            c = self.chats.get(chat)
            if not c: return None
            who = list(c.get("who") or [])
            return {"who": who, "title": c.get("title", ""), "group": bool(c.get("group")) or len(who) > 1,
                    "mine": list(c.get("mine") or [])}

    # -- learning --------------------------------------------------------------------------------------------------
    def add(self, context, text):
        """A line he just sent in Beeper: it joins that chat's lines now (the prompt block takes it at its next turn),
        and marks the chat for the next screen."""
        text = clean(text)
        if not text or signed(text): return None
        with self.lock:
            chat = find(self.marks, context, last=self.last)
            if not chat: return None
            self.last = chat
            c = self.chats.setdefault(chat, {"mine": [], "key": ""})
            c["mine"] = (c["mine"] + [text])[-KEEP:]
            for l in text.splitlines():
                m = mark(l)
                if m: self._mark(m, chat)
            self.dirty = True
        return chat

    def _mark(self, m, chat):
        old = self.marks.get(m)
        self.marks[m] = chat if old in (None, chat) else ""    # a line seen in two chats points nowhere

    def save(self):
        with self.lock:
            live = set(self.chats)
            recent_empty = set([m for m, c in self.marks.items() if c == ""][-MAX_EMPTY_MARKS:])
            self.marks = {m: c for m, c in self.marks.items() if c in live or m in recent_empty}
            data = json.dumps({"t": self.t, "chats": self.chats, "marks": self.marks}, ensure_ascii=False)
            self.dirty = False
        tmp = self.path.with_suffix(".tmp"); tmp.write_text(data); os.replace(tmp, self.path)

    def refresh(self, days=60):
        """Read Beeper: chats he wrote in since the last read (60 days the first time), his lines there, and
        fingerprints of their latest lines. -> chats read."""
        t0 = self.t or time.time() - days * 86400
        after = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0 - 3600))
        started = time.time()
        self.tried = started
        sent = beeper("messages", "search", "--sender", "me", "--after", after, "--limit", "3000", timeout=180)
        wrote = Counter(m["chatID"] for m in sent if m.get("type") == "TEXT")
        if not wrote and not self.chats: return 0     # Beeper not running (or nothing to read): try again later
        titles = {}
        try:
            listed = beeper("chats", "list", "--limit", "60")
            titles = {c["id"]: (c.get("title") or "", c.get("type") == "group") for c in listed if c.get("id")}
            active = {c["id"] for c in listed
                      if c.get("lastActivity") and calendar.timegm(time.strptime(c["lastActivity"][:19], "%Y-%m-%dT%H:%M:%S")) > t0}
        except Exception: active = set()
        with self.lock:
            known = set(self.chats)
            unnamed = [c for c in self.chats if "who" not in self.chats[c]]
        todo = [c for c, _ in wrote.most_common(80)] + sorted((active & known) - set(wrote))
        todo += [c for c in unnamed if c not in todo][:BACKFILL]
        for chat in todo:
            new = chat not in known
            try: hist = beeper("messages", "list", "--chat", chat, "--limit", "400" if new else str(MARK_LINES))
            except Exception as e: print("people:", e, flush=True); continue
            hist = sorted((h for h in hist if h.get("type") == "TEXT" and h.get("text")), key=lambda h: int(h.get("sortKey") or 0))
            with self.lock:
                c = self.chats.setdefault(chat, {"mine": [], "key": ""})
                last = int(c.get("key") or 0)
                fresh = [clean(h["text"]) for h in hist if h.get("isSender") and int(h.get("sortKey") or 0) > last]
                c["mine"] = (c["mine"] + [t for t in fresh if t and not signed(t)])[-KEEP:]
                if hist: c["key"] = str(max(last, int(hist[-1].get("sortKey") or 0)))
                note_who(c, hist, titles.get(chat))
                for h in hist[-MARK_LINES:]:
                    for l in clean(h["text"]).splitlines():
                        m = mark(l)
                        if m: self._mark(m, chat)
                if not c["mine"]: del self.chats[chat]          # a chat he only reads
        with self.lock: self.t = started
        self.save()
        return len(todo)

    def start(self):
        """Background reads; quiet when Beeper is not running."""
        def loop():
            while True:
                if time.time() - self.t >= REFRESH and time.time() - self.tried >= 600:
                    try: n = self.refresh(); print(f"people: {n} chats read, {len(self.chats)} kept", flush=True)
                    except Exception as e: print("people:", e, flush=True)
                elif self.dirty:
                    try: self.save()
                    except Exception as e: print("people:", e, flush=True)
                time.sleep(60)
        threading.Thread(target=loop, daemon=True, name="people").start()
