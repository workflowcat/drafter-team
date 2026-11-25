"""Names offered with the selector on (round "earlier", step 4): every key of made-up lines with made-up names, the
pack and his-words stand-ins made up too. Before the fix the selector path never asked the pack (0 offered); after,
words.know_only runs at each key the selector has nothing for. Counts: offered, right (the rest of the name he then
types), wrong per 1,000 keys. No model, no data/.

    .venv/bin/python -B bench/know_offer.py
"""
import re, sys, threading
from collections import Counter
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import know, words

NAMES = ["Zorvaldine", "Zolmira", "Brannoc", "Quillatra", "Mervosk", "Taldrin", "Ostrava Labs", "Vellicor", "Ludmyrka",
         "Hennacott", "Kervelle", "Pashtrin"]
OWN = {"zebra": 3, "zone": 6, "brand": 4, "quick": 5, "merge": 6, "table": 4, "today": 9, "very": 7, "lunch": 3,
       "hello": 8, "keep": 6, "pass": 5, "ok": 20, "monday": 4}
LINES = [
    "ask Zorvaldine about the invoice today", "Zolmira said the zone map is ready", "send it to Brannoc before lunch",
    "Quillatra will join the call on Monday", "Mervosk can merge it later", "Taldrin booked the table",
    "the deck from Ostrava Labs looks good", "Vellicor is very quick with replies", "Ludmyrka sent the photos",
    "Hennacott says hello", "Kervelle will keep the notes", "Pashtrin can pass it on", "Today is fine for me",
    "Monday works, Very good", "Zebra crossing near the station", "Brand book is in the folder", "Merge it after the review",
    "Keep it short please", "Hello all, quick update", "Pass the keys to Taldrin", "ok, Zolmira and Zorvaldine both agree",
    # capitalised words he has not typed before that start like a name: the wrong offers
    "Quilted jackets are back", "Talisman is a board game", "Velvet curtains for the hall", "Hennessy for the party",
]
MIN = 3      # shortGhosts: at least 3 letters


def pack():
    p = know.Pack()
    p.entries = [dict(name=n, kind="person" if " " not in n else "company", tokens=n.split(), aliases=[], forms=[],
                      heat=1, common=[], handles={}) for n in NAMES]
    return p


def finisher():
    pre = Counter()
    for w, n in OWN.items():
        for k in range(1, len(w) + 1): pre[w[:k]] += n
    return SimpleNamespace(lock=threading.Lock(), own_folded=Counter(OWN), own_prefix=pre)


def main():
    p, f = pack(), finisher()
    keys = offered = right = wrong = saved = 0
    names = sum(len(re.findall(r"\b(?:" + "|".join(n.split()[0] for n in NAMES) + r")\b", l)) for l in LINES)
    found = set()
    for li, line in enumerate(LINES):
        for i in range(1, len(line) + 1):
            before = line[:i]; keys += 1
            if before.endswith(" "): continue
            got = words.know_only(f, before, p)
            if not got or len(got) < MIN: continue
            offered += 1
            start = re.search(r"\S+$", before).start()
            if line[i:].startswith(got) and (i + len(got) == len(line) or not line[i + len(got)].isalnum()):
                right += 1
                if (li, start) not in found: found.add((li, start)); saved += len(got)   # taken at its first offer
            else: wrong += 1
    print(f"keys {keys}, names in the lines {names}")
    print(f"before: offered 0, names found 0")
    print(f"after: offered {offered} (right {right}, wrong {wrong} = {1000 * wrong / keys:.1f} per 1,000 keys), "
          f"names found {len(found)}/{names}, letters saved if taken at the first offer {saved} ({1000 * saved / keys:.0f} per 1,000 keys)")


if __name__ == "__main__":
    main()
