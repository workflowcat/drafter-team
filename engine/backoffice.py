"""The Claude back office (17 November 2026, Andrii: Claude at the caret "adds complexity, doesn't really solve anything
for us yet"; Claude is for sorting, reviewing, enhancing and tagging, which it does much better than the local models).

Slow jobs over text he already wrote, in a batch: nightly (bench/nightly.sh), or on demand (POST /backoffice/run, or
`.venv/bin/python -B engine/backoffice.py [--jobs tags,calls] [--dry-run]`). Nothing here runs while he types.
Results land in local stores under data/backoffice/:

  tags     the day's journal items (typed lines, voice takes, copies): topic, project, person -> tags.json
  calls    each call transcript of the last 8 days: summary, decisions, next steps, who said what -> calls/<call>.json
  people   people seen in recent mail and chats (engine/sources.py, when it is there): role, now, open, facts -> people.json
  snippets his week's lines: texts he types again and again, as snippet ideas he may accept -> snippet-ideas.json
  grades   a sample of local ghosts he took, each with the line he then sent: good or bad, why -> ghost-grades.jsonl
  review   weekly (or on demand): open promises, unanswered threads, what moved, next -> review-<day>.md / .json

One switch owns it all: `backOffice` (engine/cloud.py "backoffice"), off until he turns it on, and the Mac online.
A daily cost cap (`backOfficeCap`, USD, default 0.50) stops the batch before a call that would pass it; spend per day in
spend.json. Every answer is cached by its prompt (cache.json), and every item is marked done, so nothing is sent twice.
The ask goes the existing key path: the signed-in `claude` CLI (one-shot `claude -p`, its JSON reports the cost) or the
connected API (engine/provider.py, cost estimated from the length). Rows holding the test mark are never sent.

The server job queue on your server (bench/jobs.py, drafter-server-jobs) can take these jobs later; they are plain
functions over local files, so the queue only needs to call run().
"""
import hashlib, json, os, random, re, subprocess, sys, threading, time
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
TEST = "⟦drafter-test⟧"
JOBS = ("tags", "calls", "people", "snippets", "grades", "review")
DEFAULT_CAP = 0.50
# USD per million tokens (input, output), Anthropic list prices checked 2026-11-17 (claude-api skill, cached 2026-11-03)
PRICE = {"haiku": (0.10, 0.50), "sonnet": (2.00, 10.00), "opus": (4.00, 20.00)}
TIER = {"tags": "haiku", "grades": "haiku", "snippets": "haiku", "calls": "sonnet", "people": "sonnet", "review": "sonnet"}
OUT_TOKENS = {"tags": 1500, "grades": 1200, "snippets": 800, "calls": 2000, "people": 600, "review": 2500}
TAG_BATCH, ITEM_CHARS = 40, 400
CALL_CHARS = 60000
GRADE_SAMPLE = 30
PEOPLE_MAX, PEOPLE_ITEMS = 15, 12
_lock = threading.Lock()
state = {"running": False, "last": None}


# ---- small helpers --------------------------------------------------------------------------------------------------

def tokens(text):
    """A rough token count: ~3.5 characters a token (mixed English and Ukrainian runs a little higher; good enough for a cap)."""
    return max(1, int(len(text) / 3.5))


def estimate(prompt, job):
    i, o = PRICE[TIER[job]]
    return (tokens(prompt) * i + OUT_TOKENS[job] * o) / 1e6


def _read_json(p, default):
    try: return json.loads(Path(p).read_text())
    except Exception: return default


def _write_json(p, d):
    p = Path(p); p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1)); tmp.replace(p)


def _rows(p, since=0.0):
    out = []
    try:
        with open(p, encoding="utf-8") as f:
            for line in f:
                try: r = json.loads(line)
                except Exception: continue
                if isinstance(r, dict) and float(r.get("t") or 0) >= since and TEST not in str(r.get("text", "")): out.append(r)
    except FileNotFoundError: pass
    return out


def parse_json(text):
    """The first JSON value in an answer (Claude may wrap it in a code fence or a line of words)."""
    if not text: return None
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if m: text = m.group(1)
    for open_, close in (("[", "]"), ("{", "}")):
        a, b = text.find(open_), text.rfind(close)
        if a != -1 and b > a:
            try: return json.loads(text[a:b + 1])
            except Exception: pass
    return None


