"""Idle ghost step 7b: what the chat-form idle prompt costs his next key on the same screen. Per made-up chat: a typing
request (the screen is warm), an idle request in the chat form (its own cache slot), then the typing request again;
the last one's time against the first. Under the guard:

    .venv/bin/python -B bench/weights/guarded.py 6 bench/idle_switch.py --policy-mode current-2026-11-16 [--n 8] [--shared]

--shared: the idle prompt on the typing cache (no slot of its own), for the comparison.
"""
import argparse, json, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))
import request_policy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--shared", action="store_true")
    request_policy.add_argument(ap, request_policy.CURRENT)
    a = ap.parse_args()
    policy = request_policy.build(a.policy_mode)
    rows = [r for r in json.loads((ROOT / "bench/idle_set.json").read_text()) if not r["before"]][:a.n]
    import server
    if a.shared: server.IDLE_SCREEN = None
    out = []
    for r in rows:
        base = dict(policy.request, app=r["app"], title="chat", context=r["context"], ahead=False, chips=False, early=False, fix=False, keep_on=False)
        typed = r["next"].split()[0] + " "

        def ask(**k):
            t = time.perf_counter(); server._complete(dict(base, **k), seq=server.request_seq()); return round((time.perf_counter() - t) * 1000)
        ask(before=typed)                                         # the screen warms up (as focus prefill does live)
        warm = ask(before=typed)
        idle = ask(before="", idle=True, idle_bar=0.0)
        after = ask(before=typed)
        out.append({"warm_ms": warm, "idle_ms": idle, "after_idle_ms": after})
        print(r["lang"], out[-1], flush=True)
    s = lambda k: sorted(x[k] for x in out)
    print(json.dumps({k: {"p50": s(k)[len(out) // 2], "max": s(k)[-1]} for k in out[0]}), flush=True)
    import os; os._exit(0)


if __name__ == "__main__":
    main()
