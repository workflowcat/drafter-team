"""Model catalog (2026-11-15): the catalog's shape, the recommendation rule on made-up Macs and tables, weights found
in a made-up cache, the download he starts (a stand-in process), and the switch order with a stand-in model (no
real model loads here).

    .venv/bin/python -B tests/test_catalog.py
"""
import json, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import catalog as C
from server_src import lift

KEYS = {"id", "name", "repo", "rev", "disk_gb", "memory_gb", "cap_gb", "p50_ms", "p95_ms", "words_shown", "words_all",
        "kept_per_1k", "first_word_pct", "languages", "layer", "gate"}


def row(mid, mem, p95, words, first=40.0, layer=False):
    return {"id": mid, "name": mid, "repo": f"org/{mid}", "rev": None, "disk_gb": 1.0, "memory_gb": mem, "cap_gb": mem + 1,
            "p50_ms": p95 // 2, "p95_ms": p95, "words_shown": words * 2, "words_all": words, "kept_per_1k": 250,
            "first_word_pct": first, "languages": ["uk", "en"], "layer": layer, "gate": "live" if layer else "default"}


class Shape(unittest.TestCase):
    def test_every_entry_has_every_field(self):
        ms = C.load()
        self.assertEqual(ms[0]["id"], C.LIVE)
        self.assertEqual(len({m["id"] for m in ms}), len(ms))
        for m in ms:
            self.assertEqual(KEYS - set(m), set(), m["id"])
            self.assertGreater(m["p95_ms"], m["p50_ms"])
            self.assertGreaterEqual(m["cap_gb"], m["memory_gb"])
            self.assertTrue(m["repo"].count("/") == 1)

    def test_only_live_has_the_live_layer_and_gate_others_a_folder_under_layers(self):
        for m in C.load():
            self.assertEqual(m["layer"] is True, m["id"] == C.LIVE)
            if isinstance(m["layer"], str):
                self.assertTrue(m["layer"].startswith(C.LAYERS + "/"), m["id"])
                self.assertNotIn("adapters", m["layer"])
                self.assertIsNotNone(C.layer_dir(m, "/data"))
            self.assertEqual(m["gate"] == "live", m["id"] == C.LIVE)
            if m["gate"] != "live":
                g = json.loads((ROOT / "engine/defaults" / m["gate"]).read_text())
                self.assertEqual(len(g["w"]), len(g["names"]))
                self.assertTrue(all(isinstance(v, (int, float)) for v in g["w"]))   # numbers only

    def test_trial_numbers(self):
        live = C.entry(C.load(), C.LIVE)
        self.assertEqual((live["words_all"], live["first_word_pct"], live["p95_ms"], live["memory_gb"]), (0.91, 42.9, 126, 2.74))
        self.assertIsNone(C.entry(C.load(), "gemma4-e4b"))     # dropped after the trial


