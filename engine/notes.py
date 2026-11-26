"""Long notes (idea 4): a long voice take becomes a note with a title, the people and projects from the dictionary it
talks about, and the follow-ups said in it. Saved as data/notes/*.md."""
import json, re, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "actions"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import local
NOTES = ROOT / "data/notes"
FOLLOW = re.compile(r"(?i)\b(треба|потрібно|нагадай|фоловап|follow[- ]?up|не забути|написати|подзвонити|need to|have to|remind|call|send)\b")


def names():
    """(name, is a person) from the shared dictionary."""
    try: d = json.loads((ROOT / "data/words.json").read_text())
    except Exception: return []
    import dictionary   # tiny words are never names ("The" as someone's short name)
    return [(w["text"], w.get("kind") == "name") for w in d.get("words", [])
            if w.get("kind") in ("name", "project") and len(w["text"]) >= 3 and w["text"].lower() not in dictionary.STOP]


LAT = dict(zip("абвгґдезиіїйклмнопрстуфхцчшщьюяєжʼ'’", ["a","b","v","h","g","d","e","z","y","i","i","i","k","l","m","n","o","p","r","s","t","u","f","kh","ts","ch","sh","shch","","yu","ya","ye","zh","","",""]))


def latin(s):
    return "".join(LAT.get(ch, ch) for ch in s.lower())


def where(name, text, person=True):
    """How the name shows in the text, or None. The whole name anywhere; for people also a capitalized word with another
    ending, read in Latin letters too (Савою -> savoyu ~ Sava, Мілі ~ Mila), never a lowercase word ("про" is not Prof)."""
    n = name.lower()
    for low in (text.lower(), latin(text)):
        if re.search(r"(?<![\w])" + re.escape(n) + r"(?![\w])", low): return n
    first = n.split()[0]
    if not person or len(first) < 4: return None
    stem = first[: max(3, len(first) - 2)]
    for w in re.findall(r"\w+", text):
        if w[:1].isupper() and len(w) <= len(first) + 3 and (w.lower().startswith(stem) or latin(w).startswith(stem)):
            return stem
    return None


def seen(name, text):
    low, n = text.lower(), name.lower()
    if re.search(r"(?<![\w])" + re.escape(n) + r"(?![\w])", low): return True
    first = n.split()[0]
    if len(first) < 4: return False
    stem = first[: max(3, len(first) - 2)]
    return re.search(r"(?<![\w])" + re.escape(stem) + r"\w{0,3}(?![\w])", low) is not None


OWN = tuple(local.user("own_stems") or ()) or ("\0",)   # the user's own name stems (local config): in his notes that is him, never a namesake (2026-10-30)


def forms(name, text):
    """The words in the text a person's first name was found by (Савою for Sava), as `where` finds them."""
    first = name.lower().split()[0]
    if len(first) < 4: return set()
    stem = first[: max(3, len(first) - 2)]
    words = re.findall(r"\w+", text)
    plain = {w for w in words if w[:1].islower()}   # «Тільки» opening a sentence is «тільки» elsewhere, not Till
    return {w for w in words if w[:1].isupper() and w.lower() not in plain and len(w) <= len(first) + 3
            and (w.lower().startswith(stem) or latin(w).startswith(stem))}


def clear(found, text):
    """Drop first-name guesses that are not evidence. The 22 October call (re-read 2026-10-30) linked Andrew P., Andrés
    and Andy because they said «Андрій» (him), and Marko because of «Марта»: a word a whole name explains, his own
    name, or a word that fits two or more people links nobody by its first letters."""
    whole = [n for n, st in found if st == n.lower()]
    taken = {n.lower() for n in whole} | {latin(n) for n in whole}
    partial = {n: {w for w in forms(n, text) if w.lower() not in taken and latin(w) not in taken and not latin(w).startswith(OWN)}
               for n, st in found if st != n.lower()}
    fits = {}
    for n, ws in partial.items():
        for w in ws: fits.setdefault(w, set()).add(n.lower())
    return [(n, st) for n, st in found if st == n.lower() or any(len(fits[w]) == 1 for w in partial[n])]


def links(text):
    """People and projects the note talks about: dictionary names found in it, at most 6."""
    out, stems = [], set()
    known = names()
    person = dict(known)
    found = clear([(n, s) for n, p in known if (s := where(n, text, p))], text)
    # whole names first (Sava before Sava Example by stem), and each first name links once
    found = sorted([f for f in found if f[1]], key=lambda f: f[1] != f[0].lower())
    for n, st in found:
        key = n.lower().split()[0]
        if key in stems: continue
        stems.add(key); out.append({"name": n, "kind": "person" if person.get(n) else "project"})
        if len(out) >= 6: break
    return out