def day_start(now):
    d = datetime.fromtimestamp(now)
    return datetime(d.year, d.month, d.day).timestamp()


# ---- the ask, the cache and the cap ---------------------------------------------------------------------------------

SYSTEM = "You process a person's own notes in a batch. Answer exactly in the format asked, nothing else."


def cli_ask(prompt, tier, timeout=240):
    """One `claude -p` run (no plugins, no MCP, no settings, no session kept) -> (text, usd) or (None, 0)."""
    import integrations
    exe = integrations.claude_bin() if integrations.available("claude") else ""
    if not exe: return None, 0.0
    argv = [exe, "-p", "--output-format", "json", "--model", tier, "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
            # no tools and a one-line system prompt: the CLI's own prompt and tool list cost $0.16 a Sonnet call (measured 2026-11-17)
            "--tools", "", "--system-prompt", SYSTEM]
    env = {**os.environ, "PATH": f"{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"}
    try:
        p = subprocess.run(argv, input=prompt, capture_output=True, text=True, timeout=timeout, env=env)
        d = json.loads(p.stdout or "{}")
    except Exception as e:
        print("backoffice: claude", type(e).__name__, flush=True)      # never the text
        return None, 0.0
    if d.get("is_error"): return None, float(d.get("total_cost_usd") or 0)
    return (d.get("result") or "").strip() or None, float(d.get("total_cost_usd") or 0)


def default_ask(prompt, tier, job):
    """The existing key path: an API connection through provider.py, else the signed-in CLI."""
    import provider
    if provider.kind() in ("anthropic", "openai"):
        out = provider.ask(prompt, 180, tier)
        return out, estimate(prompt, job) if out else 0.0
    return cli_ask(prompt, tier)


class Office:
    """One batch: the cap, the cache and the store folder. `ask(prompt, tier, job) -> (text, usd)` is injectable (tests)."""

    def __init__(self, data=DATA, cap=DEFAULT_CAP, ask=None, now=None, dry=False):
        self.data, self.dir = Path(data), Path(data) / "backoffice"
        self.cap, self.ask_fn, self.now, self.dry = float(cap), ask or default_ask, now or time.time(), dry
        self.day = datetime.fromtimestamp(self.now).strftime("%Y-%m-%d")
        self.spend = _read_json(self.dir / "spend.json", {})
        self.cache = _read_json(self.dir / "cache.json", {})
        self.report = {"calls": 0, "cached": 0, "usd": 0.0, "estimate": 0.0, "capped": False, "jobs": {}}

    def spent(self): return float(self.spend.get(self.day, 0.0))

    def ask(self, prompt, job):
        """-> the answer, from the cache or Claude; None when capped, failed, or a dry run."""
        tier = TIER[job]
        key = hashlib.sha256((tier + "\n" + prompt).encode()).hexdigest()[:32]
        if key in self.cache:
            self.report["cached"] += 1
            return self.cache[key]["a"]
        est = estimate(prompt, job)
        self.report["estimate"] += est
        if self.dry: return None
        if self.spent() + est > self.cap:
            self.report["capped"] = True
            return None
        out, usd = self.ask_fn(prompt, tier, job)
        self.report["calls"] += 1; self.report["usd"] += usd
        self.spend[self.day] = round(self.spent() + usd, 5)
        _write_json(self.dir / "spend.json", {k: v for k, v in self.spend.items() if k >= (datetime.fromtimestamp(self.now) - timedelta(days=60)).strftime("%Y-%m-%d")})
        if out:
            self.cache[key] = {"a": out, "t": self.now}
            if len(self.cache) > 3000:
                for k in sorted(self.cache, key=lambda k: self.cache[k]["t"])[:len(self.cache) - 3000]: del self.cache[k]
            _write_json(self.dir / "cache.json", self.cache)
        return out

    def note(self, job, **kw): self.report["jobs"].setdefault(job, {}).update(kw)


# ---- what the jobs read ---------------------------------------------------------------------------------------------