class Recommend(unittest.TestCase):
    def test_this_mac_gets_live(self):
        mid, why = C.recommend(C.load(), 24.0, free_gb=10.0, current_gb=2.7)
        self.assertEqual(mid, C.LIVE)                              # the 4B with his layer is better but p95 244 > 150
        self.assertIn("own layer", why); self.assertNotIn("only one", why)
        self.assertEqual(C.best_quality(C.load()), "qwen3-4b-mine")

    def test_the_4b_with_his_layer_numbers(self):
        m = C.entry(C.load(), "qwen3-4b-mine")
        self.assertEqual((m["words_all"], m["kept_per_1k"], m["first_word_pct"], m["p95_ms"]), (0.97, 318, 45.9, 165))
        self.assertEqual((m["repo"], m["layer"], m["gate"]), (C.entry(C.load(), "qwen3-4b")["repo"], "layers/qwen3-4b",
                                                             "gates/qwen3-4b-layer.json"))

    def test_budget(self):
        self.assertEqual(C.budget_gb(24.0), 6.0)                  # a quarter of 24
        self.assertEqual(C.budget_gb(16.0), 4.0)
        self.assertLess(C.budget_gb(8.0), 0)                       # 8 - 6 - 3.4: nothing has room
        self.assertEqual(C.budget_gb(24.0, free_gb=3.0, current_gb=2.0), 4.0)   # free now plus what the switch gives back

    def test_best_quality_under_the_speed_limit(self):
        t = [row("a", 2, 120, 0.80), row("b", 2, 140, 0.90), row("c", 2, 200, 0.99)]
        self.assertEqual(C.recommend(t, 24)[0], "b")              # c is better but too slow
        self.assertEqual(C.recommend(t, 24, speed_scale=1.1)[0], "a")   # a slower Mac: b's 154 ms is over
        self.assertEqual(C.recommend(t, 24, p95_limit=250)[0], "c")

    def test_memory_budget(self):
        t = [row("big", 5.5, 100, 0.95), row("small", 2.0, 120, 0.80)]
        self.assertEqual(C.recommend(t, 24)[0], "big")
        self.assertEqual(C.recommend(t, 16)[0], "small")           # 4 GB budget
        self.assertEqual(C.recommend(t, 24, free_gb=4.0)[0], "small")

    def test_ties_go_to_first_words(self):
        t = [row("a", 2, 100, 0.8, first=38), row("b", 2, 100, 0.8, first=41)]
        self.assertEqual(C.recommend(t, 24)[0], "b")

    def test_none_quick_takes_the_fastest_that_fits(self):
        t = [row("a", 2, 300, 0.9), row("b", 2, 200, 0.7), row("c", 9, 50, 0.99)]
        mid, why = C.recommend(t, 24)
        self.assertEqual(mid, "b"); self.assertIn("fastest", why)

    def test_none_fits_takes_the_smallest(self):
        t = [row("a", 3, 100, 0.9), row("b", 2, 200, 0.7)]
        mid, why = C.recommend(t, 8)
        self.assertEqual(mid, "b"); self.assertIn("smallest", why)

    def test_marks(self):
        ms = C.load()
        live = C.entry(ms, C.LIVE)
        self.assertEqual((C.speed_mark(live), C.quality_mark(ms, live)), (3, 2))     # 0.91 against 0.97: within 12 %
        mine = C.entry(ms, "qwen3-4b-mine")
        self.assertEqual((C.speed_mark(mine), C.quality_mark(ms, mine)), (1, 3))
        self.assertEqual([m["id"] for m in ms if C.quality_mark(ms, m) == 3], ["qwen3-4b-mine"])   # the one best
        self.assertEqual(C.speed_mark(C.entry(ms, "qwen3-4b")), 1)
        self.assertEqual(C.quality_mark(ms, C.entry(ms, "gemma4-e2b")), 1)


def fake_snapshot(cache, repo, rev="abc", files=("config.json", "model.safetensors"), main=True):
    d = C.repo_dir(repo, cache)
    snap = d / "snapshots" / rev
    snap.mkdir(parents=True)
    for f in files: (snap / f).write_bytes(b"x" * 10)
    if main: (d / "refs").mkdir(); (d / "refs" / "main").write_text(rev)
    return snap


class Weights(unittest.TestCase):
    def test_found_and_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            m = row("m", 1, 100, 0.8)
            self.assertIsNone(C.local_path(m, tmp))
            snap = fake_snapshot(tmp, m["repo"])
            self.assertEqual(C.local_path(m, tmp), snap)
            self.assertIsNone(C.local_path({**m, "rev": "other"}, tmp))   # a pinned revision that is not here

    def test_half_a_sharded_model_is_not_downloaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            m = row("m", 1, 100, 0.8)
            snap = fake_snapshot(tmp, m["repo"], files=("config.json", "model-1.safetensors"))
            (snap / "model.safetensors.index.json").write_text(json.dumps({"weight_map": {"a": "model-1.safetensors", "b": "model-2.safetensors"}}))
            self.assertFalse(C.downloaded(m, tmp))
            (snap / "model-2.safetensors").write_bytes(b"x")
            self.assertTrue(C.downloaded(m, tmp))


class FakeProc:
    def __init__(self): self.code, self.killed = None, False
    def poll(self): return self.code
    def terminate(self): self.code, self.killed = -15, True
    def wait(self, t=None): return self.code
    def kill(self): self.code = -9


