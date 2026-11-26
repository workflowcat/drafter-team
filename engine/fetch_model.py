"""One catalog model's weights into the Hugging Face cache, started by the engine only when the user presses Download in
Settings > Typing > Model (engine/catalog.py Downloads). Never imports MLX, never loads a model. The engine stops it by
its exact process to cancel; what came in stays in the cache, and the next Download goes on from there.

    .venv/bin/python -B engine/fetch_model.py <repo> [revision]
    .venv/bin/python -B engine/fetch_model.py --id <catalog id>    # the repo and pinned revision from engine/catalog.json
"""
import os, sys

os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ.pop("HF_HUB_OFFLINE", None)

# what mlx_lm.load reads: weights, config, tokenizer (no README, images or other formats)
PATTERNS = ["*.json", "*.safetensors", "*.txt", "*.model", "*.jinja", "*.tiktoken"]

if __name__ == "__main__":
    from huggingface_hub import snapshot_download
    if sys.argv[1:2] == ["--id"]:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import catalog
        m = catalog.entry(catalog.load(), sys.argv[2] if len(sys.argv) > 2 else "")
        if not m: sys.exit("no such catalog id: " + " ".join(sys.argv[2:3]) + " (see engine/catalog.json)")
        repo, rev = m["repo"], m.get("rev") or None
    else:
        repo = sys.argv[1]
        rev = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
    path = snapshot_download(repo_id=repo, revision=rev, allow_patterns=PATTERNS)
    print("fetched", flush=True)