def known_names(data):
    """Project and person names from the entity store (names only; private records skipped)."""
    d = _read_json(Path(data) / "entities.json", {})
    recs = (d.get("records") or d.get("entities") or []) if isinstance(d, dict) else []
    out = {"project": [], "person": []}
    for r in recs if isinstance(recs, list) else []:
        if not isinstance(r, dict) or r.get("private"): continue
        k = r.get("kind")
        if k in out and r.get("name"): out[k].append((float(r.get("heat") or 0), str(r["name"])))
    return {k: [n for _, n in sorted(v, reverse=True)[:80]] for k, v in out.items()}


def journal_items(data, since, until):
    """The journal's raw items in a time span: typed lines, voice takes, copies. id = src:t (ms)."""
    out = []
    for src, name in (("typed", "typed.jsonl"), ("said", "takes.jsonl"), ("copied", "clipboard.jsonl")):
        for r in _rows(Path(data) / name, since):
            t = float(r.get("t") or 0)
            text = str(r.get("text") or "").strip()
            if t >= until or len(text) < 3: continue
            out.append({"id": f"{src}:{int(t * 1000)}", "src": src, "t": t, "app": str(r.get("app") or "")[:40], "text": text})
    return sorted(out, key=lambda r: r["t"])


def call_dirs(data, since):
    out = []
    for d in sorted((Path(data) / "calls").glob("*/")):
        tr = d / "transcript.txt"
        if tr.exists() and tr.stat().st_mtime >= since and tr.stat().st_size > 200: out.append(d)
    return out


def source_items(since):
    """Mail and chats from engine/sources.py (drafter-sources); [] until it lands."""
    try:
        import sources
        return list(sources.items(since=since, include_theirs=True))
    except Exception:
        return []


# ---- the jobs -------------------------------------------------------------------------------------------------------

def job_tags(o, since=None):
    store = _read_json(o.dir / "tags.json", {})
    since = day_start(o.now) - 86400 if since is None else since     # yesterday and today: the nightly run sees all of yesterday
    items = [it for it in journal_items(o.data, since, o.now) if it["id"] not in store]
    names = known_names(o.data)
    done = 0
    for i in range(0, len(items), TAG_BATCH):
        part = items[i:i + TAG_BATCH]
        lines = "\n".join(f"{n}\t{it['src']}\t{it['app']}\t{it['text'][:ITEM_CHARS]}".replace("\r", " ") for n, it in enumerate(part))
        prompt = ("Tag each journal item of one person's day (things he typed, said or copied). For each give a short "
                  "topic (2-4 words, English), the project it belongs to and the person it is about or addressed to. "
                  "Use a name from the lists when one fits, else a short new one, else an empty string. Do not guess.\n"
                  f"Known projects: {', '.join(names['project']) or '-'}\nKnown people: {', '.join(names['person']) or '-'}\n\n"
                  "Items (number, source, app, text):\n" + lines +
                  '\n\nAnswer with JSON only: [{"i": 0, "topic": "", "project": "", "person": ""}, ...] one per item.')
        ans = parse_json(o.ask(prompt, "tags"))
        if not isinstance(ans, list): continue
        for a in ans:
            if not isinstance(a, dict) or not isinstance(a.get("i"), int) or not 0 <= a["i"] < len(part): continue
            it = part[a["i"]]
            store[it["id"]] = {"t": it["t"], "src": it["src"], **{k: str(a.get(k) or "")[:60] for k in ("topic", "project", "person")}}
            done += 1
    if done: _write_json(o.dir / "tags.json", store)
    o.note("tags", items=len(items), tagged=done)


