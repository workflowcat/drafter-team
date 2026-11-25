"""Who said each line of a recorded call (17 November 2026: a client demo call came out with every line his).

Local only: a speaker-embedding model (3D-Speaker ERes2Net, 512 numbers per voice, ONNX through sherpa-onnx, about
0.3 GB) under the memory guard. Nothing leaves the Mac.

A call folder holds me.wav (his mic), them.wav (the Mac's sound: the other side), lines.json [{who, start, end?,
text, track?}] and meta.json. For each line this cuts its stretch from its track, keeps the frames above -40 dB and
turns them into one voice vector, then:
- a mic line ("track": "me") is his when it sounds like his voice print (data/voiceprint.json, built from his own
  dictation takes in data/audio, takes recorded during a call left out). Without a print, a mic line is his while the
  other side's track is alive (it was transcribed separately and his mic's echo of it taken out), else "unknown".
- every other voice (them.wav lines, and mic lines that are not his: the laptop speakers heard by the mic) is grouped
  by likeness into "Speaker 2", "Speaker 3"... in order of first appearance. A group gets a person's name only when the
  match is clear: one group on the other side and one other person in the meeting (meta.json "participants", else
  the calendar event's "people", minus him).
- a line too short or too quiet to place says "unknown" (a them.wav line stays "Вони": its side is known).
A mic line placed on the other side that repeats a them.wav line said within 20 s is dropped (the echo).

Writes lines.json (who, track, start, end, text), transcript.txt ("who: text"), speakers.json (counts per speaker,
how many lines were placed by voice) and, once, lines.before-speakers.json with what was there before.
CLI: speakers.py <call folder> [--print data/voiceprint.json] [--audio data/audio] [--dry]
Test: tests/test_speakers.py (made-up voices, never data/).
"""
import json, os, re, sys, time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

RATE = 16000
MODEL = ROOT / "models" / "speakers" / "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
MODEL_URL = ("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/"
             "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")
CAP_GB = 1.2
ME, THEM, UNKNOWN, OTHER = "Я", "Вони", "unknown", "Speaker"
# Measured on the 17 November call with this model: his takes against his print p10 0.44; the other side's 10 s
# pieces against his print p90 0.20; his takes with each other median 0.57, him against them 0.09.
HIS = 0.33            # a mic line at or above this cosine to his print is his
NOT_HIS = 0.22        # below this it is someone else; between the two it is "unknown"
SAME = 0.28           # two groups of the other side join while their average cosine is at least this (through the
                      # laptop speakers and the mic, one voice scores lower with itself: 0.25-0.30 gave 3 groups for 3 people)
SMALL = 3             # a group of fewer lines joins the nearest big group when their average cosine is at least FOLD
FOLD = 0.12
MIN_SPEECH = 0.8      # seconds of speech a line needs to be placed
LONG = 30             # a line longer than this (a voice take merged into a call) is placed window by window
WINDOW = 10
MOSTLY = 0.7
FRAME = 480           # 30 ms
LOUD = 0.010          # -40 dB, as voice.py has_speech
DEAD_BLOCK = 10       # seconds per block when deciding whether them.wav is alive
DEAD_ZEROS = 0.98     # a block that is this share of exact zeros got no sound from the Mac (capture stopped)


# MARK: audio

def read_wav(path):
    """16 kHz mono Int16 WAV -> float32 array (memory-mapped, then copied per stretch). None when missing."""
    p = Path(path)
    if not p.exists() or p.stat().st_size <= 44: return None
    with open(p, "rb") as f: head = f.read(4096)
    off = 44
    i = 12
    while i + 8 <= len(head):
        cid, n = head[i:i + 4], int.from_bytes(head[i + 4:i + 8], "little")
        if cid == b"data": off = i + 8; break
        i += 8 + n + (n & 1)
    return np.memmap(p, dtype="<i2", mode="r", offset=off)


def stretch(pcm, a, b):
    if pcm is None: return np.zeros(0, np.float32)
    s, e = max(0, int(a * RATE)), min(len(pcm), int(b * RATE))
    return np.asarray(pcm[s:e], dtype=np.float32) / 32768 if e > s else np.zeros(0, np.float32)


def speech(x):
    """Only the 30 ms frames above -40 dB, joined."""
    n = x.size // FRAME
    if n == 0: return np.zeros(0, np.float32)
    fr = x[: n * FRAME].reshape(n, FRAME)
    return fr[np.sqrt((fr * fr).mean(axis=1)) > LOUD].reshape(-1)


