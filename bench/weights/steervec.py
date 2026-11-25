"""Item B3, the pure part: steering vectors from mean hidden states (no model here).

bench/weights/collect.py stores one row per line: the mean hidden state at the output of block `layer` over the line's
own tokens (the prompt head and the app tag left out), and the mean norm of a single token's hidden state there.
A steering vector is a difference of group means; at typing time engine/tweaks.py adds strength x vector to the
block's output for every token after the fixed head. Vectors are stored at the size of a typical hidden state times
`rel`, so strength 1.0 means the same push for every vector."""
import numpy as np


def vector(a, b):
    """Mean of group a minus mean of group b (rows are lines)."""
    return np.asarray(a, np.float64).mean(0) - np.asarray(b, np.float64).mean(0)


def kind_vectors(groups):
    """{kind: rows} -> {kind: its mean minus the centre of all kinds' means} (each kind weighs the same, however many
    lines it has, so the vectors add up to zero)."""
    means = {k: np.asarray(v, np.float64).mean(0) for k, v in groups.items() if len(v)}
    centre = np.mean(list(means.values()), 0)
    return {k: m - centre for k, m in means.items()}


def scale_to(v, token_norm, rel):
    """v resized to rel x the typical hidden-state norm."""
    n = float(np.linalg.norm(v))
    return v * 0 if n == 0 else v * (rel * token_norm / n)


def cosine(u, v):
    nu, nv = float(np.linalg.norm(u)), float(np.linalg.norm(v))
    return 0.0 if not nu or not nv else float(u @ v / (nu * nv))


def holdout_accuracy(a, b, every=5):
    """How well the direction separates the groups on lines it was not made from: the vector from 4/5 of each group,
    each held-out line put on the side of the midpoint its projection falls. 0.5 = no direction at all."""
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    ma, mb = np.arange(len(a)) % every == 0, np.arange(len(b)) % every == 0
    if not ma.any() or not mb.any() or ma.all() or mb.all(): return None
    v = vector(a[~ma], b[~mb])
    mid = (a[~ma].mean(0) + b[~mb].mean(0)) / 2
    right = np.concatenate([(a[ma] - mid) @ v > 0, (b[mb] - mid) @ v <= 0])
    return float(right.mean())
