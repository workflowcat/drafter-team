"""Today's typo and layout fix, measured from data/app.log (2026-11-15). Numbers only: the log holds no words.

Each automatic fix ("autocorrect <kind> N -> M chars", N and M count the word with its punctuation and the space) ends in
one of: taken back (Backspace right after, "autocorrect taken back"), undone later (a click or Tab on its dotted line),
kept by a fast Backspace that was his own edit ("autocorrect kept, backspace ... is his own"), or kept. Offers
("fix offer space|word <kind> taken|typed|expired") are counted as they are. Mid-word ghosts before 13 November:
"shown <app> Nms fix <kind>" and "fix taken <kind>". The app of an event is the bundle of the nearest earlier line that
names one (within 60 s), sorted into ai / chat / mail / other as app/AppKind.swift does (browsers count as other).

    .venv/bin/python -B bench/typo_log.py [--json out.json] [--data data]
"""
import argparse, gzip, json, re
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AI = {"com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.perplexity.mac"}
CHAT = {"com.automattic.beeper.desktop", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram"}
MAIL = {"com.apple.mail", "com.superhuman.electron", "com.readdle.SparkDesktop", "com.mimestream.Mimestream", "com.microsoft.Outlook"}
BUNDLE = re.compile(r"^(?:shown|ghost|proofread|quiet) ([a-zA-Z0-9.-]+\.[a-zA-Z0-9.-]+)")
AUTO = re.compile(r"^autocorrect (typo|layout uk|layout en) (\d+) -> (\d+) chars")
BACK = re.compile(r"^autocorrect taken back \((typo|layout uk|layout en)\)")
OWN = re.compile(r"^autocorrect kept, backspace \d+ms is his own \((typo|layout uk|layout en)\)")
UNDO = re.compile(r"^autocorrect undone by (tab|click) \((typo|layout uk|layout en)\)")
EDITED = re.compile(r"^autocorrect take-back not counted: edited")
OFFER = re.compile(r"^fix offer (space|word) (typo|layout uk|layout en) (taken|typed|expired|changed)")
MID_SHOWN = re.compile(r"^shown ([a-zA-Z0-9.-]+) \d+ms fix (typo|layout uk|layout en)")
MID_TAKEN = re.compile(r"^fix taken (typo|layout uk|layout en) (\d+) -> (\d+) chars")


def kind_of(bundle):
    if bundle in AI: return "ai"
    if bundle in CHAT: return "chat"
    if bundle in MAIL: return "mail"
    return "other" if bundle else "unknown"


def lines(paths):
    for p in paths:
        opener = gzip.open if p.suffix == ".gz" else open
        with opener(p, "rt", errors="replace") as f:
            for l in f:
                t, _, rest = l.rstrip("\n").partition(" ")
                try: at = datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
                except ValueError: continue
                yield at, rest


def edit_of(n, m):
    d = m - n
    return {0: "same length (wrong key or swap)", 1: "letter added (missing letter)", -1: "letter removed (extra or doubled)"}.get(d, "2+ letters")


def length_of(n):
    w = n - 1
    return "3-4" if w <= 4 else "5-6" if w <= 6 else "7-9" if w <= 9 else "10+"


def events(paths):
    """Automatic fixes with their outcome, offers, mid-word ghosts. Numbers and kinds only."""
    autos, offers, mids = [], [], []
    bundle, bundle_at, open_fix = "", 0.0, None
    for at, rest in lines(paths):
        if m := BUNDLE.match(rest): bundle, bundle_at = m.group(1), at
        app = bundle if at - bundle_at < 60 else ""
        if m := AUTO.match(rest):
            open_fix = {"t": at, "kind": m.group(1), "n": int(m.group(2)), "m": int(m.group(3)), "app": kind_of(app),
                        "bundle": app, "out": "kept"}
            autos.append(open_fix); continue
        if open_fix is not None:
            if (m := BACK.match(rest)) and at - open_fix["t"] <= 9: open_fix["out"] = "taken back"; open_fix["back_t"] = at
            elif (m := OWN.match(rest)) and at - open_fix["t"] <= 9: open_fix["out"] = "kept (his fast backspace)"
            elif (m := UNDO.match(rest)) and open_fix["out"] == "kept" and at - open_fix["t"] <= 120: open_fix["out"] = "undone later"
            elif EDITED.match(rest) and open_fix["out"] == "taken back": open_fix["out"] = "taken back, then edited"
        if m := OFFER.match(rest): offers.append({"t": at, "src": m.group(1), "kind": m.group(2), "out": m.group(3), "app": kind_of(app)})
        elif m := MID_SHOWN.match(rest): mids.append({"t": at, "kind": m.group(2), "out": "shown", "app": kind_of(m.group(1))})
        elif m := MID_TAKEN.match(rest):
            if mids and mids[-1]["out"] == "shown" and at - mids[-1]["t"] < 15: mids[-1]["out"] = "taken"
    return autos, offers, mids


def table(rows, key):
    out = defaultdict(Counter)
    for r in rows: out[key(r)][r["out"]] += 1
    return {k: dict(v) for k, v in sorted(out.items())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(ROOT / "data"))
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    data = Path(a.data)
    paths = sorted((data / "logs").glob("app-*.log.gz")) + [data / "app.log"]
    autos, offers, mids = events(paths)
    typos = [e for e in autos if e["kind"] == "typo"]
    lay = [e for e in autos if e["kind"] != "typo"]
    rep = {
        "span": [datetime.fromtimestamp(autos[0]["t"]).date().isoformat(), datetime.fromtimestamp(autos[-1]["t"]).date().isoformat()] if autos else [],
        "automatic typo fixes": dict(Counter(e["out"] for e in typos)), "typo n": len(typos),
        "typo by length": table(typos, lambda e: length_of(e["n"])),
        "typo by edit": table(typos, lambda e: edit_of(e["n"], e["m"])),
        "typo by app kind": table(typos, lambda e: e["app"]),
        "layout fixes": table(lay, lambda e: e["kind"]),
        "layout by app kind": table(lay, lambda e: e["app"]),
        "offers at space": table([o for o in offers if o["src"] == "space"], lambda o: o["kind"]),
        "offers mid-word (since 13 Nov)": table([o for o in offers if o["src"] == "word"], lambda o: o["kind"]),
        "mid-word ghosts (before 13 Nov)": table(mids, lambda o: o["kind"]),
        "mid-word ghosts by app kind": table(mids, lambda o: o["app"]),
        "typo fixes by day": table(typos, lambda e: datetime.fromtimestamp(e["t"]).date().isoformat()),
    }
    print(json.dumps(rep, indent=1, ensure_ascii=False))
    if a.json: Path(a.json).write_text(json.dumps({"autos": autos, "offers": offers}, ensure_ascii=False))


if __name__ == "__main__":
    main()