def alive_blocks(them):
    """Per 10 s block of them.wav: True when the Mac's sound was coming (not a run of exact zeros)."""
    if them is None: return np.zeros(0, bool)
    B = DEAD_BLOCK * RATE
    n = (len(them) + B - 1) // B
    out = np.zeros(n, bool)
    for i in range(n):
        blk = np.asarray(them[i * B:(i + 1) * B])
        out[i] = blk.size > 0 and float((blk == 0).mean()) < DEAD_ZEROS
    return out


def alive_at(blocks, t):
    i = int(t // DEAD_BLOCK)
    return 0 <= i < len(blocks) and bool(blocks[i])


# MARK: voices

class Embedder:
    def __init__(self, model=MODEL):
        import sherpa_onnx
        if not Path(model).exists():
            raise FileNotFoundError(f"speaker model missing: {model} (download: {MODEL_URL})")
        cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model), num_threads=2)
        self.ex = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)
        self.name = Path(model).stem

    def __call__(self, x):
        s = self.ex.create_stream()
        s.accept_waveform(RATE, np.ascontiguousarray(x, dtype=np.float32))
        s.input_finished()
        e = np.array(self.ex.compute(s), dtype=np.float32)
        n = float(np.linalg.norm(e))
        return e / n if n else e


def cluster(vecs, same=SAME):
    """Average-linkage grouping by cosine: groups join while their average likeness is at least `same`.
    -> a group number per vector, numbered by first appearance."""
    n = len(vecs)
    if n == 0: return []
    V = np.array(vecs)
    S = V @ V.T
    groups = [[i] for i in range(n)]
    while len(groups) > 1:
        best, bi, bj = -2.0, -1, -1
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                v = float(S[np.ix_(groups[i], groups[j])].mean())
                if v > best: best, bi, bj = v, i, j
        if best < same: break
        groups[bi] += groups.pop(bj)
    big = [g for g in groups if len(g) >= SMALL]
    if big:
        for g in [g for g in groups if len(g) < SMALL]:
            v, k = max((float(S[np.ix_(g, b)].mean()), k) for k, b in enumerate(big))
            if v >= FOLD: big[k] += g
            else: big.append(g)
        groups = big
    label = [0] * n
    for k, g in enumerate(sorted(groups, key=min)):
        for i in g: label[i] = k
    return label


def build_print(embed, audio_dir, calls_dir=None, most=80, log=print):
    """His voice print: the mean voice of up to `most` of his newest dictation takes with 3 s of speech or more,
    takes made during a recorded call left out (the mic hears the other side there), then only takes close to that
    mean kept (another voice in a take does not pull it). -> (vector, takes used) or (None, 0)."""
    spans = []
    for m in (Path(calls_dir).glob("*/meta.json") if calls_dir else []):
        try:
            j = json.loads(m.read_text())
            if not j.get("call"): continue
            st = float(j.get("started") or 0)
            secs = (m.parent / "me.wav").stat().st_size / 32000 if (m.parent / "me.wav").exists() else 0
            spans.append((st - 60, st + secs + 60))
        except Exception:
            continue
    takes = sorted(Path(audio_dir).glob("*.wav"), key=lambda p: p.stat().st_mtime, reverse=True) if audio_dir else []
    vecs = []
    for p in takes:
        if len(vecs) >= most: break
        t = p.stat().st_mtime
        if any(a <= t <= b for a, b in spans): continue
        x = read_wav(p)
        if x is None: continue
        s = speech(np.asarray(x[: RATE * 40], dtype=np.float32) / 32768)
        if s.size < 3 * RATE: continue
        vecs.append(embed(s[: RATE * 20]))
    if len(vecs) < 5:
        log(f"speakers: only {len(vecs)} takes with speech for a voice print, none made")
        return None, 0
    V = np.array(vecs)
    m = V.mean(axis=0); m /= np.linalg.norm(m)
    keep = V[V @ m >= 0.30]
    if len(keep) < 5: keep = V
    m = keep.mean(axis=0); m /= np.linalg.norm(m)
    return m, len(keep)


def load_print(path, embed, audio_dir, calls_dir, max_age_days=7, log=print):
    """data/voiceprint.json, rebuilt when missing, from another model, or older than a week."""
    p = Path(path)
    try:
        j = json.loads(p.read_text())
        if j.get("model") == getattr(embed, "name", "") and time.time() - float(j.get("built", 0)) < max_age_days * 86400:
            return np.array(j["vec"], dtype=np.float32), int(j.get("takes", 0))
    except Exception:
        pass
    vec, n = build_print(embed, audio_dir, calls_dir, log=log)
    if vec is not None:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"model": getattr(embed, "name", ""), "built": time.time(), "takes": n, "vec": [round(float(x), 6) for x in vec]}))
        log(f"speakers: voice print built from {n} takes")
    return vec, n


# MARK: lines