class Downloads(unittest.TestCase):
    def test_start_progress_cancel(self):
        with tempfile.TemporaryDirectory() as tmp:
            m = {**row("m", 1, 100, 0.8), "disk_gb": 1e-7}       # 100 bytes
            procs = []
            d = C.Downloads(spawn=lambda e: procs.append(FakeProc()) or procs[-1], cache=tmp)
            self.assertEqual(d.state(m)["state"], "none")             # nothing starts by itself
            self.assertEqual(d.start(m)["state"], "downloading")
            d.start(m)
            self.assertEqual(len(procs), 1)                           # pressing again does not start a second one
            blobs = C.repo_dir(m["repo"], tmp) / "blobs"; blobs.mkdir(parents=True)
            (blobs / "x.incomplete").write_bytes(b"x" * 40)
            self.assertEqual(d.state(m)["pct"], 40)
            self.assertTrue(d.cancel("m"))
            self.assertTrue(procs[0].killed)
            self.assertEqual(d.state(m)["state"], "cancelled")
            self.assertFalse(d.cancel("m"))

    def test_done(self):
        with tempfile.TemporaryDirectory() as tmp:
            m = row("m", 1, 100, 0.8)
            p = FakeProc()
            d = C.Downloads(spawn=lambda e: p, cache=tmp)
            d.start(m)
            fake_snapshot(tmp, m["repo"]); p.code = 0
            self.assertEqual(d.state(m), {"state": "done", "pct": 100})
            self.assertEqual(d.start(m)["state"], "done")             # already here: no process


def fake_layer(data, name="layers/mine"):
    d = Path(data) / name
    d.mkdir(parents=True)
    (d / "adapters.safetensors").write_bytes(b"x"); (d / "adapter_config.json").write_text("{}")
    return d


