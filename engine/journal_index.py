"""Ask your day: search over the journal index the server built (bench/jobs.py, kind "index"), on the Mac.

data/jobs/journal-index/ holds vectors.npy (float16, one unit vector per item, multilingual-e5-small), items.json
({id, at, kind, tags}), tags.json and meta.json. A question is embedded here with the numpy encoder (engine/embed_np.py,
~90 MB while loaded, dropped after 2 min idle) and compared with every item: a dot product, no server, no network.
Without an index (the job has not run yet, or the model is not on this Mac) ask() returns {"ready": false} and the
journal's own search answers as before.

    .venv/bin/python -B engine/journal_index.py ask "what did we agree about the booklet" [--day 2026-11-17] [--k 8]
    .venv/bin/python -B engine/journal_index.py tags
    .venv/bin/python -B engine/journal_index.py fetch-model      # the encoder's files, once (online)"""
import json, os, sys, threading, time
from datetime import datetime
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import embed_np

IDLE_DROP = 120


def folder():
    return Path(os.environ.get("DRAFTER_DATA") or ROOT / "data") / "jobs" / "journal-index"


class Index:
    def __init__(self, path=None, encoder_folder=None):
        self.path = Path(path) if path else folder()
        self.encoder_folder = encoder_folder
        self._sig, self.vectors, self.items, self.tags, self.meta = None, None, [], [], {}
        self._enc, self._used, self._lock = None, 0.0, threading.Lock()

    def _load(self):
        f = self.path / "meta.json"
        sig = f.stat().st_mtime if f.exists() else None
        if sig == self._sig: return self.vectors is not None
        self._sig = sig
        if sig is None: self.vectors = None; return False
        self.vectors = np.load(self.path / "vectors.npy").astype(np.float32)
        self.items = json.loads((self.path / "items.json").read_text())
        self.tags = json.loads((self.path / "tags.json").read_text())
        self.meta = json.loads(f.read_text())
        return True

    def encoder(self):
        if self._enc is None:
            src = self.encoder_folder or embed_np.local_folder()
            if src is None: return None
            self._enc = embed_np.Encoder(src)
            threading.Thread(target=self._drop_when_idle, daemon=True).start()
        self._used = time.time()
        return self._enc

    def _drop_when_idle(self):
        while True:
            time.sleep(15)
            with self._lock:
                if time.time() - self._used > IDLE_DROP: self._enc = None; return

    def ask(self, q, day=None, k=8, tag=None):
        """-> {"ready", "hits": [{id, at, kind, tags, score}], "ms"}. day "YYYY-MM-DD" keeps that local day only."""
        t0 = time.perf_counter()
        with self._lock:
            if not self._load(): return {"ready": False, "why": "no index yet"}
            enc = self.encoder()
            if enc is None: return {"ready": False, "why": "the encoder is not on this Mac (journal_index.py fetch-model)"}
            v = enc.encode(["query: " + q.strip()])[0]
        s = self.vectors @ v
        keep = np.ones(len(s), bool)
        if day:
            keep &= np.array([datetime.fromtimestamp(it.get("at") or 0).strftime("%Y-%m-%d") == day for it in self.items])
        if tag:
            keep &= np.array([tag in it.get("tags", []) for it in self.items])
        idx = [i for i in np.argsort(-s) if keep[i]][:k]
        return {"ready": True, "ms": round((time.perf_counter() - t0) * 1000, 1),
                "hits": [{**self.items[i], "score": round(float(s[i]), 4)} for i in idx]}

    def tag_list(self):
        with self._lock:
            return self.tags if self._load() else []


INDEX = Index()


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("ask"); a.add_argument("q"); a.add_argument("--day"); a.add_argument("--k", type=int, default=8); a.add_argument("--tag")
    sub.add_parser("tags"); sub.add_parser("fetch-model")
    a = p.parse_args(argv)
    if a.cmd == "ask": print(json.dumps(INDEX.ask(a.q, a.day, a.k, a.tag), ensure_ascii=False, indent=1))
    elif a.cmd == "tags": print(json.dumps(INDEX.tag_list(), ensure_ascii=False, indent=1))
    else: print(embed_np.local_folder(online=True))


if __name__ == "__main__":
    main()
