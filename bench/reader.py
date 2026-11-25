"""Reader check bench (engine/reader.py, 17 November 2026): made-up chat lines, one planted slip each, checked
against his word counts (read in-process from data/, nothing printed but numbers). Reports slips found, wrong fixes,
words changed on the clean lines and the time per check. No model, nothing sent.

    .venv/bin/python -B bench/reader.py [--data data]
"""
import argparse, random, statistics, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))

# made-up lines in the way chats go (none of his)
CLEAN = """привіт, як справи
давай завтра після обіду созвонимось
я подивився документи, там все нормально
можемо перенести зустріч на п'ятницю
надішли будь ласка рахунок за жовтень
дякую, все отримав
тіки шо побачив повідомлення
ок, зроблю сьогодні ввечері
слухай, а коли буде готовий макет
норм, тоді чекаю від тебе відповідь
я зараз в дорозі, буду через годину
треба ще раз перевірити договір
скинь посилання на документ
давай обговоримо це на дзвінку
мені здається це гарна ідея
сьогодні не встигну, давай завтра
подивись будь ласка коли буде час
все добре, дякую що написав
можеш скинути презентацію
я вже відправив листа клієнту
hey, can we move the call to tomorrow
thanks, I will check the document today
sounds good, let me know when it is ready
I sent the invoice yesterday
can you share the link to the meeting
let's discuss it on the call
I think the plan works for me
please send me the final version
I will be there in ten minutes
no worries, we can do it next week""".splitlines()

EN_KEYS = "qwertyuiop[]asdfghjkl;'zxcvbnm,."
UK_KEYS = "йцукенгшщзхїфівапролджєячсмитьбю"
TO_EN = dict(zip(UK_KEYS, EN_KEYS))


def plant(line, rnd):
    """-> (line with one slip, the word as it was, the slipped word, kind)."""
    words = [w for w in line.replace(",", " ").split() if len(w) >= 5 and w.isalpha()]
    w = rnd.choice(words)
    kind = rnd.choice(["drop", "swap", "double", "wrong", "layout"])
    i = rnd.randrange(1, len(w) - 1)
    if kind == "drop": s = w[:i] + w[i + 1:]
    elif kind == "swap": s = w[:i] + w[i + 1] + w[i] + w[i + 2:]
    elif kind == "double": s = w[:i] + w[i] + w[i:]
    elif kind == "wrong":
        alpha = "abcdefghijklmnopqrstuvwxyz" if w.isascii() else "абвгдеєжзиіїйклмнопрстуфхцчшщьюя"
        s = w[:i] + rnd.choice([c for c in alpha if c != w[i]]) + w[i + 1:]
    else:
        if w.isascii(): kind = "swap"; s = w[:i] + w[i + 1] + w[i] + w[i + 2:]
        else: s = "".join(TO_EN.get(c, c) for c in w)
    return line.replace(w, s, 1), w, s, kind


MAC = """import AppKit
let c = NSSpellChecker.shared
while let w = readLine() {
    let lang = w.unicodeScalars.contains { $0.value >= 0x400 && $0.value < 0x500 } ? "uk" : "en"
    print(c.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound ? 1 : 0)
}
"""


def mac_known(ws):
    """The app's filter (ReaderRules.keep with Spell.known): which words the Mac's spellchecker knows."""
    import subprocess, tempfile
    ws = sorted(set(ws))
    if not ws: return set()
    f = Path(tempfile.mkdtemp()) / "known.swift"; f.write_text(MAC)
    out = subprocess.run(["swift", str(f)], input="\n".join(ws) + "\n", capture_output=True, text=True, timeout=120).stdout.split()
    return {w for w, k in zip(ws, out) if k == "1"}


def score(rows, drop=frozenset()):
    found = wrong = missed = 0; by = {}
    for kind, w, s, edits in rows:
        edits = [e for e in edits if " " in e["old"] + e["new"] or e["old"] not in drop]
        hit = [e for e in edits if e["old"] == s]
        ok = bool(hit) and hit[0]["new"].lower() == w.lower()
        found += ok; wrong += (bool(hit) and not ok) + len([e for e in edits if e["old"] != s]); missed += not hit
        k = by.setdefault(kind, [0, 0]); k[0] += ok; k[1] += 1
    return found, wrong, missed, by


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--data", default=str(ROOT.parent.parent / "data") if ROOT.parent.name == ".worktrees" else str(ROOT / "data"))
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--no-mac", action="store_true", help="skip the app's spellchecker filter")
    a = ap.parse_args()
    import words, word_fixes, reader
    words.DATA = Path(a.data); word_fixes.DATA = Path(a.data)
    t = time.time(); W = words.Words(); W.load(); load_s = time.time() - t
    kept = reader.keep()
    rnd = random.Random(17)
    ms, rows, clean = [], [], []
    for _ in range(a.rounds):
        for line in CLEAN:
            bad, w, s, kind = plant(line, rnd)
            if bad == line: continue
            t = time.perf_counter(); r = reader.check(bad, "", W, kept); ms.append((time.perf_counter() - t) * 1000)
            rows.append((kind, w, s, r["edits"]))
    clean_words = 0
    for line in CLEAN:
        t = time.perf_counter(); r = reader.check(line, "", W, kept); ms.append((time.perf_counter() - t) * 1000)
        clean += r["edits"]; clean_words += len(line.split())
    q = statistics.quantiles(ms, n=20)
    print(f"his words loaded in {load_s:.1f}s; {len(ms)} checks")
    drops = [("engine alone", frozenset())]
    if not a.no_mac: drops.append(("with the app's spellchecker filter", frozenset(mac_known([e["old"] for _, _, _, es in rows for e in es] + [e["old"] for e in clean]))))
    for name, drop in drops:
        found, wrong, missed, by = score(rows, drop)
        n = len(rows)
        print(f"{name}: planted {n}, found {found} ({found / n:.0%}), wrong fixes {wrong}, missed {missed}; "
              f"clean lines {len([e for e in clean if ' ' in e['old'] + e['new'] or e['old'] not in drop])} of {clean_words} words changed")
        print("  by kind (found/planted): " + ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(by.items())))
    print(f"engine time per check: p50 {statistics.median(ms):.2f} ms, p95 {q[18]:.2f} ms, max {max(ms):.2f} ms")


if __name__ == "__main__":
    main()