class Layer(unittest.TestCase):
    """An entry's own layer under data/layers/ (16 November 2026); live keeps the live layer."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.data = self.tmp.name
        self.mine = {**row("mine", 4.2, 244, 0.97), "layer": "layers/mine", "gate": "gates/mine-layer.json"}
        self.base = {**row("base", 2.9, 228, 0.87), "repo": self.mine["repo"], "gate": "gates/base.json"}

    def tearDown(self): self.tmp.cleanup()

    def test_live_and_no_layer_unchanged(self):
        live = row("live", 2.7, 126, 0.91, layer=True)
        self.assertEqual(C.adapter_for(live, "/data/adapters", self.data), "/data/adapters")
        self.assertIsNone(C.adapter_for(row("x", 2, 100, 0.8), "/data/adapters", self.data))
        self.assertEqual(C.gate_name([live], live, True), "live")
        self.assertTrue(C.has_layer(live, None, self.data))

    def test_an_entry_with_a_layer_gets_it(self):
        d = fake_layer(self.data)
        self.assertEqual(C.adapter_for(self.mine, "/data/adapters", self.data), str(d.resolve()))
        self.assertTrue(C.has_layer(self.mine, None, self.data))
        self.assertEqual(C.gate_name([self.base, self.mine], self.mine, True), "gates/mine-layer.json")

    def test_a_missing_layer_runs_the_base_with_the_base_gate_and_a_log_line(self):
        import io, contextlib
        out = io.StringIO()
        with contextlib.redirect_stdout(out): got = C.adapter_for(self.mine, "/data/adapters", self.data)
        self.assertIsNone(got)
        self.assertIn("model layer: mine has no layer here", out.getvalue())
        self.assertFalse(C.has_layer(self.mine, None, self.data))
        self.assertEqual(C.gate_name([self.base, self.mine], self.mine, False), "gates/base.json")
        self.assertIsNone(C.gate_name([self.mine], self.mine, False))              # no base entry: the shipped default
        (Path(self.data) / "layers/mine").mkdir(parents=True)                       # a folder without the weights
        self.assertIsNone(C.adapter_for(self.mine, None, self.data, log=False))

    def test_a_layer_never_leaves_data_layers(self):
        fake_layer(self.data, "adapters")
        for bad in ("adapters", "layers/../adapters", "layers", "/etc", "layers/"):
            self.assertIsNone(C.adapter_for({**self.mine, "layer": bad}, None, self.data, log=False), bad)

    def test_switch_and_back(self):
        d = fake_layer(self.data)
        live = row("live", 2.7, 126, 0.91, layer=True); live["repo"] = "org/live"
        m = StandIn()
        got, err, _ = C.switch(m, self.mine, live, "/live-layer", rebuild=lambda: None, set_cap=lambda gb: None,
                               data=self.data, src_for=lambda e: "/snap" if e["id"] != "live" else None)
        self.assertEqual((got["id"], err), ("mine", None))
        self.assertIn(f"load org/mine {d.resolve()} /snap", m.log)
        got, err, _ = C.switch(m, live, live, "/live-layer", rebuild=lambda: None, set_cap=lambda gb: None,
                               data=self.data, src_for=lambda e: "/snap" if e["id"] != "live" else None)
        self.assertEqual(m.log[-1], "load org/live /live-layer None")

    def test_switch_with_the_layer_missing_loads_the_base(self):
        live = row("live", 2.7, 126, 0.91, layer=True); live["repo"] = "org/live"
        m = StandIn()
        got, err, _ = C.switch(m, self.mine, live, "/live-layer", rebuild=lambda: None, set_cap=lambda gb: None,
                               data=self.data, src_for=lambda e: "/snap" if e["id"] != "live" else None)
        self.assertEqual((got["id"], err, m.log[-1]), ("mine", None, "load org/mine None /snap"))

    def test_server_start_and_gate_use_the_entry_layer(self):
        # the start path is module code in server.py: the non-live pick loads with its own layer
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn("Model(REPO, catalog.adapter_for(_pick, ADAPTER, DATA), strength=strength_setting(), src=", src)
        self.assertNotIn("Model(REPO, None, strength", src)
        self.assertIn("catalog.switch(model, target, LIVE_ENTRY, ADAPTER", src)
        import types
        defaults = Path(self.data) / "defaults"; (defaults / "gates").mkdir(parents=True)
        for f in ("gate.json", "gates/mine-layer.json", "gates/base.json"): (defaults / f).write_text("{}")
        ns = lift("gate_file", "fitted", DATA=Path(self.data), DEFAULTS=defaults, catalog=C, CATALOG=[self.base, self.mine],
                  CURRENT={"entry": self.mine}, model=types.SimpleNamespace(adapter="/x"))
        self.assertEqual(ns["gate_file"](), defaults / "gates/mine-layer.json")
        ns["model"] = types.SimpleNamespace(adapter=None)                      # the layer was missing at load
        self.assertEqual(ns["gate_file"](), defaults / "gates/base.json")
        ns["CURRENT"] = {"entry": row("live", 2.7, 126, 0.91, layer=True)}
        self.assertEqual(ns["gate_file"](), defaults / "gate.json")           # live: data/gate.json, else the default


class StandIn:
    """Records what the switch does to the model, in order."""
    def __init__(self, fail=()):
        self.log, self.fail, self.loaded = [], set(fail), "org/live"
    def loaded_gb(self): return 2.0 if self.loaded else 0.0
    def unload(self): self.log.append("unload"); self.loaded = None
    def load_as(self, repo, adapter=None, src=None):
        if self.loaded: raise RuntimeError("two models")
        self.log.append(f"load {repo} {adapter} {src}")
        if repo in self.fail: raise MemoryError("stand-in")
        self.loaded = repo


class Switch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.live = row("live", 2.7, 126, 0.91, layer=True); self.live["repo"] = "org/live"
        self.other = row("other", 1.9, 142, 0.83)

    def tearDown(self): self.tmp.cleanup()

    def go(self, m, target, src="/snap", free_gb=None):
        caps, heads = [], []
        out = C.switch(m, target, self.live, "/layer", rebuild=lambda: (heads.append(m.loaded), m.log.append("head")),
                       set_cap=lambda gb: (caps.append(gb), m.log.append(f"cap {gb}")), data=self.tmp.name,
                       src_for=lambda e: src if e["id"] != "live" else None, free_gb=free_gb)
        return out, caps, heads

    def test_unload_before_load_and_no_layer_on_another_model(self):
        m = StandIn()
        (got, err, _), caps, _ = self.go(m, self.other)
        self.assertEqual((got["id"], err), ("other", None))
        self.assertEqual(m.log, ["unload", f"cap {self.other['cap_gb']}", "load org/other None /snap", "head"])
        self.assertFalse(C.marker_path(self.tmp.name).exists())

    def test_back_to_live_keeps_his_layer(self):
        m = StandIn(); m.loaded = "org/other"
        (got, err, _), _, _ = self.go(m, self.live)
        self.assertEqual(got["id"], "live")
        self.assertIn("load org/live /layer None", m.log)

    def test_a_failed_load_falls_back_to_live(self):
        m = StandIn(fail={"org/other"})
        (got, err, _), caps, heads = self.go(m, self.other)
        self.assertEqual((got["id"], err), ("live", "MemoryError"))
        self.assertEqual(m.log, ["unload", f"cap {self.other['cap_gb']}", "load org/other None /snap",
                                 "unload", f"cap {self.live['cap_gb']}", "load org/live /layer None", "head"])
        self.assertEqual(caps[-1], self.live["cap_gb"])
        self.assertEqual(heads, ["org/live"])

    def test_not_downloaded_changes_nothing(self):
        m = StandIn()
        (got, err, _), _, _ = self.go(m, self.other, src=None)
        self.assertEqual((got, err, m.log), (None, "not downloaded", []))

    def test_too_little_memory_changes_nothing(self):
        m = StandIn()
        (got, err, _), _, _ = self.go(m, {**self.other, "memory_gb": 5.0}, free_gb=2.0)   # 2 free + 2 back - 1 margin
        self.assertEqual((got, err, m.log), (None, "not enough free memory", []))

    def test_a_load_the_guard_stopped_starts_live_next_time(self):
        ms = [self.live, self.other]
        with tempfile.TemporaryDirectory() as cache:
            fake_snapshot(cache, "org/other")
            st = {"typingModel": "other"}
            self.assertEqual(C.start_pick(ms, st, self.tmp.name, cache=cache)[0]["id"], "other")
            mk = C.marker_path(self.tmp.name); mk.parent.mkdir(parents=True, exist_ok=True); mk.write_text("{}")
            pick, why = C.start_pick(ms, st, self.tmp.name, cache=cache)
            self.assertEqual(pick["id"], "live"); self.assertFalse(mk.exists())
            self.assertEqual(C.start_pick(ms, st, self.tmp.name, cache=cache)[0]["id"], "other")   # once only
        self.assertEqual(C.start_pick(ms, {"typingModel": "other"}, self.tmp.name, cache=self.tmp.name)[0]["id"], "live")  # not here
        self.assertEqual(C.start_pick(ms, {}, self.tmp.name, env_repo="org/other")[0]["id"], "other")

    def test_the_apps_old_model_setting_does_not_hide_his_pick(self):
        # the app passes settings "model" (the live repo) as DRAFTER_MODEL on every start
        ms = [self.live, self.other]
        with tempfile.TemporaryDirectory() as cache:
            fake_snapshot(cache, "org/other")
            st = {"typingModel": "other", "model": self.live["repo"]}
            self.assertEqual(C.start_pick(ms, st, self.tmp.name, env_repo=self.live["repo"], cache=cache)[0]["id"], "other")
            self.assertEqual(C.start_pick(ms, {"model": self.live["repo"]}, self.tmp.name, env_repo=self.live["repo"], cache=cache)[0]["id"], "live")
            self.assertEqual(C.start_pick(ms, st, self.tmp.name, env_repo="org/other", cache=cache)[0]["id"], "other")   # a bench repo wins
        self.assertIsNone(C.start_pick(ms, {}, self.tmp.name, env_repo="org/bench")[0])


class Here(unittest.TestCase):
    """A new person's Mac: no layer, so no "+ my style" name and no pick on layer numbers (team round, 25 November 2026)."""

    def setUp(self):
        self.live = {**row("live", 2.7, 126, 0.91, layer=True), "name": "Small + my style"}
        self.mine = row("big-mine", 4.2, 140, 0.97, layer="layers/big")
        self.plain = row("big", 2.9, 140, 0.87)

    def test_no_layer_gives_the_plain_list(self):
        with tempfile.TemporaryDirectory() as data:
            ms = C.here([self.live, self.mine, self.plain], None, data)
            self.assertEqual([m["id"] for m in ms], ["live", "big"])
            self.assertEqual(ms[0]["name"], "Small"); self.assertFalse(ms[0]["layer"])
            self.assertEqual(C.recommend(C.ranked(ms), 24)[0], "big")
            self.assertIn("your own layer", C.recommend([self.live], 24)[1])

    def test_with_layers_nothing_changes(self):
        with tempfile.TemporaryDirectory() as data:
            ad = Path(data) / "adapters"; ad.mkdir(); (ad / "adapters.safetensors").write_text("x")
            lay = Path(data) / "layers" / "big"; lay.mkdir(parents=True)
            (lay / "adapters.safetensors").write_text("x"); (lay / "adapter_config.json").write_text("{}")
            ms = C.here([self.live, self.mine, self.plain], str(ad), data)
            self.assertEqual(ms, [self.live, self.mine, self.plain])


if __name__ == "__main__":
    unittest.main()
