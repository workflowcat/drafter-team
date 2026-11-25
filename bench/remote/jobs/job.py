"""One Drafter background job inside the drafter-jobs container on your server (bench/remote/jobs/Dockerfile). Started
by bench/jobs.py on the Mac; never run on the Mac. Reads /work/in (read-only), writes only /work/out.

    python /app/job.py careful --threads 10      # in: job.json + the sides' 16 kHz mono wav; out: <side>.json, meta.json
    python /app/job.py index --threads 10        # in: job.json + items.jsonl {id, text}; out: vectors.npy, items.json, tags.json, meta.json
    python /app/job.py check                     # torch and the numpy encoder agree on made-up lines (smoke only)

careful: faster-whisper (CTranslate2, int8) with beam search 5, voice activity filter, segment times; one json per side,
[{start, end, text}], the shape the Mac's reading writes before it merges the sides.
index: multilingual-e5-small, "passage: " + text, mean pooled, unit length, float16; topic tags from spherical k-means
over the vectors, each cluster named by its 2 most distinctive words (class TF-IDF); an item far from its centre gets none."""
import argparse, json, math, os, re, resource, sys, time, wave
from collections import Counter
from pathlib import Path

import numpy as np

IN, OUT = Path("/work/in"), Path("/work/out")
E5 = "intfloat/multilingual-e5-small"


def peak_gb():
    cg = None
    for f in ("/sys/fs/cgroup/memory.peak", "/sys/fs/cgroup/memory/memory.max_usage_in_bytes"):
        try: cg = round(int(Path(f).read_text()) / 1e9, 2); break
        except Exception: pass
    return cg, round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6, 2)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def read_wav(path):
    with wave.open(str(path)) as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise SystemExit(f"{path.name}: want 16 kHz mono 16-bit, got {w.getframerate()} Hz {w.getnchannels()} ch {w.getsampwidth() * 8} bit")
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


def careful(threads):
    from faster_whisper import WhisperModel
    job = json.loads((IN / "job.json").read_text())
    model_name = job.get("model", "large-v3-turbo")
    t0 = time.time()
    m = WhisperModel(model_name, device="cpu", compute_type="int8", cpu_threads=threads, download_root="/cache/whisper")
    load = time.time() - t0
    audio_sec, read_sec, sides = 0.0, 0.0, {}
    for side in job["sides"]:
        a = read_wav(IN / side["file"])
        secs = len(a) / 16000
        t = time.time()
        segs, info = m.transcribe(a, language=job.get("language") or None, beam_size=int(job.get("beam", 5)), vad_filter=True,
                                  condition_on_previous_text=False, initial_prompt=job.get("hint") or None)
        rows = [{"start": round(s.start, 2), "end": round(s.end, 2), "text": s.text.strip()} for s in segs if s.text.strip()]
        took = time.time() - t
        (OUT / f"{side['name']}.json").write_text(json.dumps(rows, ensure_ascii=False))
        sides[side["name"]] = {"audio_sec": round(secs, 1), "read_sec": round(took, 1), "lines": len(rows), "language": info.language}
        audio_sec += secs; read_sec += took
        log(f"{side['name']}: {secs / 60:.1f} min audio in {took / 60:.1f} min ({took / max(secs, 1):.2f} min per audio min), {len(rows)} lines")
    cg, rss = peak_gb()
    meta = {"kind": "careful", "model": model_name, "beam": int(job.get("beam", 5)), "threads": threads, "load_sec": round(load, 1), "audio_sec": round(audio_sec, 1),
            "read_sec": round(read_sec, 1), "min_per_audio_min": round(read_sec / max(audio_sec, 1), 3), "sides": sides,
            "peak_gb_cgroup": cg, "peak_gb_rss": rss}
    (OUT / "meta.json").write_text(json.dumps(meta, indent=1))
    log("done", json.dumps(meta))


def e5_torch(threads):
    import torch
    from transformers import AutoModel, AutoTokenizer
    torch.set_num_threads(threads)
    tok = AutoTokenizer.from_pretrained(E5); model = AutoModel.from_pretrained(E5).eval()

    def enc(texts, batch=32):
        out = []
        order = sorted(range(len(texts)), key=lambda i: len(texts[i]))   # similar lengths batch together: less padding
        for b in range(0, len(order), batch):
            idx = order[b:b + batch]
            x = tok([texts[i] for i in idx], padding=True, truncation=True, max_length=512, return_tensors="pt")
            with torch.no_grad(): h = model(**x).last_hidden_state
            m = x["attention_mask"].unsqueeze(-1).float()
            v = (h * m).sum(1) / m.sum(1)
            v = torch.nn.functional.normalize(v, dim=-1).numpy()
            out.extend(zip(idx, v))
        return np.stack([v for _, v in sorted(out, key=lambda p: p[0])])
    return enc