def job_calls(o):
    out_dir = o.dir / "calls"
    todo = [d for d in call_dirs(o.data, o.now - 8 * 86400)
            if not (out_dir / (d.name + ".json")).exists() or (out_dir / (d.name + ".json")).stat().st_mtime < (d / "transcript.txt").stat().st_mtime]
    done = 0
    for d in todo:
        text = (d / "transcript.txt").read_text(errors="replace")
        if TEST in text: continue
        meta = _read_json(d / "meta.json", {})
        prompt = ("Clean up the notes of one recorded " + ("call" if meta.get("call") else "voice note") + ". The transcript is "
                  "machine speech-to-text: fix obvious mishearings from context, keep names as written when unsure. The owner "
                  "of the recording is Andrii; 'me' lines are his, 'them' lines the other side when marked.\n"
                  "Answer with JSON only: {\"summary\": \"3-5 sentences\", \"decisions\": [\"...\"], "
                  "\"next_steps\": [{\"who\": \"\", \"what\": \"\", \"when\": \"\"}], \"said\": [{\"who\": \"\", \"points\": [\"...\"]}], "
                  "\"people\": [\"names mentioned\"], \"language\": \"uk|en|...\"}. Write in the transcript's language.\n\n"
                  "Transcript:\n" + text[-CALL_CHARS:])
        ans = parse_json(o.ask(prompt, "calls"))
        if not isinstance(ans, dict): continue
        ans["call"], ans["at"], ans["app"] = d.name, o.now, str(meta.get("app") or "")
        _write_json(out_dir / (d.name + ".json"), ans); done += 1
    o.note("calls", todo=len(todo), cleaned=done)


def job_people(o):
    items = [it for it in source_items(o.now - 7 * 86400) if TEST not in str(it.get("text", ""))]
    if not items: return o.note("people", skipped="no mail or chats yet (engine/sources.py)")
    by = {}
    for it in items:
        for w in it.get("who") or []:
            n = (w.get("name") or w.get("email") or "").strip()
            if n: by.setdefault(n, []).append(it)
    store = _read_json(o.dir / "people.json", {})
    top = sorted(by, key=lambda n: -len(by[n]))[:PEOPLE_MAX]
    done = 0
    for n in top:
        rows = sorted(by[n], key=lambda it: -float(it.get("t") or 0))[:PEOPLE_ITEMS]
        newest = max(float(it.get("t") or 0) for it in rows)
        if store.get(n, {}).get("newest", 0) >= newest: continue      # nothing new since the last card
        lines = "\n".join(f"- [{it.get('src')}, {'him' if it.get('mine') else 'them'}] {str(it.get('title') or '')[:80]}: "
                          f"{str(it.get('text') or '')[:500]}".replace("\r", " ") for it in rows)
        prompt = (f"From recent mail and chat lines with {n} (newest first), write a short person card for Andrii. Facts "
                  "only, nothing assessed; empty when the lines do not say. Answer with JSON only: {\"role\": \"\", "
                  "\"company\": \"\", \"now\": [\"what they are working on with him now\"], \"open\": [\"what waits, on whom\"], "
                  "\"facts\": [\"stable facts worth keeping\"]}.\n\n" + lines)
        ans = parse_json(o.ask(prompt, "people"))
        if not isinstance(ans, dict): continue
        store[n] = {**{k: ans.get(k) for k in ("role", "company", "now", "open", "facts")}, "newest": newest, "at": o.now,
                    "from": [str(it.get("id")) for it in rows]}
        done += 1
    if done: _write_json(o.dir / "people.json", store)
    o.note("people", people=len(top), carded=done)


def job_snippets(o):
    lines = [r["text"] for r in _rows(o.data / "typed.jsonl", o.now - 7 * 86400) if 8 <= len(str(r.get("text", ""))) <= 400]
    if len(lines) < 20: return o.note("snippets", skipped="too few lines")
    seen = _read_json(o.dir / "snippet-ideas.json", {"ideas": [], "week": ""})
    week = datetime.fromtimestamp(o.now).strftime("%G-W%V")
    if seen.get("week") == week: return o.note("snippets", skipped="done this week")
    sn = _read_json(o.data / "snippets.json", [])
    have = list(sn)[:60] if isinstance(sn, dict) else []     # snippets.json: cue -> text; the cues are enough to skip them
    sample = lines[-300:]
    prompt = ("Below are messages one person typed this week. Find texts he types again and again that a snippet would "
              "save (an address, a link, a standard reply, a sign-off, an intro). At most 5; skip any already in his "
              f"snippets: {have or '-'}.\nAnswer with JSON only: [{{\"cue\": \"short trigger word\", \"text\": \"the snippet\", "
              "\"seen\": times}}].\n\n" + "\n".join(s.replace("\n", " ")[:300] for s in sample))
    ans = parse_json(o.ask(prompt, "snippets"))
    if isinstance(ans, list):
        _write_json(o.dir / "snippet-ideas.json", {"week": week, "at": o.now, "ideas": [a for a in ans if isinstance(a, dict)][:5]})
    o.note("snippets", lines=len(sample), ideas=len(ans) if isinstance(ans, list) else 0)


