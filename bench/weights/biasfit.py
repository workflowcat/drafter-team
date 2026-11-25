"""Item B2, the pure part: fit a per-token additive logit bias b on stored next-token distributions, by gradient
descent (one step size per token), with no model.

bench/weights/collect.py first tokenises the fitting lines and picks the candidate tokens F: the ones he wrote at
least `min_count` times (at most a few thousand). It then stores, for every position, the model's log-probability of
each token in F, plus the token he wrote and its log-probability. Only tokens in F get a bias; every other token keeps
b = 0, so the mass outside F needs no detail and the fit is exact:
    Z = sum over t in F of p_t e^{b_t}  +  (1 - sum over t in F of p_t)
    loss = - mean over positions of (log p_y + b_y - log Z)  +  lam/2 |b|^2       (b_y = 0 when y is outside F)
    d loss / d b_t = (expected count of t under the biased model - count of t he wrote) / positions + lam b_t
At the optimum the model offers each token of F as often as he writes it, in context: a calibrated prior toward his
words, names and language mix. lam is picked on held-out positions."""
import numpy as np


def candidates(token_lists, min_count=5, most=3000):
    """Token ids written at least `min_count` times in the tokenised lines, the `most` frequent at most."""
    counts = {}
    for toks in token_lists:
        for t in toks: counts[t] = counts.get(t, 0) + 1
    keep = sorted((t for t, c in counts.items() if c >= min_count), key=lambda t: -counts[t])[:most]
    return np.array(sorted(keep), np.int64)


def pack(cand, cand_lp, y, y_lp):
    """cand (F,) ids, cand_lp (N, F) log-probabilities, y (N,) the token he wrote, y_lp (N,) its log-probability."""
    cand = np.asarray(cand, np.int64)
    p = np.exp(np.asarray(cand_lp, np.float32))     # float32: 32,000 positions x 2,000 candidates is 256 MB
    y = np.asarray(y, np.int64)
    col = {int(t): i for i, t in enumerate(cand)}
    ycol = np.array([col.get(int(t), -1) for t in y], np.int64)
    return {"cand": cand, "p": p, "out": np.clip(1.0 - p.sum(1, dtype=np.float64), 1e-9, None), "y": y, "ycol": ycol,
            "y_lp": np.asarray(y_lp, np.float64), "n": len(y)}


def loss_grad(b, d, lam, curv=False):
    """(loss, gradient[, curvature]) for the bias values `b` (one per candidate). The curvature is the diagonal of the
    Hessian, mean of q (1 - q) over positions, plus lam."""
    w = d["p"] * np.exp(b).astype(np.float32)[None, :]
    z = w.sum(1, dtype=np.float64) + d["out"]
    by = np.where(d["ycol"] >= 0, b[np.maximum(d["ycol"], 0)], 0.0)
    loss = -np.mean(d["y_lp"] + by - np.log(z)) + 0.5 * lam * float(b @ b)
    q = w / z[:, None].astype(np.float32)
    written = np.bincount(d["ycol"][d["ycol"] >= 0], minlength=len(b))
    g = (q.sum(0, dtype=np.float64) - written) / d["n"] + lam * b
    if not curv: return loss, g
    return loss, g, (q * (1 - q)).sum(0, dtype=np.float64) / d["n"] + lam


def nll(b, d):
    return loss_grad(b, d, 0.0)[0]


def fit(d, lam=1e-4, steps=200, eta=0.5, cap=4.0):
    """Gradient descent from b = 0 where each token's step is divided by its own curvature (with one step size for all,
    rare tokens would need thousands of steps; this is the classic proportional-fitting update), damped by `eta`,
    every value kept within +-cap. -> (b per candidate, [loss per step])"""
    b, hist = np.zeros(len(d["cand"])), []
    for _ in range(steps):
        loss, g, h = loss_grad(b, d, lam, curv=True)
        hist.append(loss)
        b = np.clip(b - eta * g / h, -cap, cap)
    return b, hist


def dense(b, cand, vocab):
    out = np.zeros(vocab, np.float32)
    out[np.asarray(cand)] = b
    return out


def split(d, every=5, part=0):
    """(fit part, validation part): every `every`-th position from `part` validates."""
    m = (np.arange(d["n"]) % every) == part
    take = lambda k: {"cand": d["cand"], "p": d["p"][k], "out": d["out"][k], "y": d["y"][k], "ycol": d["ycol"][k],
                      "y_lp": d["y_lp"][k], "n": int(k.sum())}
    return take(~m), take(m)


def choose(d, lams=(1e-2, 3e-3, 1e-3, 3e-4, 1e-4), steps=200, cap=4.0):
    """Fit on 4/5 of the positions for each lam, keep the one with the lowest held-out loss, refit on all.
    -> {"lam", "b", "valid": {lam: (loss with no bias, loss fitted)}}"""
    tr, va = split(d)
    report, best = {}, None
    for lam in lams:
        b, _ = fit(tr, lam, steps, cap=cap)
        report[lam] = (round(nll(np.zeros(len(b)), va), 5), round(nll(b, va), 5))
        if best is None or report[lam][1] < report[best][1]: best = lam
    b, _ = fit(d, best, steps, cap=cap)
    return {"lam": best, "b": b, "valid": report}
