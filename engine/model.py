"""One warm model with a reusable prompt cache. Only one model is loaded per process.

The prompt has a fixed head (style, dictionary, examples) and a moving tail (app, window, text before the caret).
Consecutive keystrokes share most tokens, so the cache is trimmed back to the common part and only new tokens are fed.
"""
import copy, gc, hashlib, json, math, os, re, tempfile, threading, time
from collections import OrderedDict
from pathlib import Path

import mlx.core as mx
from mlx_lm import load
from mlx_lm.generate import generate_step, generation_stream
from mlx_lm.models.cache import make_prompt_cache, can_trim_prompt_cache, trim_prompt_cache, save_prompt_cache, load_prompt_cache
from mlx_lm.sample_utils import make_sampler

CAP_GB = float(os.environ.get("DRAFTER_CAP_GB", "3.6"))   # guard cap for the whole engine
mx.set_memory_limit(int(CAP_GB * 0.92 * 2**30))          # MLX tries to stay under this (below 2.6 GB it stalls the 4B model)
mx.set_cache_limit(64 * 2**20)                             # never keep a big free-buffer pool (lesson from an older dictation app)


def set_limit(cap_gb):
    """MLX's own limit for another guard cap (model catalog: a bigger model gets its cap at a switch)."""
    mx.set_memory_limit(int(cap_gb * 0.92 * 2**30))

END = re.compile(r"[.!?…)\n]")
# other screens kept warm (2026-11-01, the user: "it takes a long time to start often"): going back to a chat reads
# nothing again. Each holds one prompt, ~0.15 GB at 1,300 tokens for Qwen3 1.7B.
SPARE = int(os.environ.get("DRAFTER_SPARE_CACHES", "2"))
# the user's-writing layer merged into a copy of the layers it touches (2026-11-13, bench/speed.py): unmerged, each of the
# 112 LoRA layers adds two small matmuls per token, 19.5 ms a token against 6.8 merged (M4 Pro, Qwen3 1.7B 4-bit);
# the merged copies cost ~0.43 GB. 0 = the old way.
FUSE = os.environ.get("DRAFTER_LORA_FUSE", "1") == "1"
# The plain layers are not kept beside the merged ones (engine memory round, 2026-11-17): they doubled the 16 layers the user's
# layer touches, 0.85 GB on Qwen3 4B and 0.42 GB on 1.7B (read from the weight files). Layer off (chips, rewrites) runs
# the merged layer with the LoRA at minus its scale: the base model within one re-rounding of 4-bit, the same rounding
# the merged typing layers carry. Typing runs on the same merged layers as before, bit for bit. A new strength loads
# the plain weights from disk again. DRAFTER_LORA_KEEP_PLAIN=1 = the old way (exact base model for layer off).
KEEP_PLAIN = os.environ.get("DRAFTER_LORA_KEEP_PLAIN", "0") == "1"
# the next-token distribution kept beside the cache (round four, 2026-11-14, Codex review): inside a half word the
# prompt ids stay the same from key to key (the typed letters are healed, not fed), so the model's first step was
# being run again on the same tokens. With the distribution after those ids kept, the cache is cut back to them and
# the first token comes from it without a forward pass; bench/dist_check.py shows the choices stay identical.
SETTLE = os.environ.get("DRAFTER_SETTLE", "1") == "1"   # round five: stop once the ghost can no longer change
DIST = os.environ.get("DRAFTER_DIST", "1") == "1"   # bench/dist_check.py 2026-11-14: same choices on 1,080 keys; DRAFTER_DIST=0 turns it off
# logit bias / steering vectors (weights round, 2026-11-14, engine/tweaks.py): a file from bench/weights/, default off
TWEAKS = os.environ.get("DRAFTER_TWEAKS", "")
# the fixed head read from a file at load and wake instead of being read by the model (big-model round, 2026-11-15;
# bench/weights/speed.py: 335 ms of prefill became a 4 ms read, the next-token logits identical). The file is made
# when the head (or the model, layer or tweaks) changes; a stale, broken or missing file falls back to the prefill.
# It holds the user's example messages, so it lives under data/. Empty DRAFTER_HEAD_CACHE = off.
HEAD_CACHE = os.environ.get("DRAFTER_HEAD_CACHE", str(Path(__file__).resolve().parent.parent / "data" / "cache"))
# copies kept after the screen text, for caches that cannot be cut back (big-model round): one per screen, at most
# SPARE + 1 (the active screen and the parked ones)
MARKS = SPARE + 1


