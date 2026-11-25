"""Parity round (2026-11-15): the guarded recordings, one model at a time, on mains power only. Loads no model itself.

    .venv/bin/python -B bench/parity_run.py <run> [--smoke]

Each run records a slice from bench/parity_sets.py as Drafter types it (bench/typebench.py through bench/models/record.py,
24 tokens a key, the live model and his layer), with the head cache file off (DRAFTER_HEAD_CACHE=, so the live engine's
file is never touched). -> data/bench/parity-<run>.jsonl, scored by bench/big/score.py against its baseline run."""
import argparse, json, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE / "models")); sys.path.insert(0, str(HERE / "big"))
import shared as S
from run import checks

P = "data/bench/parity/"
EN, SHORT = "write in English", "short, no greetings"
# name: (set, extra typebench args, env)
RUNS = {
    "clip-off": ("clip", ["--no-clip"], {}), "clip-on": ("clip", [], {}),
    "noise-off": ("noise", ["--no-clip", "--every", "2"], {}), "noise-on": ("noise", ["--every", "2"], {}),
    "notes-none": ("notes", ["--every", "3"], {}),
    "notes-en": ("notes", ["--every", "3", "--notes", EN], {}),
    "notes-en-line": ("notes", ["--every", "3", "--notes", EN], {"DRAFTER_NOTES_FORM": "line"}),
    "notes-short": ("notes", ["--every", "3", "--notes", SHORT], {}),
    "notes-short-line": ("notes", ["--every", "3", "--notes", SHORT], {"DRAFTER_NOTES_FORM": "line"}),
    "notes-en-near": ("notes", ["--every", "3", "--notes", EN], {"DRAFTER_NOTES_FORM": "near"}),
    "notes-en-uk": ("notes", ["--every", "3", "--notes", "пиши англійською"], {"DRAFTER_NOTES_FORM": "near"}),
    "strength-50": ("notes", ["--every", "3", "--strength", "0.5"], {}),
    "strength-0": ("notes", ["--every", "3", "--strength", "0"], {}),
    "unmerged": ("notes", ["--every", "3"], {"DRAFTER_LORA_FUSE": "0"}),
}


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("run", choices=sorted(RUNS)); ap.add_argument("--smoke", action="store_true")
    a = ap.parse_args()
    checks()
    sset, extra, env = RUNS[a.run]
    label = "parity-" + a.run + ("-smoke" if a.smoke else "")
    t = time.time()
    _, lines = S.record(label, "live", adapter="data/adapters", set_path=P + sset + ".json", smoke=a.smoke,
                        extra=["--tokens", "24", *extra], env={"DRAFTER_HEAD_CACHE": "", **env})
    print(json.dumps({"label": label, "seconds": round(time.time() - t), "peak_gb": S.peak_gb(lines),
                      "load": " ".join(l for l in lines if "loaded in" in l)[:160]}))


if __name__ == "__main__":
    main()