def words(s):
    return [w for w in re.split(r"\W+", (s or "").lower()) if w]


def same_words(a, b, share=0.8):
    """As MergeRules.same: at least 80% of the shorter line's words are in the other (with repeats)."""
    wa, wb = words(a), words(b)
    if not wa or not wb: return False
    short, long_ = (wa, wb) if len(wa) <= len(wb) else (wb, wa)
    if len(short) < 3: return short == long_
    bag = {}
    for w in long_: bag[w] = bag.get(w, 0) + 1
    common = 0
    for w in short:
        if bag.get(w, 0) > 0: bag[w] -= 1; common += 1
    return common >= share * len(short)


def track_of(row, me, them):
    """The row's track: its own "track", else from its old label, else the louder file at that moment."""
    t = row.get("track")
    if t in ("me", "them"): return t
    w = row.get("who") or ""
    if w == THEM: return "them"
    if w == ME: return "me"
    st = float(row.get("start") or 0)
    a, b = speech(stretch(me, st, st + 4)), speech(stretch(them, st, st + 4))
    return "them" if b.size > a.size else "me"


def ends(rows):
    """Each row's end: its own "end" (a voice take in a merged call runs minutes), else the next row's start on the same
    track, at most 30 s; at least 1 s."""
    out = []
    for i, r in enumerate(rows):
        st = float(r.get("start") or 0)
        e = r.get("end")
        if e is None:
            nxt = [float(x.get("start") or 0) for x in rows[i + 1:] if x["track"] == r["track"] and float(x.get("start") or 0) > st]
            guess = st + max(1.5, 0.45 * len(words(r.get("text"))) + 0.5)
            e = min(nxt[0], guess, st + 30) if nxt else min(guess, st + 30)
        out.append(max(st + 1.0, float(e)))
    return out


def me_names(meta):
    names = {"andrii", "андрій", "andrew"}
    try:
        import local
        s = (local.short_name() or "").strip().lower()
        if s: names.add(s)
    except Exception:
        pass
    return names


def remote_people(meta):
    ev = meta.get("event") or {}
    people = meta.get("participants") or ev.get("people") or []
    mine = me_names(meta)
    out = []
    for p in people:
        p = str(p).strip()
        if p and p.lower() not in mine and p.split()[0].lower() not in mine and p not in out: out.append(p)
    return out


