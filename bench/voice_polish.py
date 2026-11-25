"""Polished voice level (research item 3): time the live engine's /rewrite on 20 made-up takes, as the app sends them.

Loads no model: it asks the engine already running on 127.0.0.1:8798. Hold data/.bench.lock (mkdir) while it runs and
check memory first (memory_pressure free >= 25%, swap used < 8 GB). Prints p50 / p90 ms and how many answers the app
would keep (VoiceModeRules.accept), numbers only.
  .venv/bin/python -B bench/voice_polish.py
"""
import json, time, urllib.request

TAKES = [
    "Can we move the call to Thursday at ten", "I think the invoice is almost ready",
    "Please send the drawings to the station team before lunch", "First the order form, second the check mark, third the map",
    "Let me think, the strip on both sides looks off", "Можемо перенести дзвінок на четвер на десяту",
    "Я думаю, що рахунок вже готовий", "Send it to the whole team and copy me please",
    "So the plan is simple, we ship on Friday", "Thanks for the notes yesterday",
    "The station map needs one more check before we print it", "Can you look at the order form again",
    "Let's keep the old drawings and add the new ones at the end", "So the meeting moved to Monday morning",
    "I'll call you after the review tomorrow", "Please fix the check mark on page two and three",
    "OK, the invoice and the drawings both go out today", "We look at the strip again on both sides",
    "Send the notes to Mila and Sava after the sync", "So overall the plan works but the dates are tight",
]
# the same text as VoiceModeRules.instruction for a mode "Email: formal, short paragraphs" and no app note
INSTR = ("This is dictated speech. Rewrite it as written text: whole sentences, no spoken fillers or false starts, "
         "the same meaning, language, names and numbers; do not add facts, greetings or sign-offs it does not have. "
         "Style: formal, short paragraphs.")


def accept(p, clean):
    p = p.strip(); n = len(clean)
    if not p or n == 0 or len(p) > n * 2 + 40 or len(p) * 3 < n: return False
    return not p.lower().startswith(("here is", "here's", "ось ", "sure,", "звісно"))


def main():
    ms, kept = [], 0
    for t in TAKES:
        body = json.dumps({"text": t, "instruction": INSTR, "names": []}).encode()
        r = urllib.request.Request("http://127.0.0.1:8798/rewrite", body, {"Content-Type": "application/json"})
        a = time.perf_counter()
        out = json.load(urllib.request.urlopen(r, timeout=30)).get("text", "")
        ms.append((time.perf_counter() - a) * 1000)
        kept += accept(out, t)
    s = sorted(ms)
    print(json.dumps({"takes": len(s), "p50_ms": round(s[len(s) // 2]), "p90_ms": round(s[int((len(s) - 1) * 0.9)]),
                      "max_ms": round(s[-1]), "over_6s": sum(x > 6000 for x in s), "answers_kept": kept}))


if __name__ == "__main__":
    main()
