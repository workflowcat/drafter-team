"""Two-step ghost over HTTP (round two, 2026-11-13): replays held-out lines key by key against an engine started from
this checkout on another port (never the live one on 8798), the way the app asks (/complete with "stream": true,
min_letters 5, the AI-app tail), and times from sending the request to the first grey text (the first part, or the
answer when no part came) and to the whole ghost. One request at a time, as when he types slower than the engine.

    DRAFTER_PORT=8799 DRAFTER_OWNED=0 DRAFTER_PEOPLE=0 .venv/bin/python engine/server.py &   # then:
    .venv/bin/python bench/stream_speed.py [--port 8799] [--n 8] [--keys 40] [--no-tail]
"""
import argparse, http.client, json, statistics, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AI = ("claude", "chatgpt", "codex")


def ask(port, body):
    """-> (ms to the first text, ms to the end, first text, whole text)"""
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    t0 = time.perf_counter()
    c.request("POST", "/complete", json.dumps(body), {"Content-Type": "application/json"})
    r = c.getresponse()
    first = whole = None; first_text = ""; text = ""; timing = {}
    for raw in r:
        j = json.loads(raw)
        now = (time.perf_counter() - t0) * 1000
        t = j.get("part") or j.get("text") or ""
        if t and first is None: first, first_text = now, t
        if j.get("final"): whole, text, timing = now, j.get("text") or "", j.get("t") or {}
    c.close()
    return first, whole, first_text, text, timing


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--keys", type=int, default=40)
    ap.add_argument("--set", default="data/replay-fresh.json")
    ap.add_argument("--no-tail", action="store_true")
    ap.add_argument("--tail", type=float, default=0.3, help="the AI-app tail bar the app sends (0.2 before round five)")
    ap.add_argument("--ahead", action="store_true", help="let the engine work ahead after each ghost, as live")
    ap.add_argument("--gap", type=float, default=0, help="ms between keys, as he types (live median ~150)")
    ap.add_argument("--length", default=None, choices=["word", "phrase", "sentence"], help="long round: the app's ghostLength (sends length, floor 0.1, cap 24; no tail)")
    ap.add_argument("--futures", type=int, default=None, help="long round: futures per ghost the engine may prepare (with --ahead)")
    ap.add_argument("--roll", action="store_true", help="long round: after each ghost, wait --gap and ask for the text with the ghost taken (Tab to the next words)")
    ap.add_argument("--dump", default=None, help="write each key's answer (texts and times) to this JSON file, to compare two engines (bench/out only: it holds his text)")
    a = ap.parse_args()
    assert a.port != 8798, "never the live engine"
    items = json.loads((ROOT / a.set).read_text())[: a.n]
    firsts, wholes, two_step, grew, parts, dump = [], [], 0, 0, {}, []
    rolls, rolled_ahead, words = [], 0, []
    for it in items:
        ai = any(k in it["app"].lower() for k in AI)
        for pos in range(2, min(len(it["text"]), a.keys)):
            body = {"before": it["text"][:pos], "app": it["app"], "title": "", "context": it.get("context", ""), "max_tokens": 10,
                    "chips": False, "min_letters": 5, "early": False, "ahead": a.ahead, "memory": False, "stream": True}
            if ai and not a.no_tail and a.length in (None, "word"): body.update(tail=a.tail, tail_words=8)
            if a.length and a.length != "word": body.update(length=a.length, floor=0.1, cap=24)
            if a.futures is not None: body["futures"] = a.futures
            if a.gap: time.sleep(a.gap / 1000)
            f, w, ft, t, tm = ask(a.port, body)
            dump.append({"line": items.index(it), "pos": pos, "first": ft, "text": t, "first_ms": f, "end_ms": w, "t": tm})
            for k, v in tm.items(): parts.setdefault(k, []).append(v)
            if f is None or w is None: continue
            firsts.append(f); wholes.append(w)
            if a.roll and t:
                time.sleep(max(a.gap, 150) / 1000)          # he reads it, then Tab: the look-ahead had this long
                _, rw, _, rt, rtm = ask(a.port, dict(body, before=body["before"] + t))
                if rw is not None: rolls.append(rw); rolled_ahead += rw < 15
            two_step += f < w - 1
            words.append(len(t.split()))
            grew += len(t) > len(ft)
    q = lambda xs, p: sorted(xs)[int(len(xs) * p)]
    print(f"ghosts {len(firsts)}: first grey text p50 {statistics.median(firsts):.1f} p90 {q(firsts, .9):.1f} ms · whole p50 "
          f"{statistics.median(wholes):.1f} p90 {q(wholes, .9):.1f} ms · first text earlier than the end in {two_step}, grew after it in {grew}")
    print("engine split, p50 / p90 over gated answers: " + " · ".join(f"{k} {statistics.median(v):.0f}/{q(v, .9):.0f}" for k, v in parts.items()))
    print(f"words per ghost p50 {statistics.median(words) if words else 0} p90 {q(words, .9) if words else 0}")
    if rolls: print(f"Tab to the next words (whole ghost taken after {max(a.gap, 150):.0f} ms): p50 {statistics.median(rolls):.1f} p90 {q(rolls, .9):.1f} ms over {len(rolls)}, under 15 ms (prepared) {rolled_ahead}")
    try:
        c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=5); c.request("GET", "/health"); h = json.loads(c.getresponse().read())
        print(f"engine memory: mlx active {h.get('mlx_active_gb')} GB, peak {h.get('mlx_peak_gb')} GB, rss {h.get('rss_gb')} GB; ahead {h.get('ahead')}")
    except Exception as e: print("no /health:", e)
    if a.dump: Path(a.dump).write_text(json.dumps(dump, ensure_ascii=False))