def label(rows, me, them, embed, his=None, people=(), log=print):
    """rows [{who, start, end?, text, track?}] -> (rows with who and track, stats). Pure apart from `embed`."""
    rows = [dict(r) for r in rows if (r.get("text") or "").strip()]
    rows.sort(key=lambda r: float(r.get("start") or 0))
    for r in rows: r["track"] = track_of(r, me, them)
    stop = ends(rows)
    blocks = alive_blocks(them)
    vec, share = [], []              # one voice per line; for a long line, the share of its windows that are his
    for r, e in zip(rows, stop):
        st = float(r.get("start") or 0)
        src = me if r["track"] == "me" else them
        if e - st <= LONG:
            s = speech(stretch(src, st, e))
            vec.append(embed(s) if s.size >= MIN_SPEECH * RATE else None); share.append(None)
            continue
        # a long line (a voice take): 10 s windows, each placed on its own
        ws = [speech(stretch(src, a, min(a + WINDOW, e))) for a in np.arange(st, e, WINDOW)]
        ws = [embed(w) for w in ws if w.size >= 3 * RATE]
        if not ws: vec.append(None); share.append(None); continue
        mine = [w for w in ws if his is not None and r["track"] == "me" and float(w @ his) >= HIS]
        other = [w for w in ws if not (his is not None and r["track"] == "me" and float(w @ his) >= NOT_HIS)]
        share.append(len(mine) / len(ws) if his is not None and r["track"] == "me" else None)
        pool = other if other else ws
        m = np.mean(pool, axis=0); vec.append(m / np.linalg.norm(m))
    def heard(i):
        st = float(rows[i].get("start") or 0)
        return any(x["track"] == "them" and abs(float(x.get("start") or 0) - st) <= 60 for x in rows)
    who = [None] * len(rows)
    remote = []                      # indices of lines spoken by someone on the other side
    for i, r in enumerate(rows):
        v = vec[i]
        if r["track"] == "them":
            if v is not None: remote.append(i)
            continue
        if share[i] is not None:     # a long mic line: his when 70% of its windows are, someone else's when 30% or less
            if share[i] >= MOSTLY: who[i] = ME
            elif share[i] <= 1 - MOSTLY: remote.append(i)
            else: who[i] = UNKNOWN
        elif his is not None and v is not None:
            c = float(v @ his)
            if c >= HIS: who[i] = ME
            elif c < NOT_HIS: remote.append(i)
            else: who[i] = UNKNOWN
        elif (his is None or v is None) and alive_at(blocks, float(r.get("start") or 0)) and heard(i):
            who[i] = ME              # the other side was recorded and read apart (his mic's echo of it taken out)
        else:
            who[i] = UNKNOWN
    groups = cluster([vec[i] for i in remote])
    n = (max(groups) + 1) if groups else 0
    names = {}
    big = [g for g in range(n) if sum(1 for x in groups if x == g) >= 2]
    if len(people) == 1 and len(big) == 1 and n <= 2:
        names[big[0]] = people[0]
    for k, i in enumerate(remote):
        g = groups[k]
        who[i] = names.get(g) or f"{OTHER} {g + 2}"
    # a them.wav line too short to place: the nearest placed line of that track within 3 s (gap between the lines),
    # else "Вони"
    def gap(i, j):
        return max(0.0, float(rows[i].get("start") or 0) - stop[j], float(rows[j].get("start") or 0) - stop[i])
    for i, r in enumerate(rows):
        if who[i] is not None: continue
        near = [j for j in range(len(rows)) if j != i and rows[j]["track"] == "them" and who[j] not in (None, UNKNOWN, THEM)
                and gap(i, j) <= 3]
        who[i] = who[min(near, key=lambda j: gap(i, j))] if near else THEM
    # a mic line on the other side repeating a them.wav line within 20 s is the echo: dropped
    gone = set()
    for i, r in enumerate(rows):
        if r["track"] != "me" or who[i] in (ME, UNKNOWN): continue
        st = float(r.get("start") or 0)
        if any(rows[j]["track"] == "them" and abs(float(rows[j].get("start") or 0) - st) <= 20 and same_words(r["text"], rows[j]["text"])
               for j in range(len(rows))):
            gone.add(i)
    out = []
    for i, (r, e) in enumerate(zip(rows, stop)):
        if i in gone: continue
        row = {"who": who[i], "track": r["track"], "start": round(float(r.get("start") or 0), 2), "end": round(e, 2), "text": r["text"].strip()}
        out.append(row)
    counts = {}
    for r in out: counts[r["who"]] = counts.get(r["who"], 0) + 1
    stats = {"lines": len(out), "counts": dict(sorted(counts.items(), key=lambda kv: -kv[1])), "echo_dropped": len(gone),
             "by_voice": sum(1 for v in vec if v is not None), "groups": n, "named": {f"{OTHER} {g + 2}": p for g, p in names.items()},
             "them_alive_min": round(float(blocks.sum()) * DEAD_BLOCK / 60, 1), "print": his is not None}
    return out, stats


def transcript(rows):
    return "\n".join(f"{r['who']}: {r['text']}" if r["who"] else r["text"] for r in rows) + "\n"


def run(folder, print_path=None, audio_dir=None, calls_dir=None, dry=False, log=print, embed=None):
    d = Path(folder)
    meta = json.loads((d / "meta.json").read_text()) if (d / "meta.json").exists() else {}
    if not meta.get("call", True): return {"skipped": "not a call"}
    rows = json.loads((d / "lines.json").read_text())
    me, them = read_wav(d / "me.wav"), read_wav(d / "them.wav")
    embed = embed or Embedder()
    his, used = (load_print(print_path, embed, audio_dir, calls_dir, log=log) if print_path else (None, 0))
    out, stats = label(rows, me, them, embed, his, remote_people(meta), log=log)
    stats["print_takes"] = used
    stats["model"] = getattr(embed, "name", "")
    if not dry:
        before = d / "lines.before-speakers.json"
        if not before.exists(): before.write_text(json.dumps(rows, ensure_ascii=False))
        tmp = d / "lines.json.tmp"
        tmp.write_text(json.dumps(out, ensure_ascii=False, indent=1)); os.replace(tmp, d / "lines.json")
        (d / "transcript.txt").write_text(transcript(out))
        (d / "speakers.json").write_text(json.dumps(dict(stats, at=time.time()), ensure_ascii=False, indent=1))
    return stats


if __name__ == "__main__":
    import argparse, guard
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--print", dest="print_path", default=str(ROOT / "data" / "voiceprint.json"))
    ap.add_argument("--audio", default=str(ROOT / "data" / "audio"))
    ap.add_argument("--calls", default=str(ROOT / "data" / "calls"))
    ap.add_argument("--dry", action="store_true")
    a = ap.parse_args()
    guard.start(CAP_GB)
    s = run(a.folder, a.print_path, a.audio, a.calls, a.dry, log=lambda m: print(m, file=sys.stderr, flush=True))
    print(json.dumps(s, ensure_ascii=False), flush=True)
