"""Direct weight tweaks for typing: a learned per-token logit bias and steering vectors. Off unless DRAFTER_TWEAKS names
a file (weights round, 2026-11-14: docs/rounds/2026-11-14-weights.md; made by bench/weights/bias.py and steer.py).

The file is an .npz with any of
  bias_<kind>   (vocab,)  added to the logits: a calibrated next-token prior (his words, names, language mix)
  steer_<kind>  (hidden,) added to the output of block `layer` for tokens after the fixed head, times `strength`
  meta          JSON text: {"layer": 14, "strength": 1.0}
<kind> is "all", "ai" or "chat"; the kind in force picks its own entry and falls back to "all".

Nothing is reloaded to switch: the model object and one block get a subclass whose __call__ adds the tweak, and
Tweaks.on / .kind / .strength are read on every call. Model.lora(False) (chips, rewrites) turns them off with the layer."""
import json, os

import numpy as np
import mlx.core as mx

KINDS = ("all", "ai", "chat")
CHAT_APPS = ("beeper", "whatsapp", "telegram", "signal", "slack", "messages", "discord", "messenger")
AI_APPS = ("claude", "chatgpt", "codex", "cursor", "gemini", "perplexity", "terminal", "ghostty", "iterm")


def kind_of(app):
    a = (app or "").lower()
    if any(x in a for x in CHAT_APPS): return "chat"
    if any(x in a for x in AI_APPS): return "ai"
    return "all"


class Tweaks:
    def __init__(self, bias=None, steer=None, layer=14, strength=1.0, kind="all"):
        self.bias = {k: mx.array(np.asarray(v, dtype=np.float32)) for k, v in (bias or {}).items()}
        self.steer = {k: mx.array(np.asarray(v, dtype=np.float32)) for k, v in (steer or {}).items()}
        self.layer, self.strength, self.kind = int(layer), float(strength), kind
        self.on, self.start = True, 0     # start: tokens before it (the fixed head) are never steered

    def pick(self, d):
        return d.get(self.kind, d.get("all"))

    @classmethod
    def load(cls, path, kind=None):
        z = np.load(path)
        meta = json.loads(str(z["meta"])) if "meta" in z.files else {}
        get = lambda pre: {f[len(pre):]: z[f] for f in z.files if f.startswith(pre)}
        return cls(get("bias_"), get("steer_"), meta.get("layer", 14),
                   float(os.environ.get("DRAFTER_TWEAKS_STRENGTH", meta.get("strength", 1.0))),
                   kind or os.environ.get("DRAFTER_TWEAKS_KIND", "all"))


def _top_class(base):
    def __call__(self, *a, **k):
        out = base.__call__(self, *a, **k)
        tw = self._drafter_tw
        b = tw.pick(tw.bias) if tw.on else None
        return out if b is None else out + b.astype(out.dtype)
    return type(base.__name__ + "Tweaked", (base,), {"__call__": __call__, "_drafter_base": base})


def _block_class(base):
    def __call__(self, x, mask=None, cache=None):
        off = getattr(cache, "offset", 0) if cache is not None else 0   # read before attention moves it
        out = base.__call__(self, x, mask, cache)
        tw = self._drafter_tw
        v = tw.pick(tw.steer) if tw.on and tw.strength else None
        if v is None: return out
        add = (tw.strength * v).astype(out.dtype)
        n = out.shape[1]
        if off >= tw.start: return out + add
        keep = (mx.arange(off, off + n) >= tw.start).astype(out.dtype)[None, :, None]
        return out + keep * add
    return type(base.__name__ + "Tweaked", (base,), {"__call__": __call__, "_drafter_base": base})


def _swap(obj, make):
    cls = type(obj)
    if not hasattr(cls, "_drafter_base"): obj.__class__ = make(cls)


def attach(model, tw):
    """Hook `tw` (a Tweaks, or a path to load) into a loaded mlx_lm model. -> the Tweaks in force."""
    if isinstance(tw, (str, os.PathLike)): tw = Tweaks.load(tw)
    if tw.bias:
        _swap(model, _top_class)
        model._drafter_tw = tw
    if tw.steer:
        block = model.layers[tw.layer]
        _swap(block, _block_class)
        block._drafter_tw = tw
    return tw
