"""multilingual-e5-small in plain numpy: the query side of the journal index (engine/journal_index.py) on the Mac.

The index is built on your server (integrations.server) with PyTorch (bench/remote/jobs/job.py); a query on the Mac needs the same vector
without torch. A BERT forward pass is 12 small layers, and a query is a few tokens, so numpy does it in milliseconds.
The weights are memory-mapped (safetensors) and only the word rows a query uses are read from the 250k-row table, so
the resident cost is the 12 layers (~85 MB in float32), not the whole 470 MB file.

    from embed_np import Encoder
    e = Encoder(folder)              # config.json, model.safetensors, sentencepiece.bpe.model (else tokenizer.json)
    v = e.encode(["query: what did we agree with the printer"])   # (n, 384), unit length

E5 wants "query: " before a question and "passage: " before an indexed text; callers add it.
The same file runs in the jobs container to check that torch and numpy agree (job.py --check)."""
import json, math
from pathlib import Path

import numpy as np

REPO = "intfloat/multilingual-e5-small"
MAX_TOKENS = 512
FILES = ["config.json", "tokenizer.json", "sentencepiece.bpe.model", "model.safetensors"]


def _gelu(x):
    # BERT's exact gelu (erf); numpy has no erf, so the tanh form within 1e-3 would drift: use math.erf vectorized
    return 0.5 * x * (1.0 + _erf(x / math.sqrt(2.0)))


def _erf(x):
    # Abramowitz-Stegun 7.1.26 is 1.5e-7 off at most: far below float32 noise after 12 layers of LayerNorm
    s = np.sign(x); a = np.abs(x)
    t = 1.0 / (1.0 + 0.3275911 * a)
    y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * np.exp(-a * a)
    return s * y


def _norm(x, w, b, eps):
    m = x.mean(-1, keepdims=True)
    v = ((x - m) ** 2).mean(-1, keepdims=True)
    return (x - m) / np.sqrt(v + eps) * w + b


class Encoder:
    def __init__(self, folder):
        from safetensors import safe_open
        folder = Path(folder)
        self.cfg = json.loads((folder / "config.json").read_text())
        self.ids = self._spm(folder) or self._fast(folder)
        self._f = safe_open(str(folder / "model.safetensors"), framework="np")
        keys = list(self._f.keys())
        self.pre = "bert." if any(k.startswith("bert.") for k in keys) else ""
        g = lambda k: self._f.get_tensor(self.pre + k).astype(np.float32)
        self.words = self._f.get_slice(self.pre + "embeddings.word_embeddings.weight")
        self._cache = {}
        self.pos = g("embeddings.position_embeddings.weight")
        self.typ = g("embeddings.token_type_embeddings.weight")[0]
        self.eln = (g("embeddings.LayerNorm.weight"), g("embeddings.LayerNorm.bias"))
        self.eps = float(self.cfg.get("layer_norm_eps", 1e-12))
        self.heads = int(self.cfg["num_attention_heads"])
        self.layers = []
        for i in range(int(self.cfg["num_hidden_layers"])):
            p = f"encoder.layer.{i}."
            self.layers.append({n: g(p + k) for n, k in {
                "q": "attention.self.query.weight", "qb": "attention.self.query.bias",
                "k": "attention.self.key.weight", "kb": "attention.self.key.bias",
                "v": "attention.self.value.weight", "vb": "attention.self.value.bias",
                "o": "attention.output.dense.weight", "ob": "attention.output.dense.bias",
                "l1": "attention.output.LayerNorm.weight", "l1b": "attention.output.LayerNorm.bias",
                "i": "intermediate.dense.weight", "ib": "intermediate.dense.bias",
                "u": "output.dense.weight", "ub": "output.dense.bias",
                "l2": "output.LayerNorm.weight", "l2b": "output.LayerNorm.bias"}.items()})

    @staticmethod
    def _spm(folder):
        """XLM-R's own sentencepiece file: the same ids as tokenizer.json (fairseq offset: <s> 0, </s> 2, <unk> 3,
        piece + 1) at ~100 MB less than the fast tokenizer's 250k-entry table (~350 MB)."""
        f = folder / "sentencepiece.bpe.model"
        try:
            import sentencepiece
            sp = sentencepiece.SentencePieceProcessor(model_file=str(f))
        except Exception:
            return None
        return lambda t: [0] + [i + 1 if i else 3 for i in sp.encode(t)][: MAX_TOKENS - 2] + [2]

    @staticmethod
    def _fast(folder):
        from tokenizers import Tokenizer
        tok = Tokenizer.from_file(str(folder / "tokenizer.json"))
        tok.no_padding(); tok.enable_truncation(MAX_TOKENS)
        return lambda t: tok.encode(t).ids

    def _row(self, i):
        r = self._cache.get(i)
        if r is None:
            r = np.asarray(self.words[i:i + 1], dtype=np.float32)[0]
            if len(self._cache) < 20000: self._cache[i] = r
        return r

    def _one(self, ids):
        rows = {i: self._row(i) for i in set(ids)}       # only these rows are read from the 250k-row table
        x = np.stack([rows[i] for i in ids]) + self.pos[: len(ids)] + self.typ
        x = _norm(x, *self.eln, self.eps)
        n, d = x.shape; h = self.heads; hd = d // h
        for L in self.layers:
            q = (x @ L["q"].T + L["qb"]).reshape(n, h, hd).transpose(1, 0, 2)
            k = (x @ L["k"].T + L["kb"]).reshape(n, h, hd).transpose(1, 0, 2)
            v = (x @ L["v"].T + L["vb"]).reshape(n, h, hd).transpose(1, 0, 2)
            a = q @ k.transpose(0, 2, 1) / math.sqrt(hd)
            a = np.exp(a - a.max(-1, keepdims=True)); a /= a.sum(-1, keepdims=True)
            c = (a @ v).transpose(1, 0, 2).reshape(n, d)
            x = _norm(x + c @ L["o"].T + L["ob"], L["l1"], L["l1b"], self.eps)
            f = _gelu(x @ L["i"].T + L["ib"]) @ L["u"].T + L["ub"]
            x = _norm(x + f, L["l2"], L["l2b"], self.eps)
        v = x.mean(0)                                   # mean pooling (no padding: one text at a time)
        return v / (np.linalg.norm(v) + 1e-12)

    def encode(self, texts):
        return np.stack([self._one(self.ids(t)) for t in texts]).astype(np.float32)


def local_folder(repo=REPO, online=False):
    """The model's files on this Mac (Hugging Face cache); with online, fetched once when missing. None when absent."""
    try:
        from huggingface_hub import snapshot_download
        return Path(snapshot_download(repo, allow_patterns=FILES, local_files_only=not online))
    except Exception:
        return None