class Model:
    def __init__(self, repo, adapter=None, strength=1.0, src=None):
        t = time.time()
        self.repo = repo
        self.src = src         # a local snapshot folder to load from (catalog models), else the repo id as before
        self.adapter = adapter if adapter and os.path.isdir(adapter) else None
        # personalization strength (parity round, 2026-11-15): the user's layer's scale, 0..1, applied when it is merged
        # (fuse_lora), so a key costs the same at any strength; set_strength re-merges in place
        self.strength = min(1.0, max(0.0, float(strength)))
        # a LoRA trained on the user's own writing (bench/train.py) sits on top of the base model
        self.model, self.tok = self._load()
        self.fused = []        # (parent module, attribute, LoRA module, merged copy): see fuse_lora
        if self.adapter and FUSE: self.fuse_lora()
        self.tw = self._tweak(None)
        if self.adapter and not FUSE and self.strength != 1.0: self.lora(True)
        self.lock = threading.Lock()
        self.cache, self.ids = None, []
        self.rebuilds = 0
        self.screen, self.parked, self.swaps = None, OrderedDict(), 0   # parked: screen -> (ids, cache), oldest first
        self.snapshot = None   # (cache, ids) right after the fixed head, for caches that cannot be trimmed
        self.marks = OrderedDict()   # screen -> (cache, ids) right after the screen text, same kind of cache only
        self.head_file = None        # "read", "made" or None: how the head came in at the last warm
        self.mark_hits = 0           # keys answered from a copy after the screen text
        self.head_ids, self.wake_at, self.sleeps, self.loading = [], 0.0, 0, False
        self.retrain_sleep = False
        self.load_s = time.time() - t
        self.sampler = make_sampler(temp=0.0)
        self.dist = None       # (id of the cache, ids) -> raw logits of the token after them: see DIST
        self.dist_used = 0

    def encode(self, text):
        return self.tok.encode(text, add_special_tokens=False)

    def bos(self):
        b = getattr(self.tok, "bos_token_id", None)
        return [b] if b is not None and "gemma" in self.repo.lower() else []

    # Sleep (2026-11-01, the user: "not to overload the Mac, a lot of stuff is being recorded"): while a long call is read
    # again (the voice engine may take 3.4 GB then), the text model gives its ~1.9 GB back. Typing paths answer empty
    # meanwhile (the word finisher still speaks); a one-off can wake ordinary voice sleep, but never a retrain lease.
    @property
    def asleep(self):
        return self.model is None

    def sleep(self, secs, retrain=False):
        with self.lock:
            until = time.time() + max(0.0, secs)
            if getattr(self, "retrain_sleep", False) and time.time() < self.wake_at:
                until, retrain = max(until, self.wake_at), True
            self.wake_at, self.retrain_sleep = until, retrain
            if self.model is None: return False
            self._drop()
            self.sleeps += 1
        gc.collect(); mx.clear_cache()
        return True

    def _load(self):
        where = getattr(self, "src", None) or self.repo
        return load(where, adapter_path=self.adapter) if self.adapter else load(where)

    def _drop(self):
        """Under the lock: the weights and every cache made from them go (sleep, and a switch before the next load)."""
        self.model, self.fused = None, []    # the merged copies hold memory too
        self.cache, self.ids, self.snapshot, self.dist = None, [], None, None
        self.parked.clear(); self.screen = None; self.marks.clear()
        self._lora_mods = None; self._ru = None; self.__dict__.pop("_masks", None)

    # Model catalog (2026-11-15): another model in place of this one. engine/catalog.switch calls unload() first, so
    # memory never holds two models, then load_as(); the caller reads the head again with the new tokenizer.
    def unload(self):
        with self.lock:
            self._drop()
            self._by_first, self.tw = None, None    # token pieces and tweaks belong to the old tokenizer
            self.wake_at, self.retrain_sleep = 0.0, False
        gc.collect(); mx.clear_cache(); mx.reset_peak_memory()

    def load_as(self, repo, adapter=None, src=None):
        """Load `repo` (from `src` when given) with `adapter` into this (unloaded) object. Raises when it cannot."""
        with self.lock:
            if self.model is not None: raise RuntimeError("unload first: one model at a time")
            t = time.time()
            self.repo, self.src = repo, src
            self.adapter = adapter if adapter and os.path.isdir(adapter) else None
            self.head_ids, self.head_file = [], None
            self.loading = True
            try:
                self.model, self.tok = self._load()
                if self.adapter and FUSE: self.fuse_lora()
                self.tw = self._tweak(None)
                if self.adapter and not FUSE and self.strength != 1.0: self.lora(True)
                self.cache, self.ids = None, []
            except Exception:
                self._drop()
                raise
            finally:
                self.loading = False
            self.load_s = time.time() - t

    def loaded_gb(self):
        """What the loaded weights hold now (MLX active memory), 0 when nothing is loaded."""
        return 0.0 if self.model is None else mx.get_active_memory() / 2**30

    def wake(self, force=True):
        """Load back now (force), or only if the sleep ran out. -> True when the model is there."""
        with self.lock:
            return self._ensure(force)

    def _ensure(self, force=False):
        """Under the lock: True when the model is loaded. After a sleep it loads back once the time ran out, or at once
        with force; the head is read in again, so the next key costs what it did before."""
        if self.model is None and not force and time.time() < self.wake_at: return False
        self.wake_at, self.retrain_sleep = 0.0, False
        if self.model is not None: return True
        t = time.time()
        self.loading = True        # the server answers typing from the word finisher meanwhile, never behind this
        try:
            where = getattr(self, "src", None) or self.repo     # a catalog model loads from its snapshot folder
            self.model, _ = load(where, adapter_path=self.adapter) if self.adapter else load(where)
            if self.adapter and FUSE: self.fuse_lora()
            self.tw = self._tweak(self.tw)
            if self.adapter and not FUSE and self.strength != 1.0: self.lora(True)
            self._warm(self.head_ids)
        finally:
            self.loading = False
        self.load_s = time.time() - t
        return True

    def _switch(self, screen):
        """Make the cache of `screen` (app · window) the active one. A screen seen lately gets its own cache back, so
        its chat is not read again; a new one starts from a copy of the active cache (trimmed back to the shared
        head by _feed), or reuses the buffers of the screen parked longest."""
        if not SPARE or screen is None or screen == self.screen or self.cache is None:
            if screen is not None: self.screen = screen
            return
        if screen in self.parked:
            ids, cache = self.parked.pop(screen)
            self.swaps += 1
        elif len(self.parked) >= SPARE:
            ids, cache = self.parked.popitem(last=False)[1]
        else:
            ids, cache = list(self.ids), copy.deepcopy(self.cache)
        if self.screen is not None: self.parked[self.screen] = (self.ids, self.cache)
        self.ids, self.cache, self.screen, self.dist = ids, cache, screen, None

    def _feed(self, ids, stable=None):
        """Make the cache hold exactly ids[:-1] and return the tail to feed (at least one token).
        stable (big-model round): ids[:stable] stay put while the user types on this screen (Builder.ids_stable). A cache
        that cannot be cut back then restores its copy at that point (made here the first time) and only the typed
        line is read again; a cache that can be cut back never comes this far, so nothing changes for it."""
        if self.cache is not None:
            n = 0
            for a, b in zip(self.ids, ids):
                if a != b: break
                n += 1
            n = min(n, len(ids) - 1)
            drop = len(self.ids) - n
            if drop == 0 or (can_trim_prompt_cache(self.cache) and trim_prompt_cache(self.cache, drop) == drop):
                self.ids = self.ids[:n]
                if drop == 0 and stable and self.snapshot and n < stable < len(ids) and self.marks.get(self.screen, (0, None))[1] != ids[:stable]:
                    self._mark(ids, stable)     # the cache only grows here: make the copy on the way
                return ids[len(self.ids):]
        self.rebuilds += 1
        snap = self.snapshot          # only a cache that cannot be cut back has one (_warm)
        stable = stable if snap and stable and 0 < stable < len(ids) else None
        if stable:
            mark = self.marks.get(self.screen)
            if mark and mark[1] == ids[:stable]:
                self.marks.move_to_end(self.screen)
                self.cache, self.ids = copy.deepcopy(mark[0]), list(mark[1])
                self.mark_hits = getattr(self, "mark_hits", 0) + 1   # getattr: tests run _feed on stand-ins
                return ids[stable:]
        if snap and ids[: len(snap[1])] == snap[1] and len(ids) > len(snap[1]):
            self.cache, self.ids = copy.deepcopy(snap[0]), list(snap[1])
        else:
            self.cache, self.ids = make_prompt_cache(self.model), []
        if stable and len(self.ids) < stable < len(ids): self._mark(ids, stable)
        return ids[len(self.ids):]

    def _mark(self, ids, stable):
        """Read the cache on to ids[:stable] and keep a copy there for this screen."""
        self._read(ids[len(self.ids):stable])
        self.ids = list(ids[:stable])
        self.marks[self.screen] = (copy.deepcopy(self.cache), list(self.ids))
        self.marks.move_to_end(self.screen)
        while len(self.marks) > MARKS: self.marks.popitem(last=False)

    def _read(self, ids, step=512):
        """Read ids into the active cache (no token made)."""
        with mx.stream(generation_stream):
            for i in range(0, len(ids), step):
                self.model(mx.array(ids[i:i + step])[None], cache=self.cache)
                mx.eval([c.state for c in self.cache])
        mx.clear_cache()

    def _reuse(self, raw_ids):
        """The distribution after exactly raw_ids, when it is kept and the cache can be cut back to them: then the cache
        holds raw_ids and the raw logits come back (the caller feeds nothing); else None and nothing changes."""
        d = self.dist
        if not DIST or d is None or self.cache is None or d[0] != (id(self.cache), tuple(raw_ids)): return None
        n = len(raw_ids)
        if n == 0 or self.ids[:n] != list(raw_ids) or getattr(self.cache[0], "offset", -1) != len(self.ids): return None
        drop = len(self.ids) - n
        if drop and not (can_trim_prompt_cache(self.cache) and trim_prompt_cache(self.cache, drop) == drop): return None
        self.ids = list(raw_ids)
        self.dist_used += 1
        return d[1]

    def _steps(self, raw_ids, fed, procs, max_tokens, raw0=None, prefill_step=512, cancelled=None):
        """mlx_lm generate_step (0.32) for the main cache, with the distribution after raw_ids kept (self.dist), and
        with `raw0` (from _reuse) the first token taken from it without a forward pass. Same greedy choices, same
        logits processors (they see the fed tokens first), every yielded token already inside the cache.
        cancelled (ghost p90 round, 2026-11-17): checked after each prefill chunk, so a key stops a long prompt read
        (the idle ghost's chat prompt) within one chunk instead of after all of it; self.ids grows with each chunk so
        the cache and self.ids stay the same length when it stops there."""
        tokens, key, kept = None, (id(self.cache), tuple(raw_ids)), [False]

        def step(inp, raw=None):
            nonlocal tokens
            with mx.stream(generation_stream):
                logits = raw if raw is not None else self.model(inp[None], cache=self.cache)[:, -1, :]
                if not kept[0]:
                    kept[0] = True
                    self.dist = (key, logits) if DIST else None
                tokens = mx.concat([tokens, inp]) if tokens is not None else inp
                for proc in procs: logits = proc(tokens, logits)
                lp = logits - mx.logsumexp(logits, keepdims=True)
                return self.sampler(lp), lp.squeeze(0)
        prompt = mx.array(fed)
        with mx.stream(generation_stream):
            if raw0 is None:
                while len(prompt) > 1:
                    k = min(prefill_step, len(prompt) - 1)
                    self.model(prompt[:k][None], cache=self.cache)
                    mx.eval([c.state for c in self.cache])
                    tokens = mx.concat([tokens, prompt[:k]]) if tokens is not None else prompt[:k]
                    prompt = prompt[k:]
                    mx.clear_cache()
                    if cancelled is not None:
                        done = len(fed) - len(prompt)
                        self.ids = list(raw_ids[: len(raw_ids) - len(fed) + done])
                        if cancelled(): raise Model.Cancelled()
            y, lp = step(prompt, raw0)
            mx.async_eval(y, lp)
            n = 0
            while True:
                if n != max_tokens:
                    ny, nlp = step(y)
                    mx.async_eval(ny, nlp)
                if n == 0: mx.eval(y)
                if n == max_tokens: break
                yield y.item(), lp
                y, lp = ny, nlp
                n += 1

    def _pieces_cache_path(self, n):
        cache_dir = getattr(self, "pieces_cache_dir", HEAD_CACHE)
        repo = getattr(self, "repo", None)
        if not cache_dir or not repo or n <= 0:
            return None
        # Fingerprint repo + vocab size + local tokenizer.json stat (when present) + evenly spaced decoded tokens.
        probes = sorted({0, min(1, n - 1), n // 4, n // 2, (3 * n) // 4, n - 1})
        sig = [str(repo), str(n)] + [self.tok.decode([i]) for i in probes]
        src = getattr(self, "src", None)
        if src:
            tok_file = Path(src) / "tokenizer.json"
            try:
                st = tok_file.stat()
                sig.append(f"{st.st_size}:{st.st_mtime_ns}")
            except OSError:
                pass
        h = hashlib.sha1("\x00".join(sig).encode("utf-8", errors="replace")).hexdigest()[:16]
        return Path(cache_dir) / f"pieces-{h}.json"

    def pieces(self):
        """Every token as text, indexed by first character, for token healing.
        Cached atomically under HEAD_CACHE (pieces-<sha1>.json) so cold starts skip the 1-3 s 152k-token decode loop."""
        if getattr(self, "_by_first", None) is None:
            n = len(self.tok._tokenizer) if hasattr(self.tok, "_tokenizer") else self.tok.vocab_size
            path = self._pieces_cache_path(n)
            if path is not None and path.exists():
                try:
                    raw = json.loads(path.read_text(encoding="utf-8"))
                    if isinstance(raw, dict) and raw.get("v") == 1 and raw.get("n") == n and isinstance(raw.get("by"), dict):
                        self._by_first = {k: [(int(i), t) for i, t in lst] for k, lst in raw["by"].items()}
                        self.pieces_file = "read"
                        return self._by_first
                except (OSError, ValueError, TypeError):
                    pass
            by = {}
            for i in range(n):
                t = self.tok.decode([i])
                if t and "\ufffd" not in t: by.setdefault(t[0], []).append((i, t))
            self._by_first = by
            self.pieces_file = None
            if path is not None:
                try:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    fd, tmp = tempfile.mkstemp(prefix=".pieces-", suffix=".tmp", dir=path.parent)
                    try:
                        with os.fdopen(fd, "w", encoding="utf-8") as f:
                            json.dump({"v": 1, "n": n, "by": by}, f, ensure_ascii=False, separators=(",", ":"))
                        os.replace(tmp, path)
                        self.pieces_file = "made"
                    finally:
                        if os.path.exists(tmp): os.unlink(tmp)
                except OSError:
                    pass
        return self._by_first

    def mask(self, left, shape):
        """Additive mask allowing only tokens that fit `left`; kept per string (a space alone allows ~1/3 of the vocab)."""
        cache = self.__dict__.setdefault("_masks", {})
        m = cache.get(left)
        if m is None or m.shape != shape:
            ok = [i for i, t in self.pieces().get(left[0], []) if t.startswith(left) or left.startswith(t)]
            if not ok: return None
            m = mx.full(shape, -float("inf")); m[..., mx.array(ok)] = 0
            mx.eval(m)
            if len(cache) > 12: cache.clear()
            cache[left] = m
        return m

    def russian_mask(self, shape):
        """Tokens with letters only Russian has (ы э ъ ё): never offered; the user's text is Ukrainian or English."""
        m = getattr(self, "_ru", None)
        if m is None or m.shape != shape:
            bad = [i for lst in self.pieces().values() for i, t in lst if any(c in "ыэъёЫЭЪЁ" for c in t)]
            m = mx.zeros(shape); m[..., mx.array(bad)] = -float("inf"); mx.eval(m)
            self._ru = m
        return m

    def healer(self, need, n_prompt):
        """Logits processor: the first tokens must spell `need` (the half-typed word or space cut from the prompt)."""
        state = {"left": need, "seen": 0}

        def proc(tokens, logits):
            left = state["left"]
            if not left: return logits
            new = tokens[n_prompt + state["seen"]:].tolist() if tokens.size > n_prompt + state["seen"] else []
            for t in new:
                s = self.tok.decode([t]); state["seen"] += 1
                left = left[len(s):] if left.startswith(s) else ""
                if not left: break
            state["left"] = left
            if not left: return logits
            m = self.mask(left, logits.shape)
            return logits if m is None else logits + m
        return proc

    def booster(self, cands, n_prompt, lam):
        """Logits processor (2026-11-01, the user: "guess the words I actually use often"): the user's own next words
        (words.dist) mixed into the model's at the word level, P = (1 - lam) model + lam the user's. Each of the user's words is a
        token path; each step mixes the model's token probabilities with the share of their words still on that path,
        so a word the user writes often after these words gets the boost all the way through, and nothing else moves.
        cands: [(text the model should write, p)], the text starting with the healed half word. None when idle."""
        seqs = [(self.encode(t), p) for t, p in cands if t and p > 0]
        if not seqs or lam <= 0: return None
        st = {"pm": 1.0, "lp": None, "n": 0, "off": False, "ended": 0.0}

        def proc(tokens, logits):
            if st["off"]: return logits
            gen = tokens[n_prompt:].tolist() if tokens.size > n_prompt else []
            if len(gen) > st["n"] and st["lp"] is not None:
                st["ended"] *= math.exp(float(st["lp"][0, gen[-1]]))
                st["pm"] *= math.exp(float(st["lp"][0, gen[-1]]))     # the model's own p of the token just taken
            st["n"] = k = len(gen)
            nxt = {}
            ended = 0.0
            for seq, p in seqs:
                if len(seq) == k and seq == gen: ended += p
                if len(seq) > k and seq[:k] == gen:
                    nxt[seq[k]] = nxt.get(seq[k], 0.0) + p
            # Once a candidate ends, its mass follows the base continuation rather
            # than transferring to a longer candidate sharing its prefix.
            st["ended"] += ended
            if not nxt:
                st["off"] = True; return logits
            lp = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
            st["lp"] = lp
            pm = max(st["pm"], 1e-30)
            base = (1 - lam) * pm + lam * st["ended"]
            denom = base + lam * sum(nxt.values())
            ids = list(nxt)
            idx = mx.array(ids)
            mine = lp[..., idx].reshape(-1).tolist()
            vals = [math.log(max(1e-30, base * math.exp(x) + lam * nxt[t]) / denom) for t, x in zip(ids, mine)]
            out = lp + math.log(max(1e-30, base) / denom)
            out[..., idx] = mx.array(vals, dtype=out.dtype)
            return out
        return proc

    class Cancelled(Exception):
        pass

    def fuse_lora(self):
        """Merge the LoRA into a quantized copy of each layer it touches and put the copies in place (typing runs on
        them). Same requantization as `mlx_lm fuse` (data/fused). Each layer is merged and evaluated on its own, so the
        load never holds more than one layer's float copy. Unless KEEP_PLAIN, the LoRA module then wraps the merged
        layer and the plain one goes: `lora(False)` runs it at minus the scale. -> number of layers merged."""
        from mlx_lm.tuner.lora import LoRALinear
        self.fused = []
        for _, mod in self.model.named_modules():
            for name, child in list(mod.children().items()):
                if isinstance(child, LoRALinear):
                    sc = child.scale
                    if self.strength <= 0: merged = child.linear          # strength 0: the plain layer, no merge
                    else:
                        child.scale = sc * self.strength
                        try: merged = child.fuse()
                        finally: child.scale = sc
                        mx.eval(merged.parameters())
                        if not KEEP_PLAIN: child.linear = merged          # the plain copy has no other reference: freed
                    self.fused.append((mod, name, child, merged, sc))
        for mod, name, _, merged, _ in self.fused: setattr(mod, name, merged)
        gc.collect(); mx.clear_cache()
        return len(self.fused)

    def _tweak(self, tw):
        if not TWEAKS: return None
        import tweaks
        return tweaks.attach(self.model, tw or TWEAKS)

    def tweak_kind(self, app):
        """Bias and steering for this app's kind (ai / chat / all): read on every call, nothing reloads."""
        if getattr(self, "tw", None):
            import tweaks
            with self.lock: self.tw.kind, self.dist = tweaks.kind_of(app), None

    def lora(self, on):
        """The user's-writing layer (LoRA) on for suggestions, off for instructions (chips, rewrites): training on plain text
        took the model's instruction-following away (2026-10-19), the base model still has it."""
        if getattr(self, "tw", None): self.tw.on, self.dist = on, None
        if not self.adapter: return
        self.dist = None
        if self.fused:
            for mod, name, lora_mod, merged, sc in self.fused:
                if on or lora_mod.linear is not merged: setattr(mod, name, merged if on else lora_mod.linear)
                else:   # merged only (no plain copy kept): the merged layer minus the user's layer is the base layer
                    lora_mod.scale = -sc * self.strength
                    setattr(mod, name, lora_mod)
            return
        mods = getattr(self, "_lora_mods", None)
        if mods is None:
            mods = self._lora_mods = [(m, m.scale) for m in self.model.modules() if type(m).__name__.startswith("LoRA") and hasattr(m, "scale")]
        for m, sc in mods: m.scale = sc * getattr(self, "strength", 1.0) if on else 0.0

    def set_strength(self, strength):
        """The user's layer at another strength (0..1): the merged copies are made again in place (one model, no reload; the
        old copies go first, so memory never holds two sets), the head is read again (its file is keyed by strength).
        -> seconds it took, 0.0 when nothing changed."""
        strength = min(1.0, max(0.0, float(strength)))
        with self.lock:
            if abs(strength - self.strength) < 1e-6 or not self.adapter: self.strength = strength; return 0.0
            t = time.time()
            self.strength = strength
            if self.model is None: return 0.0            # asleep: the next load merges at the new strength
            self.loading = True                          # typing answers from the user's words meanwhile, never waits here
            try: self._restrength()
            finally: self.loading = False
            return time.time() - t

    def _restrength(self):
        """Under the lock: the merged copies made again at self.strength (the old ones go first), the head read again."""
        if FUSE and not KEEP_PLAIN:
            # the plain layers are not kept: the weights come from disk again (the old ones go first, so memory never
            # holds two models) and merge at the new strength; _ensure reads the head in again
            self._drop()
            gc.collect(); mx.clear_cache()
            self._ensure(force=True)
            return
        if FUSE:
            for mod, name, lora_mod, *_ in self.fused: setattr(mod, name, lora_mod)
            self.fused = []
            gc.collect(); mx.clear_cache()
            self.fuse_lora()
        else:
            self.lora(True)                          # _lora_mods keeps the trained scales
        self.cache, self.ids, self.snapshot, self.dist = None, [], None, None
        self.parked.clear(); self.screen = None; self.marks.clear()
        self._warm(self.head_ids)

    def oneshot(self, ids, max_tokens=60, stop=None, cancelled=lambda: False, layer=False):
        """A one-off prompt (chip fields, rewrites) on its own small cache, so the warm head stays where it is, with the
        base model (the user's-writing layer off; `layer`: on, for "Rewrite in my style"). Stops (raises Cancelled) as soon as a
        newer request arrives."""
        with self.lock:
            if not self._ensure(force=not getattr(self, "retrain_sleep", False)): return ""
            self.lora(layer)
            try:
                return self._oneshot(ids, max_tokens, stop, cancelled)
            finally:
                self.lora(True)

    def _oneshot(self, ids, max_tokens, stop, cancelled):
        cache, out = make_prompt_cache(self.model), []
        eos = set(getattr(self.tok, "eos_token_ids", None) or [self.tok.eos_token_id])
        for tok, _ in generate_step(mx.array(ids), self.model, max_tokens=max_tokens, sampler=self.sampler,
                                    prompt_cache=cache, prefill_step_size=512):
            if int(tok) in eos: break
            out.append(int(tok))
            if stop and stop.search(self.tok.decode(out)): break
            if cancelled():
                del cache; mx.clear_cache(); raise Model.Cancelled()
        del cache
        mx.clear_cache()
        return self.tok.decode(out)

    BARS = (0.3, 0.45, 0.6)   # finishing the typed word, a first new word, each further word (bench/replay.py, setup E)

    def complete(self, prompt, max_tokens=12, stop=END, cancelled=lambda: False, raw_ids=None, heal="", min_p=0.0, max_words=0, bars=None, soft=0.0, soft_from=2, screen=None, stable=None):
        """Greedy continuation. With `heal`, the output first re-spells it and only the rest is returned.
        Returns (text, first_token_ms, total_ms)."""
        with self.lock:
            if cancelled(): raise Model.Cancelled()
            ids = raw_ids if raw_ids is not None else self.bos() + self.encode(prompt)
            if self.model is None:     # asleep: typing never loads it (the wake timer or /wake does)
                self.hit_limit, self.last_p, self.sure_len = False, [], None
                return "", 0, 0
            t0 = time.perf_counter()
            self._switch(screen)
            if cancelled(): raise Model.Cancelled()
            raw0 = self._reuse(ids) if DIST else None
            tail = list(ids[-1:]) if raw0 is not None else (self._feed(ids, stable) if stable else self._feed(ids))
            out, first, n, healed_at = [], None, 0, None
            eos = set(getattr(self.tok, "eos_token_ids", None) or [self.tok.eos_token_id])
            self.hit_limit = False
            procs = ([self.healer(heal, len(tail))] if heal else []) + [lambda toks, logits: logits + self.russian_mask(logits.shape)]
            self.last_p = []
            sure = ""          # the text up to the last token the model was sure of (min_p): Clef's idea, decide by probability
            # a lighter tail (2026-10-21, Cotypist's few words): after two sure words, further words above `soft` still
            # come, and self.sure_len says where the sure part ends (the app draws the rest lighter)
            strict_end = None
            self.sure_len = None
            if cancelled(): raise Model.Cancelled()
            steps = (self._steps(ids, tail, procs, max_tokens + (6 if heal else 0), raw0) if DIST else
                     generate_step(mx.array(tail), self.model, max_tokens=max_tokens + (6 if heal else 0), sampler=self.sampler,
                                   prompt_cache=self.cache, prefill_step_size=512, logits_processors=procs))
            for tok, lp in steps:
                tok = int(tok)
                if first is None: self.ids = list(ids)  # tail was fed before the first yield
                self.ids.append(tok)   # every yielded token is already inside the cache
                if cancelled(): raise Model.Cancelled()
                if first is None: first = (time.perf_counter() - t0) * 1000
                if tok in eos: break
                p = float(mx.exp(lp[tok])) if min_p else 1.0
                self.last_p.append(round(p, 3))
                out.append(tok); n += 1
                full = self.tok.decode(out)
                # Cotypist-like (2026-10-19): finishing the word being typed needs little certainty, a new word more,
                # each further word the full min_p
                piece = self.tok.decode([tok])
                new_word = not piece[:1].isalnum() and piece[:1] not in ("'", "’", "-")
                words_so_far = len((full[len(heal):] if heal else full).split())
                bw, bn, bf = bars or self.BARS
                bar = 0 if not min_p else (bw if not new_word else (bn if words_so_far <= 1 else bf))
                soft_ok = bool(soft) and words_so_far >= soft_from and p >= soft and (new_word or strict_end is not None)
                if min_p and p < bar and soft_ok and strict_end is None:
                    strict_end = len(sure)
                if min_p and p < bar and not soft_ok:
                    # unsure from here on: keep what came before, cut back to a whole word
                    text = sure
                    piece = self.tok.decode([tok])
                    if text and piece[:1].isalnum() and not text[-1:].isspace():
                        text = text[: max(text.rfind(" "), 0)] if " " in text.strip() else ("" if not heal else text)
                    self.hit_limit = False
                    text = text.rstrip()
                    self.sure_len = min(strict_end, len(text)) if strict_end is not None else None
                    return text, first, (time.perf_counter() - t0) * 1000
                if heal and len(full) <= len(heal):
                    if cancelled(): raise Model.Cancelled()
                    continue
                if healed_at is None: healed_at = n - 1 if heal else 0   # tokens before only re-spelled the cut
                text = full[len(heal):] if heal else full
                sure = text
                if max_words and len(text.split()) > max_words:
                    text = " ".join(text.split(" ")[: max_words + (1 if text.startswith(" ") else 0)])
                    self.hit_limit = False
                    self.sure_len = min(strict_end, len(text)) if strict_end is not None else None
                    return text, first, (time.perf_counter() - t0) * 1000
                m = stop.search(text) if stop else None
                if m:
                    text = text[: m.end()].rstrip("\n")
                    self.sure_len = min(strict_end, len(text)) if strict_end is not None else None
                    return text, first, (time.perf_counter() - t0) * 1000
                if n - healed_at >= max_tokens:
                    self.hit_limit = True
                    if strict_end is not None:   # cut a half word off the light tail
                        cut = text.rfind(" ")
                        text = text[:cut] if cut > strict_end else text
                        self.sure_len = min(strict_end, len(text))
                    return text, first, (time.perf_counter() - t0) * 1000
                if cancelled(): break
            full = self.tok.decode(out)
            text = full[len(heal):] if heal and full.startswith(heal) else ("" if heal else full)
            return text, first or 0.0, (time.perf_counter() - t0) * 1000

    def complete_gated(self, raw_ids, heal, decide, more=0.5, max_words=3, max_tokens=10, cancelled=lambda: False, screen=None,
                       boost=None, lam=0.0, min_letters=0, grow=None, grow_words=6, tail=None, tail_words=8, on_part=None,
                       run=None, alts=0, stable=None, mid=None, prefill_step=512):
        """Greedy continuation decided by the gate (2026-10-31, engine/gatecore.py): as soon as the first word is whole,
        `decide(toks)` says yes or no; on no it stops at once (nothing shown, no tokens wasted), on yes further words
        come while each token stays >= `more`. toks: [text after the half word, p, p2]. Returns
        (text, gate p or None, first_token_ms, total_ms).
        min_letters / grow (2026-11-13): while the sure words add fewer than min_letters, the words after them go on at
        the lower bar `grow`, up to grow_words words (gatecore.grow); the server hides what stays short.
        tail / tail_words (round two, 2026-11-13): past those words, more words while each token is >= `tail`, up to
        tail_words words in all; they are the lighter part, and `self.last_sure` says where it starts.
        on_part(text, sure_len): called as soon as the gate said yes and whole words exist, and again each time the
        ghost grows by a whole word, so the app can draw the first words before the rest is written (two-step ghost).
        Each part starts with the one before it; the returned text starts with the last part.
        run (long round, 2026-11-14): {"mode": "phrase"|"sentence", "floor", "kind", "likely"}: after the gate's yes the
        ghost runs to the end of the sentence or clause while the running confidence holds (gatecore.run_words) instead
        of the per-token bars; self.last_conf holds the running chance after each later word, self.last_why what
        ended it. alts: keep the first letters of up to this many other likely continuations (self.last_alts), for
        the futures prepared in the gap (server.look_ahead).
        mid (mid-line round, 2026-11-15): {"rest": first token id of the rest of the caret's line, "text": that rest,
        "stop", "more", "words"}: the ghost ends where the gap is filled (engine/fim.py shape: the rest's first token
        has p >= stop at a word boundary, or the text runs into the rest); nothing when the rest is likely right away
        (nothing missing). self.last_rests holds p of the rest token at each step."""
        import gatecore, fim
        tl = time.perf_counter()
        with self.lock:
            if cancelled(): raise Model.Cancelled()
            if self.model is None: return "", None, 0, 0
            t0 = time.perf_counter()
            # where the time goes (round three, live 48-91 ms against 51 ms on the bench): waiting for the model
            # (a look-ahead or another request holds it), switching screens, tokens read anew, first token, first part
            self.timing = {"lock": round((t0 - tl) * 1000, 1)}
            self._switch(screen)
            self.timing["switch"] = round((time.perf_counter() - t0) * 1000, 1)
            if cancelled(): raise Model.Cancelled()
            raw0 = self._reuse(raw_ids) if DIST else None
            fed = list(raw_ids[-1:]) if raw0 is not None else (self._feed(raw_ids, stable) if stable else self._feed(raw_ids))
            self.timing["fed"] = 0 if raw0 is not None else len(fed)
            eos = set(getattr(self.tok, "eos_token_ids", None) or [self.tok.eos_token_id])
            procs = ([self.healer(heal, len(fed))] if heal else []) + [lambda toks, logits: logits + self.russian_mask(logits.shape)]
            bp = self.booster(boost, len(fed), lam) if boost else None
            if bp: procs.append(bp)
            toks, out, first, g, n = [], [], None, None, 0
            ms = lambda: (time.perf_counter() - t0) * 1000
            sent = [""]       # the last part given to on_part
            self.last_sure, self.last_conf, self.last_why, self.last_alts = None, [], None, []
            closed = None
            self.last_raw = ""   # what the model wrote after the half word, shown or not (server branch letters)
            rests = self.last_rests = []

            def mid_shape(closed=False):
                return fim.shape(toks, rests, mid["text"], heal, mid.get("more", fim.MORE), mid.get("words", fim.WORDS),
                                 mid.get("stop", fim.STOP), closed=closed)

            def shape(toks, closed=None):
                """-> (the ghost the recorded tokens make now, how many characters of it are the sure part)"""
                if run:
                    text, sure, why, conf = gatecore.run_words(toks, run.get("mode", "sentence"), run.get("floor", gatecore.RUN_FLOOR),
                                                               closed=closed, likely=run.get("likely", gatecore.RUN_LIKELY),
                                                               min_letters=min_letters, kind=run.get("kind", "prod"),
                                                               words=run.get("max_words"), min_words=run.get("min_words"))
                    self.last_conf, self.last_why = conf, why
                    return text, sure
                return gatecore.shape(toks, more, max_words, grow, grow_words, min_letters, tail, tail_words)
            if cancelled(): raise Model.Cancelled()
            # a job a key may stop (idle ghost, look-ahead) reads its prompt in small chunks and checks between them
            small = prefill_step < 512
            steps = (self._steps(raw_ids, fed, procs, max_tokens + (6 if heal else 0), raw0, prefill_step=prefill_step,
                                 cancelled=cancelled if small else None) if DIST else
                     generate_step(mx.array(fed), self.model, max_tokens=max_tokens + (6 if heal else 0), sampler=self.sampler,
                                   prompt_cache=self.cache, prefill_step_size=prefill_step, logits_processors=procs))
            for tok, lp in steps:
                tok = int(tok)
                if first is None: self.ids = list(raw_ids)
                self.ids.append(tok)
                if cancelled(): raise Model.Cancelled()
                if first is None:
                    first = ms(); self.timing["first"] = round(first, 1)
                    if alts: self.last_alts = self._alts(lp, heal, alts)
                if tok in eos: closed = "eos"; break
                # exp in the model's own dtype, as before the batching, so gate thresholds see the same values
                top = mx.exp(mx.topk(lp, 2))
                p_e = mx.exp(lp[tok])
                r_e = mx.exp(lp[mid["rest"]]) if mid and mid.get("rest") is not None else None
                if hasattr(mx, "eval"):
                    mx.eval(top, p_e, *([r_e] if r_e is not None else []))
                vals = sorted(top.tolist(), reverse=True)
                p = float(p_e)
                p2 = vals[1] if len(vals) > 1 else 0.0
                if mid: rests.append(float(r_e) if r_e is not None else 0.0)
                out.append(tok)
                full = self.tok.decode(out)
                text = full[len(heal):] if heal and len(full) >= len(heal) and full.startswith(heal) else ("" if heal else full)
                toks.append([text, round(p, 4), round(p2, 4)])
                self.last_raw = text
                if mid and len(toks) == 1 and mid_shape()[1] == "none": return "", None, first, ms()   # nothing missing
                if not text:
                    if cancelled(): raise Model.Cancelled()
                    continue
                n += 1
                if g is None and (gatecore.word_done(text) or END.search(text)):
                    g = decide(toks)
                    if g is None or g is False: return "", None, first, ms()
                if g is not None and mid:
                    if mid_shape()[1] != "open" or n >= max_tokens or cancelled(): break
                    continue
                if g is not None:
                    now = shape(toks)
                    if on_part is not None:
                        whole, sure = gatecore.whole_words(*now)
                        if whole and len(whole) > len(sent[0]) and whole.startswith(sent[0]):
                            sent[0] = whole; on_part(whole, sure)
                            self.timing.setdefault("part", round(ms(), 1))
                    if run:
                        if gatecore.run_settled(self.last_why): break
                        if n >= max_tokens or cancelled(): closed = "cap"; break
                        continue
                    if END.search(text): break
                    # round five: the ghost can no longer change (a whole word after it was turned down): stop here,
                    # the same text, sooner (bench/settle.py); the tokens after it were only waiting for a low one
                    if SETTLE and gatecore.settled(text, now[0], min_letters if grow is not None else 0):
                        self.timing["settled"] = n; break
                    short = grow is not None and min_letters and gatecore.letters(
                        gatecore.extend(toks, gatecore.next_word(text), more, max_words)) < min_letters
                    bars = [more] + ([grow] if short else []) + ([tail] if tail is not None else [])
                    words = max([max_words] + ([grow_words] if short else []) + ([tail_words] if tail is not None else []))
                    if tail is None and short and (p < grow or len(text.split()) > grow_words): break
                    if tail is None and not short and (p < more or len(text.split()) > max_words): break
                    if tail is not None and (p < min(bars) or len(text.split()) > words): break
                if n >= max_tokens or cancelled(): break
            if g is None:   # the reply ended inside the first word (end of text or token limit): decide on that
                g = decide(toks) if toks and toks[-1][0] else None
                if not g: return "", None, first or 0.0, ms()
            if run and closed is None and n >= max_tokens: closed = "cap"
            if mid:
                text = mid_shape(closed=closed == "eos" or n >= max_tokens)[0]
                self.last_sure = len(text)
                return text, g, first or 0.0, ms()
            text, self.last_sure = shape(toks, closed)
            return text, g, first or 0.0, ms()

    def _alts(self, lp, heal, k):
        """The next letter the user may type, from the first step's distribution (healer mask applied): the letter right
        after the half word (or space) of each of the likeliest tokens, best first by summed probability."""
        n = min(48, lp.size)
        if n <= 0: return []
        idx = mx.argpartition(-lp, n)[:n] if n < lp.size and hasattr(mx, "argpartition") else mx.argsort(-lp)[:n]
        vals = lp[idx]
        if hasattr(mx, "eval"): mx.eval(idx, vals)
        pairs = sorted(zip(vals.tolist(), idx.tolist()), key=lambda x: (-x[0], x[1]))
        score = {}
        for v, t in pairs:
            s = self.tok.decode([t])
            if not s.startswith(heal) or len(s) <= len(heal): continue
            ch = s[len(heal)]
            if heal == "" and ch == " " and len(s) > 1: ch = s.lstrip(" ")[:1]
            if not ch or ch.isspace() or ch == "\ufffd": continue
            score[ch] = score.get(ch, 0.0) + math.exp(v)
        return [c for c, _ in sorted(score.items(), key=lambda x: -x[1])[:k]]

    def prefill(self, ids, screen=None, stable=None):
        """Read ids into the cache now (on focus, before the user types), so the first suggestion only adds a few tokens."""
        with self.lock:
            if self.model is None: return 0
            self._switch(screen)
            tail = self._feed(ids, stable) if stable else self._feed(ids)
            self.ids = list(ids)
            if tail:
                steps = (self._steps(ids, tail, [], 0, prefill_step=256) if DIST else
                         generate_step(mx.array(tail), self.model, max_tokens=0, prompt_cache=self.cache, prefill_step_size=256))
                for _ in steps: pass
            return len(tail)

    def warm(self, head_ids):
        """Prefill the fixed head once and keep a copy of the cache at that point (asleep: read in when it wakes)."""
        with self.lock:
            self.head_ids = list(head_ids or [])
            if self.model is not None: self._warm(self.head_ids)

    def _warm(self, head_ids):
        self.snapshot, self.dist = None, None
        self.parked.clear(); self.screen = None   # a new head: every parked prompt starts with the old one
        self.marks.clear()                        # each copy starts with the old head
        if getattr(self, "tw", None): self.tw.start = len(head_ids or [])   # the head is never steered, so it serves every kind
        self.cache, self.ids = make_prompt_cache(self.model), []
        self.head_file = None
        if not head_ids: return   # "bare" prompts (a model trained on the user's writing needs no examples up front)
        if not self._head_read(head_ids):
            for _ in generate_step(mx.array(head_ids), self.model, max_tokens=0, prompt_cache=self.cache, prefill_step_size=256): pass
            mx.eval([c.state for c in self.cache])
            self._head_save(head_ids)
        self.ids = list(head_ids)
        # a copy costs memory; only caches that cannot be trimmed back (Gemma's sliding window) need one
        self.snapshot = None if can_trim_prompt_cache(self.cache) else (copy.deepcopy(self.cache), list(head_ids))
        mx.clear_cache()

    def head_key(self, head_ids):
        """What the head cache depends on: the model, the user's layer (path, size, time), whether it is merged, the tweaks,
        the cache classes and the head ids. Any change gives another key, so a stale file is never read."""
        parts = [str(self.repo), str(FUSE), TWEAKS, ",".join(type(c).__name__ for c in self.cache or [])]
        if getattr(self, "strength", 1.0) != 1.0: parts.append(f"strength={self.strength:.3f}")   # 1.0 keeps today's key
        if self.adapter:
            f = Path(self.adapter) / "adapters.safetensors"
            try: st = f.stat(); parts += [str(f), str(st.st_size), str(st.st_mtime_ns)]
            except OSError: parts += [str(f), "missing"]
        parts.append(",".join(map(str, head_ids)))
        return hashlib.sha1("|".join(parts).encode()).hexdigest()[:20]

    def head_path(self, key):
        return Path(HEAD_CACHE) / f"head-{key}.safetensors" if HEAD_CACHE else None

    def _head_read(self, head_ids):
        """The head's cache from its file, when the file is there and matches. -> True when read (else nothing changed)."""
        try:
            key = self.head_key(head_ids)
            p = self.head_path(key)
            if p is None or not p.exists(): return False
            cache, meta = load_prompt_cache(str(p), return_metadata=True)
            if meta.get("key") != key or int(meta.get("tokens", -1)) != len(head_ids) or len(cache) != len(self.cache): return False
            if [type(c).__name__ for c in cache] != [type(c).__name__ for c in self.cache]: return False
            if getattr(cache[0], "offset", len(head_ids)) != len(head_ids): return False
            mx.eval([c.state for c in cache])
            self.cache, self.head_file = cache, "read"
            return True
        except Exception as e:
            print(f"head cache: not read ({type(e).__name__})", flush=True)
            return False

    def _head_save(self, head_ids):
        """Write the head's cache once per key; old head files go (only ours, by name)."""
        try:
            key = self.head_key(head_ids)
            p = self.head_path(key)
            if p is None or p.exists(): return
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_name(p.stem + ".tmp.safetensors")
            save_prompt_cache(str(tmp), self.cache, {"key": key, "tokens": str(len(head_ids))})
            os.replace(tmp, p)
            self.head_file = "made"
            olds = sorted((q for q in p.parent.glob("head-*.safetensors") if q != p and ".tmp." not in q.name),
                          key=lambda q: q.stat().st_mtime)
            for q in olds[:-8]: q.unlink(missing_ok=True)    # a few kept: switching back (another catalog model, another strength) reads it
        except Exception as e:
            print(f"head cache: not saved ({type(e).__name__})", flush=True)

    def memory_gb(self):
        return mx.get_active_memory() / 2**30, mx.get_peak_memory() / 2**30

    def kv_gb(self):
        """What the prompt caches hold, by kind (engine memory round, 2026-11-17; /health "kv_gb"): the active screen,
        the parked screens, the copies after the screen text and after the head. Buffers as allocated (KVCache grows
        256 tokens at a time), so a cache cut back still counts what it reached. Read without the lock: a number."""
        def size(cache):
            n = 0
            for c in cache or []:
                for a in (getattr(c, "keys", None), getattr(c, "values", None)):
                    for x in (a if isinstance(a, (tuple, list)) else (a,)):
                        n += getattr(x, "nbytes", 0) or 0
            return n
        try:
            parked = sum(size(c) for _, c in list(self.parked.values()))
            marks = sum(size(c) for c, _ in list(self.marks.values()))
            snap = size(self.snapshot[0]) if self.snapshot else 0
            out = {"active": size(self.cache), "parked": parked, "marks": marks, "head_copy": snap}
        except Exception:
            return {}
        return {k: round(v / 2**30, 3) for k, v in out.items()} | {"screens": 1 + len(self.parked)}