STOP = set("""що як де коли хто чи і й та в у на з із до про по за це той ця ці то так не але а бо або від для при
вже ще теж тут там його її їх ми ви вони він вона воно я ти мене тебе нам вам мені тобі було буде був була є є
the a an of to in on is was are be it this that for with and or but not you we they i me my at as by from have has
just will can so if do did what when who where how about there here then than""".split())


def words(t):
    return [w for w in re.findall(r"[^\W\d_]{4,}", t.lower()) if w not in STOP]


def kmeans(v, k, iters=25, seed=7):
    rng = np.random.default_rng(seed)
    c = v[rng.choice(len(v), k, replace=False)].copy()
    for _ in range(iters):
        lab = (v @ c.T).argmax(1)
        for j in range(k):
            s = v[lab == j]
            if len(s): c[j] = s.mean(0) / (np.linalg.norm(s.mean(0)) + 1e-12)
    return lab, c


def index(threads):
    rows = [json.loads(l) for l in (IN / "items.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    t0 = time.time()
    enc = e5_torch(threads)
    load = time.time() - t0
    t = time.time()
    v = enc(["passage: " + r["text"][:4000] for r in rows]) if rows else np.zeros((0, 384), np.float32)
    took = time.time() - t
    tags, item_tags = [], [[] for _ in rows]
    if len(rows) >= 8:
        k = max(2, min(40, int(math.sqrt(len(rows) / 2))))
        lab, c = kmeans(v, k)
        docs = [Counter(w for i in np.where(lab == j)[0] for w in words(rows[i]["text"])) for j in range(k)]
        df = Counter(w for d in docs for w in d)
        for j in range(k):
            n = int((lab == j).sum())
            if n < 2: continue
            score = {w: f * math.log(1 + k / df[w]) for w, f in docs[j].items() if f >= 2}
            top = [w for w, _ in sorted(score.items(), key=lambda p: -p[1])[:2]]
            if not top: continue
            name = " ".join(top)
            sims = v[lab == j] @ c[j]
            cut = float(np.quantile(sims, 0.2)) if n >= 5 else -1.0   # the farthest fifth of a cluster stays untagged
            same = next((t for t in tags if t["tag"] == name), None)   # two clusters, one name: one tag
            if same: same["items"] += n
            else: tags.append({"tag": name, "items": n})
            for i, s in zip(np.where(lab == j)[0], sims):
                if s >= cut: item_tags[i].append(name)
    np.save(OUT / "vectors.npy", v.astype(np.float16))
    (OUT / "items.json").write_text(json.dumps([{"id": r["id"], "tags": tg} for r, tg in zip(rows, item_tags)], ensure_ascii=False))
    (OUT / "tags.json").write_text(json.dumps(tags, ensure_ascii=False))
    cg, rss = peak_gb()
    meta = {"kind": "index", "model": E5, "threads": threads, "items": len(rows), "load_sec": round(load, 1), "embed_sec": round(took, 1),
            "items_per_sec": round(len(rows) / max(took, 1e-6), 1), "tags": len(tags), "dim": int(v.shape[1]) if len(v) else 384,
            "peak_gb_cgroup": cg, "peak_gb_rss": rss}
    (OUT / "meta.json").write_text(json.dumps(meta, indent=1))
    log("done", json.dumps(meta))


def check(threads):
    """The numpy encoder the Mac runs for a query gives the torch vector (cosine >= 0.999)."""
    from huggingface_hub import snapshot_download
    sys.path.insert(0, "/app")
    from embed_np import Encoder
    lines = ["query: що ми домовились про друк буклетів", "query: when is the budget review", "passage: made-up note about the Friday deck"]
    a = e5_torch(threads)(lines)
    import embed_np
    folder = snapshot_download(E5, allow_patterns=embed_np.FILES)
    b = Encoder(folder).encode(lines)
    ids_same = all(Encoder._spm(Path(folder))(t) == Encoder._fast(Path(folder))(t) for t in lines + ["Привіт 123 ʼапостроф’s co-op, 3.5%"])
    cos = (a * b).sum(1)
    out = {"kind": "check", "cosine_min": round(float(cos.min()), 5), "spm_ids_same": ids_same}
    (OUT / "meta.json").write_text(json.dumps(out)); log("done", json.dumps(out))
    if cos.min() < 0.999 or not ids_same: raise SystemExit(f"numpy and torch differ: {cos}, ids same {ids_same}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("kind", choices=["careful", "index", "check"]); p.add_argument("--threads", type=int, default=10)
    a = p.parse_args()
    {"careful": careful, "index": index, "check": check}[a.kind](a.threads)