def followups(text):
    sents = re.split(r"(?<=[.!?])\s+|\n", text)
    return [s.strip() for s in sents if FOLLOW.search(s) and 3 <= len(s.split()) <= 40][:6]


import integrations
CLAUDE = (integrations.claude_bin() if integrations.available("claude") else "") or "/nonexistent/claude"


def claude_summary(text):
    """The final call summary by Claude (Haiku, the logged-in `claude` CLI): far better than the local 1.7B at this.
    Only the transcript text goes; the recording stays on the Mac. None when it fails (then the local model does it)."""
    import os, subprocess
    prompt = ("Below is a call transcript (Я = " + local.short_name() + "; Вони, Speaker 2, Speaker 3... or a name = people "
              "on the other side; unknown = a line not placed on anyone, never assume it is " + local.short_name() + "). In the language of the call, return only JSON: "
              '{"title": "3-7 words", "points": ["up to 6 key points and decisions"], "todos": ["up to 6 actions as \'who: what\', '
              'only ones actually agreed in the call"]}. Do not invent anything.\n\nTranscript:\n' + text[-30000:])
    try:
        import claude_worker
        out = claude_worker.ask(prompt, 120) or ""
        m = re.search(r"\{.*\}", out, re.S)
        return json.loads(m.group(0)) if m else None
    except Exception as e:
        print("notes: claude summary", e, flush=True)
        return None


def summary(text, ask, cloud=False):
    """For a call: main points and to-dos (with who), from the transcript. Claude first when `cloud` (server:
    claude_on("call_notes"), the `callNotes` switch and online), the local model if that is off or fails."""
    d = claude_summary(text) if cloud else None
    if d and (d.get("points") or d.get("todos")):
        return [str(x) for x in d.get("points") or []][:6], [str(x) for x in d.get("todos") or []][:6]
    try:
        t = ask("Ось розшифровка дзвінка (Я — Андрій; Вони, Speaker 2, Speaker 3 або ім'я — співрозмовники; unknown — не визначено хто). Мовою розмови дай JSON: points (до 6 головних "
                "пунктів і рішень), todos (до 6 справ: хто що робить). Лише JSON.\nРозшифровка:\n" + text[-9000:], 420)
        m = re.search(r"\{.*\}", t, re.S)
        d = json.loads(m.group(0)) if m else {}
        return [str(x) for x in (d.get("points") or [])][:6], [str(x) for x in (d.get("todos") or [])][:6]
    except Exception:
        return [], []


def make(text, ask, audio="", call=False, dry=False, event=None, cloud=False):
    """-> the note as saved: title, links, follow-ups, where it went. `event` is the calendar event the recording
    belongs to ({title, people}): its title names the note and its people are linked (2026-10-29). `cloud`: the call
    summary may go to Claude (server passes claude_on("call_notes")); False keeps it on the local model."""
    event = event or {}
    title = (event.get("title") or "").strip()
    if not title:
        try:
            t = ask("Дай коротку назву (3-7 слів, мовою тексту, без лапок і крапки) для цієї нотатки. Відповідай лише JSON {\"title\": \"...\"}.\n"
                    "Нотатка:\n" + text[:3000], 60)
            m = re.search(r'"title"\s*:\s*"([^"]+)', t); title = m.group(1).strip() if m else ""
        except Exception:
            pass
    title = title or " ".join(text.split()[:6])
    people = [p for p in event.get("people") or [] if isinstance(p, str)]
    ln, fu = links(text + ("\n" + ", ".join(people) if people else "")), followups(text)
    points, todos = summary(text, ask, cloud) if call else ([], [])
    if todos: fu = todos
    saved = []
    if dry: return {"title": title, "links": ln, "followups": fu, "points": points, "saved": []}   # tests: nothing kept
    NOTES.mkdir(parents=True, exist_ok=True)
    slug = re.sub(r"[^\w-]+", "-", title.lower()).strip("-")[:50] or "note"
    f = NOTES / f"{time.strftime('%Y-%m-%d-%H%M')}-{slug}.md"
    f.write_text(f"# {'Дзвінок: ' if call else ''}{title}\n\n" + (f"Про: {', '.join(l['name'] for l in ln)}\n\n" if ln else "")
                 + ("## Головне\n" + "\n".join("- " + p for p in points) + "\n\n## Розшифровка\n" if call else "") + text + "\n"
                 + ("\n## Фоловапи\n" + "\n".join("- " + x for x in fu) + "\n" if fu else "") + (f"\nЗапис: {audio}\n" if audio else ""))
    saved.append(str(f.relative_to(ROOT)))
    return {"title": title, "links": ln, "followups": fu, "points": points, "saved": saved}
