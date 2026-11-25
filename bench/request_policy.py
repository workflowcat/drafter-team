"""Bench-only request presets. No settings reads, services, model loads or runtime imports.

The dated current mode freezes the ordinary end-of-line request flags from 2026-11-16.
It does not turn a model-only replay into the live selector or simulate in-flight work
in a static replay. Each caller keeps its gate, timing rules and output schema.
Historical modes remain the defaults so old commands keep their results.
"""
from dataclasses import dataclass

CURRENT = "current-2026-11-16"
EARLIER = "historical-earlier"
BIG = "historical-big"
SELECTOR = "historical-selector"


@dataclass
class RequestPolicy:
    mode: str
    request: dict
    guess_bar: float | None = None

    def run_kwargs(self):
        """Arguments for earlier.ghost; historical selector uses lengths.policy instead."""
        r = self.request
        if "length" not in r:
            raise ValueError("historical-selector uses lengths.policy")
        out = {"mode": r["length"], "floor": r["floor"], "cap": r["cap"], "min_letters": r["min_letters"]}
        if r["length"] == "words":
            out.update(min_words=r["words_min"], max_words=r["words_max"])
        return out

    def timing_kwargs(self):
        """Only earlier.timed models request retention. Static scorers carry this flag only."""
        return {"keep": self.request.get("keep_on", False)}


def build(mode):
    """Return fresh flags, never a shared mutable preset. Guess enablement and its bar are separate."""
    if mode == CURRENT:
        return RequestPolicy(mode, {"length": "words", "floor": 0.1, "cap": 24,
                                    "words_min": 3, "words_max": 5, "min_letters": 3,
                                    "guess": True, "guess_shade": True, "keep_on": True}, 0.3)
    if mode in (EARLIER, BIG):
        return RequestPolicy(mode, {"length": "sentence", "floor": 0.1, "cap": 24, "min_letters": 5})
    if mode == SELECTOR:
        return RequestPolicy(mode, {"min_letters": 5, "grow": 0.05, "tail": 0.2, "tail_words": 8})
    raise ValueError(f"unknown bench request mode: {mode}")


def add_argument(parser, historical):
    parser.add_argument("--policy-mode", choices=(historical, CURRENT), default=historical,
                        help="dated request flags; default preserves historical presets and output")
