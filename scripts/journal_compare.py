"""Compares data/typed.jsonl, takes.jsonl and clipboard.jsonl with data/journal.sqlite row by row (journal in SQLite,
phase 1, 23 November 2026). Read-only on both sides; prints numbers only, never a line's text. Exit 1 on any
difference. Its own reading of the files (not engine/journal_db.py): whole lines in file order against the live rows
in `seq` order; per row the SHA-256 of the line (computed again from the database's stored bytes too), the id and
the timestamp token as written.

    .venv/bin/python -B scripts/journal_compare.py [--data DIR] [--db PATH] [--tries 3] [--wait 5]

The engine follows the files every 2 s: a difference is checked again `--tries` times, `--wait` seconds apart, before
it counts (a line appended during the check is not a difference).
"""
import argparse
import hashlib
import json
import sqlite3
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORES = ("typed", "takes", "clipboard")


class _Raw(str):
    pass


def file_rows(path: Path):
    """[(sha, id, t token)] for every whole line; and 1 when the file ends inside a line."""
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return [], 0
    last = data.rfind(b"\n")
    lines = [l for l in data[:last].split(b"\n") if l] if last >= 0 else []
    out = []
    for l in lines:
        rid = tok = None
        try:
            j = json.loads(l.decode("utf-8"), parse_float=_Raw, parse_int=_Raw)
            if isinstance(j, dict):
                rid = j.get("id") if isinstance(j.get("id"), str) else None
                tok = str(j["t"]) if isinstance(j.get("t"), _Raw) else None
        except (UnicodeDecodeError, ValueError):
            pass
        out.append((hashlib.sha256(l).hexdigest(), rid, tok))
    return out, int(len(data) > last + 1)


def compare(data_dir: Path, db_path: Path) -> dict:
    if not db_path.exists():
        return {s: {"jsonl": len(file_rows(data_dir / f"{s}.jsonl")[0]), "db": 0, "diff": 1, "missing_db": 1} for s in STORES}
    db = sqlite3.connect(f"file:{db_path.as_posix()}?mode=ro", uri=True, timeout=5)
    try:
        out = {}
        for s in STORES:
            rows, partial = file_rows(data_dir / f"{s}.jsonl")
            live = db.execute("SELECT sha, id, t_raw, line FROM rows WHERE store=? AND removed_at IS NULL ORDER BY seq",
                              (s,)).fetchall()
            n = {"jsonl": len(rows), "db": len(live), "partial": partial, "order": 0, "hash": 0, "id": 0, "t": 0,
                 "stored": 0, "missing": 0, "extra": 0}
            fs, ds = [r[0] for r in rows], [r[0] for r in live]
            have = {}
            for h in ds:
                have[h] = have.get(h, 0) + 1
            for h in fs:
                if have.get(h, 0):
                    have[h] -= 1
                else:
                    n["missing"] += 1
            n["extra"] = sum(have.values())
            for (fh, fid, ft), (dh, did, dt, line) in zip(rows, live):
                if fh != dh:
                    n["order"] += 1
                    continue
                n["id"] += fid != did
                n["t"] += ft != dt
            for dh, _, _, line in live:
                n["stored"] += hashlib.sha256(bytes(line)).hexdigest() != dh
            n["hash"] = n["missing"] + n["extra"]
            n["diff"] = int(n["jsonl"] != n["db"]) + n["order"] + n["id"] + n["t"] + n["stored"] + n["hash"]
            out[s] = n
        return out
    finally:
        db.close()


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(ROOT / "data"))
    ap.add_argument("--db", default=None)
    ap.add_argument("--tries", type=int, default=3)
    ap.add_argument("--wait", type=float, default=5.0)
    a = ap.parse_args(argv)
    data = Path(a.data)
    db = Path(a.db) if a.db else data / "journal.sqlite"
    t0 = time.perf_counter()
    for i in range(max(1, a.tries)):
        res = compare(data, db)
        total = sum(v["diff"] for v in res.values())
        if not total:
            break
        if i + 1 < a.tries:
            time.sleep(a.wait)
    for s, v in res.items():
        print(s + ": " + " ".join(f"{k} {v[k]}" for k in v))
    print(f"journal compare {time.strftime('%Y-%m-%d %H:%M')}: differences {total} in {round((time.perf_counter() - t0) * 1000)} ms")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
