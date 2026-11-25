"""Round five (2026-11-14): the app's own request pattern against an engine from this checkout, on a key clock.

His keys come every `--gap` ms whatever the engine does (bench/stream_speed.py waits for each answer instead). At each
key the app asks at once (Keys.predict); the debounced ask 35 ms later went out again when the first answer had
already come (`--dup`, the app before round five) and stays home now (no `--dup`). Measured per key: time from the key
to the first grey text, whether the engine had the answer ready (look-ahead or a word branch made in the gap), and
answers that came after the next key (late). Never the live engine.

    DRAFTER_PORT=8799 DRAFTER_OWNED=0 DRAFTER_PEOPLE=0 DRAFTER_ADAPTER=<live adapters> .venv/bin/python engine/server.py &
    .venv/bin/python -B bench/key_clock.py [--n 8] [--keys 40] [--gap 150] [--dup]
"""
import argparse, http.client, json, statistics, threading, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AI = ("claude", "chatgpt", "codex")


def ask(port, body, out):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    t0 = time.perf_counter()
    c.request("POST", "/complete", json.dumps(body), {"Content-Type": "application/json"})
    r = c.getresponse()
    for raw in r:
        j = json.loads(raw)
        t = j.get("part") or j.get("text") or ""
        if t and "first" not in out: out["first"] = (time.perf_counter() - t0) * 1000
        if j.get("final"):
            out.update(end=(time.perf_counter() - t0) * 1000, ready=bool(j.get("ahead")), text=j.get("text") or "")
    c.close()
    out["done"] = True


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--keys", type=int, default=40)
    ap.add_argument("--gap", type=float, default=150)
    ap.add_argument("--dup", action="store_true", help="ask again 35 ms after the key when the first answer already came")
    ap.add_argument("--set", default="data/replay-fresh.json")
    ap.add_argument("--tail", type=float, default=0.3, help="the AI-app tail bar the app sends (0.2 before round five)")
    a = ap.parse_args()
    assert a.port != 8798, "never the live engine"
    items = json.loads((ROOT / a.set).read_text())[: a.n]
    rows, dups = [], 0
    for it in items:
        ai = any(k in it["app"].lower() for k in AI)
        for pos in range(2, min(len(it["text"]), a.keys)):
            body = {"before": it["text"][:pos], "app": it["app"], "title": "", "context": it.get("context", ""), "max_tokens": 10,
                    "chips": False, "min_letters": 5, "early": False, "stream": True}
            if ai: body.update(tail=a.tail, tail_words=8)
            key = time.perf_counter()
            out = {}
            th = threading.Thread(target=ask, args=(a.port, body, out)); th.start()
            time.sleep(0.037)
            if a.dup and out.get("done"):
                dups += 1; ask(a.port, body, {})
            th.join()
            rows.append(dict(out, src=it["app"]))
            left = a.gap / 1000 - (time.perf_counter() - key)
            if left > 0: time.sleep(left)
    shown = [r for r in rows if r.get("text")]
    q = lambda xs, p: round(sorted(xs)[min(len(xs) - 1, int(len(xs) * p))], 1) if xs else None
    firsts = [r["first"] for r in shown if "first" in r]
    ready = sum(r["ready"] for r in rows); ready_shown = sum(r["ready"] for r in shown)
    late = sum(1 for r in shown if r.get("first", 0) > a.gap)
    print(f"{'dup' if a.dup else 'once'} gap {a.gap:.0f}: keys {len(rows)}, asked again {dups}; answers ready {ready} of {len(rows)} "
          f"({100 * ready / max(1, len(rows)):.0f}%); ghosts {len(shown)}, ready {ready_shown} ({100 * ready_shown / max(1, len(shown)):.0f}%), "
          f"first grey text p50 {q(firsts, .5)} p90 {q(firsts, .9)} ms, after the next key {late}")