def ghost_pairs(data, since, until):
    """Each ghost he took (accepted.jsonl), with the line he then sent in that app within 10 minutes (typed.jsonl)."""
    typed = _rows(Path(data) / "typed.jsonl", since)
    out = []
    for a in _rows(Path(data) / "accepted.jsonl", since):
        t = float(a.get("t") or 0)
        if t >= until or not a.get("text"): continue
        before = str(a.get("before") or "")
        sent = next((r for r in typed if r.get("app") == a.get("app") and t <= float(r.get("t") or 0) <= t + 600), None)
        out.append({"t": t, "app": str(a.get("app") or "")[:40], "before": before[-300:], "ghost": str(a["text"])[:200],
                    "sent": str(sent.get("text") or "")[:400] if sent else "", "src": str(a.get("src") or "")})
    return out


def job_grades(o):
    path = o.dir / "ghost-grades.jsonl"
    graded = {round(float(r.get("t") or 0), 3) for r in _rows(path)}
    pairs = [p for p in ghost_pairs(o.data, day_start(o.now) - 86400, o.now) if round(p["t"], 3) not in graded]
    random.Random(int(o.now // 86400)).shuffle(pairs)
    pairs = pairs[:GRADE_SAMPLE]
    if not pairs: return o.note("grades", sample=0)
    lines = "\n".join(f"{n}\tapp={p['app']}\tbefore={p['before']!r}\tghost={p['ghost']!r}\tsent={p['sent']!r}" for n, p in enumerate(pairs))
    prompt = ("A small local model suggests the next words while a person types (the ghost); he took each of these. "
              "Grade each ghost: good when it says what he meant in his own way (the sent line, when given, shows what he "
              "really sent), bad when he had to fix it, it is generic filler, or it changes the meaning. One short reason.\n\n"
              + lines + '\n\nAnswer with JSON only: [{"i": 0, "good": true, "why": ""}, ...]')
    ans = parse_json(o.ask(prompt, "grades"))
    n = 0
    if isinstance(ans, list):
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            for a in ans:
                if isinstance(a, dict) and isinstance(a.get("i"), int) and 0 <= a["i"] < len(pairs) and isinstance(a.get("good"), bool):
                    f.write(json.dumps({**pairs[a["i"]], "good": a["good"], "why": str(a.get("why") or "")[:160], "at": o.now}, ensure_ascii=False) + "\n")
                    n += 1
    o.note("grades", sample=len(pairs), graded=n)


def unanswered(items, now):
    """Chats and mail threads whose newest line is theirs, 1-7 days old (local rule, nothing sent)."""
    last = {}
    for it in items:
        k = it.get("chat") or it.get("title") or it.get("id")
        if k and float(it.get("t") or 0) >= float(last.get(k, {}).get("t") or 0): last[k] = it
    return [{"thread": str(it.get("title") or k)[:80], "src": it.get("src"), "who": [w.get("name") or w.get("email") for w in it.get("who") or []][:3],
             "t": it.get("t")} for k, it in last.items() if not it.get("mine") and 86400 <= now - float(it.get("t") or 0) <= 7 * 86400]


def job_review(o, force=False):
    last = sorted(o.dir.glob("review-*.json"))
    if last and not force and o.now - _read_json(last[-1], {}).get("at", 0) < 6 * 86400: return o.note("review", skipped="done this week")
    week = o.now - 7 * 86400
    tags = [v for v in _read_json(o.dir / "tags.json", {}).values() if float(v.get("t") or 0) >= week]
    count = lambda k: sorted(((sum(1 for v in tags if v.get(k) == x), x) for x in {v.get(k) for v in tags if v.get(k)}), reverse=True)[:12]
    calls = [c for c in (_read_json(p, {}) for p in (o.dir / "calls").glob("*.json")) if float(c.get("at") or 0) >= week]
    pf = _read_json(o.data / "promises.json", {})
    promises = [p for p in (pf.get("rows") or [] if isinstance(pf, dict) else []) if isinstance(p, dict) and not p.get("done")]
    threads = unanswered(source_items(week), o.now)
    facts = {"projects": count("project"), "people": count("person"), "topics": count("topic"),
             "calls": [{"call": c.get("call"), "summary": c.get("summary"), "decisions": c.get("decisions"), "next_steps": c.get("next_steps")} for c in calls][:12],
             "open_promises": [{"what": p.get("what"), "person": p.get("person"), "due": p.get("due")} for p in promises][:30],
             "unanswered": threads[:30]}
    prompt = ("Write Andrii's weekly review from these facts of his week (JSON below). Plain short English, no praise, "
              "no filler. Sections: Open promises (what he said he would do, oldest due first), Unanswered threads (who "
              "waits on him), What moved (by project, from the counts and the call notes), Next week (at most 5 lines). "
              "Leave a section out when it has nothing. Markdown, under 400 words.\n\n" + json.dumps(facts, ensure_ascii=False)[:30000])
    text = o.ask(prompt, "review")
    if text:
        day = datetime.fromtimestamp(o.now).strftime("%Y-%m-%d")
        (o.dir).mkdir(parents=True, exist_ok=True)
        (o.dir / f"review-{day}.md").write_text(text + "\n")
        _write_json(o.dir / f"review-{day}.json", {"at": o.now, "facts": facts})
    o.note("review", tags=len(tags), calls=len(calls), promises=len(promises), unanswered=len(threads), written=bool(text))


RUN = {"tags": job_tags, "calls": job_calls, "people": job_people, "snippets": job_snippets, "grades": job_grades, "review": job_review}


def allowed(st):
    """`backOffice` on (engine/cloud.py), a model connected, and the Mac online."""
    import cloud, router
    return cloud.allowed("backoffice", st) and router.online()


def run(jobs=None, st=None, data=DATA, ask=None, now=None, dry=False, force=False):
    """Run the batch. -> the report {calls, cached, usd, estimate, capped, jobs:{...}}. A dry run sends nothing and
    estimates what the batch would cost; it still needs no switch."""
    st = _read_json(Path(data) / "settings.json", {}) if st is None else st
    if not dry and not force and not allowed(st): return {"skipped": "off or offline"}
    if not _lock.acquire(blocking=False): return {"skipped": "already running"}
    state["running"] = True
    try:
        o = Office(data, cap=float(st.get("backOfficeCap") or DEFAULT_CAP), ask=ask, now=now, dry=dry)
        for j in [j for j in (jobs or JOBS) if j in RUN]:
            if o.report["capped"]: break
            try: RUN[j](o)
            except Exception as e: o.note(j, error=type(e).__name__)
        o.report["usd"], o.report["estimate"] = round(o.report["usd"], 4), round(o.report["estimate"], 4)
        o.report["today"] = round(o.spent(), 4)
        o.report["at"] = o.now
        if not dry: _write_json(o.dir / "last.json", o.report)
        state["last"] = o.report
        return o.report
    finally:
        state["running"] = False; _lock.release()


def status(data=DATA, now=None):
    d = Path(data) / "backoffice"
    day = datetime.fromtimestamp(now or time.time()).strftime("%Y-%m-%d")
    return {"running": state["running"], "last": _read_json(d / "last.json", None),
            "today": float(_read_json(d / "spend.json", {}).get(day, 0.0))}


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="The Claude back office batch")
    ap.add_argument("--jobs", default=",".join(JOBS))
    ap.add_argument("--dry-run", action="store_true", help="send nothing; count items and estimate the cost")
    ap.add_argument("--nightly", action="store_true", help="the nightly run: needs the switch, skips quietly when off")
    a = ap.parse_args()
    r = run([j.strip() for j in a.jobs.split(",") if j.strip()], dry=a.dry_run)
    print(json.dumps(r, ensure_ascii=False))
