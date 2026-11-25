"""Remote training driver (bench/remote_train.py) with ssh and rsync mocked: the command order, the caps on the
container, only the adapter coming back, the server folder removed on success and on failure, the dry run running
nothing, the smoke run's made-up lines, and retrain.py's switch. Nothing leaves the Mac; no model loads.

    .venv/bin/python -B tests/test_remote_train.py
"""
import io, json, sys, tempfile, unittest
from contextlib import redirect_stdout
from pathlib import Path

import numpy as np
from safetensors.numpy import save_file

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))
import remote_train as RT
RT.HOST = "build-box"   # a made-up ssh alias: the test never reads the live config
from lora_recipe import RECIPE


def fake_peft(folder, total=36, layers=16, r=8):
    w = {}
    for n in range(total - layers, total):
        for key, (i, o) in {"self_attn.q_proj": (8, 8), "mlp.down_proj": (12, 8)}.items():
            w[f"base_model.model.model.layers.{n}.{key}.lora_A.weight"] = np.ones((r, i), np.float32)
            w[f"base_model.model.model.layers.{n}.{key}.lora_B.weight"] = np.ones((o, r), np.float32)
    save_file(w, str(folder / "adapter_model.safetensors"))
    (folder / "adapter_config.json").write_text(json.dumps({"r": r, "lora_alpha": 160, "lora_dropout": 0.0, "bias": "none"}))
    (folder / "meta.json").write_text(json.dumps({"num_hidden_layers": total, "seconds": 7200, "sec_per_step": 4.8,
                                                  "peak_gb_cgroup": 11.2, "peak_gb_rss": 10.9}))
    (folder / "train.log").write_text("done\n")


class Server:
    """Records each command; the pull-back rsync drops a made-up PEFT adapter in the local folder."""
    def __init__(self, fail_on=None):
        self.calls, self.fail_on, self.sent = [], fail_on, None

    def __call__(self, argv, timeout):
        self.calls.append(argv)
        if argv[0] == "rsync" and argv[-1].startswith("build-box:") and argv[-1].endswith("/data/"):
            self.sent = {f.name: f.read_text() for f in Path(argv[-2]).iterdir()}
        if self.fail_on and self.fail_on in " ".join(argv): raise RuntimeError("boom")
        if argv[0] == "rsync" and "--exclude=*" in argv: fake_peft(Path(argv[-1]))


