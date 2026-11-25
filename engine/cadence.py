"""Cadence routing (cadence round, 2026-11-17; docs/rounds/2026-11-17-cadence.md): two typing models in the one
engine, one GPU queue, one model per key. The fast one (the live Qwen3 1.7B + his layer) answers while he types fast,
the picked bigger one (qwen3-4b-mine) in longer gaps. Pure rules here; engine/server.py holds the second slot.

Measured on held-137 (bench/cadence_replay.py, policy current-2026-11-16, his live key gaps): a gap under 120 ms to the
fast model gives +9.3 kept letters per 1,000 and key-to-ghost p95 134 ms against 155 for the 4B alone.
A 4B extension of the fast ghost in the time left added nothing (-0.1 kept letters): not built."""

CADENCE_MS = 120.0    # the gap before this key under which the fast model answers (his median gap is about 100 ms)
FAST_ID = "live"      # the fast slot: the catalog's live entry (Qwen3 1.7B + data/adapters)
FAST_GB = 2.0         # what the fast slot adds to the engine's footprint (bench/cadence_mem.py: 1.70 GB, rounded up)


def wanted(req, current_id):
    """The app asked for two models (setting comboModels) and the loaded model is not the fast one itself."""
    return bool(req.get("combo")) and current_id not in (None, FAST_ID)


def gap_ms(req):
    """The gap before this key in ms, as the app measured it; None when unknown (first key, after a pause it
    did not time, a bench request)."""
    try: g = float(req.get("gap_ms"))
    except (TypeError, ValueError): return None
    return g if g > 0 else None


def route(req, fast_ready, current_id, th=CADENCE_MS):
    """-> "fast" or "big" for this request. Fast only for ordinary typing: combo on, the slot loaded, a known gap
    under `th`; idle ghosts, mid-line gaps and Tab follow-ups (no gap) stay on the picked model."""
    if not fast_ready or not wanted(req, current_id): return "big"
    if req.get("idle") or req.get("mid"): return "big"
    g = gap_ms(req)
    return "fast" if g is not None and g < th else "big"


def fits(cap_gb, budget_cap_gb, fast_gb=FAST_GB):
    """The fast slot may load when the engine's cap with it stays within `budget_cap_gb` (the combined cap)."""
    return cap_gb + fast_gb <= budget_cap_gb + 1e-9