class Driver(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        self.train = self.dir / "train"; self.train.mkdir()
        for name, n in (("train.jsonl", 8), ("valid.jsonl", 2)):
            (self.train / name).write_text("".join(json.dumps({"text": f"[Claude]\nmade-up {i}", "src": "cc"}) + "\n" for i in range(n)))
        self.out = io.StringIO()

    def tearDown(self): self.tmp.cleanup()

    def go(self, server, **kw):
        with redirect_stdout(self.out):
            return RT.train_remote(out=self.dir / "layer", train_dir=self.train, runner=server, **kw)

    def test_order_caps_and_cleanup(self):
        s = Server()
        meta = self.go(s)
        heads = [" ".join(c[:2]) for c in s.calls]
        self.assertEqual(heads, ["ssh build-box", "rsync -a", "ssh build-box", "rsync -a", "ssh build-box", "rsync -a", "ssh build-box"])
        docker = s.calls[4][2]
        for part in ("docker run --rm", "--cpus 10", "--memory 24g", "--memory-swap 24g", "nice -n 19", "drafter-hf-cache:/cache",
                     "--base Qwen/Qwen3-4B-Instruct-2507", f"--iters {RECIPE['iters']}", "--rank 8", "--scale 20.0",
                     "--layers 16", "--lr 0.0001", "--batch 4", "--max-seq 256", "--seed 7", ":/work/data:ro"):
            self.assertIn(part, docker)
        self.assertIn("$HOME/drafter-train/run-", docker)             # unquoted, so the server shell expands it
        back = s.calls[5]
        self.assertIn("--exclude=*", back)
        self.assertEqual({a.split("=", 1)[1] for a in back if a.startswith("--include=")}, set(RT.BACK))
        run = s.calls[0][2].split()[-1].rsplit("/", 1)[0]
        self.assertIn(f"rm -rf {run}", s.calls[-1][2]); self.assertIn("docker rm -f", s.calls[-1][2])
        self.assertTrue((self.dir / "layer/adapters.safetensors").exists())
        cfg = json.loads((self.dir / "layer/adapter_config.json").read_text())
        self.assertEqual((cfg["num_layers"], cfg["lora_parameters"]["scale"], cfg["model"]),
                         (16, 20.0, "mlx-community/Qwen3-4B-Instruct-2507-4bit"))
        self.assertEqual(meta["sec_per_step"], 4.8)
        printed = self.out.getvalue()
        self.assertIn("peak memory 11.2 GB", printed); self.assertIn("training 2.00 h", printed)

    def test_only_text_goes_up(self):
        s = Server(); self.go(s)
        rows = [json.loads(l) for l in s.sent["train.jsonl"].splitlines()]
        self.assertEqual(len(rows), 8); self.assertEqual(set().union(*rows), {"text"})
        self.assertEqual(sorted(s.sent), ["train.jsonl", "valid.jsonl"])

    def test_cleanup_runs_when_training_fails(self):
        for where in ("docker run", "docker build", "--exclude=*"):
            with self.subTest(where):
                s = Server(fail_on=where)
                with self.assertRaises(RuntimeError): self.go(s)
                self.assertIn("rm -rf drafter-train/run-", s.calls[-1][2])

    def test_dry_run_runs_nothing(self):
        s = Server()
        self.assertEqual(self.go(s, dry_run=True), {})
        self.assertEqual(s.calls, [])
        printed = self.out.getvalue()
        for label in ("[mkdir]", "[image files]", "[build]", "[lines up]", "[train]", "[back]", "[clean]"):
            self.assertIn(label, printed)

    def test_smoke_reads_no_lines_of_his(self):
        s = Server()
        with redirect_stdout(self.out):
            RT.train_remote(out=self.dir / "layer", train_dir=self.dir / "nowhere", smoke=True, model="1.7b", runner=s)
        self.assertEqual(len(s.sent["train.jsonl"].splitlines()) + len(s.sent["valid.jsonl"].splitlines()), 50)
        self.assertIn(f"--iters {RT.SMOKE_ITERS}", s.calls[4][2]); self.assertIn("--base Qwen/Qwen3-1.7B ", s.calls[4][2])
        self.assertIn("a full run of 1500 steps", self.out.getvalue())

    def test_unknown_model_refused(self):
        with self.assertRaises(SystemExit): RT.hf_base("org/other")


class RetrainSwitch(unittest.TestCase):
    def test_flag_or_setting(self):
        sys.path.insert(1, str(ROOT / "engine"))
        import retrain, local
        on = lambda name: name == "server"
        host = lambda name, key=None, default=None: "build-box" if (name, key) == ("server", "host") else default
        old = (local.enabled, local.setting)
        local.enabled, local.setting = on, host   # a made-up config: never the live one
        self.addCleanup(lambda: setattr(local, "enabled", old[0]) or setattr(local, "setting", old[1]))
        self.assertTrue(retrain.remote_wanted(["retrain.py", "--remote"], {}))
        self.assertTrue(retrain.remote_wanted(["retrain.py"], {"retrainRemote": True}))
        self.assertFalse(retrain.remote_wanted(["retrain.py"], {"retrainRemote": False}))
        self.assertFalse(retrain.remote_wanted(["retrain.py"], {}))
        local.enabled = lambda name: False   # integration off: train on the Mac even when asked
        self.assertFalse(retrain.remote_wanted(["retrain.py", "--remote"], {}))
        self.assertEqual(retrain.base_model({}), "mlx-community/Qwen3-1.7B-4bit")
        self.assertEqual(retrain.base_model({"model": "mlx-community/Qwen3-4B-Instruct-2507-4bit"}), "mlx-community/Qwen3-4B-Instruct-2507-4bit")


class Recipe(unittest.TestCase):
    def test_mlx_trainer_reads_the_same_recipe(self):
        src = (ROOT / "bench/train.py").read_text()
        self.assertIn("from lora_recipe import RECIPE", src)
        for literal in ('"--batch-size", "4"', '"--learning-rate", "1e-4"', '"--num-layers", "16"'):
            self.assertNotIn(literal, src)
        self.assertIn('RECIPE["iters"]', (ROOT / "bench/retrain.py").read_text())


if __name__ == "__main__":
    unittest.main()
