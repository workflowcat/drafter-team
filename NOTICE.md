# Notices

Drafter is MIT licensed ([LICENSE](LICENSE)). This page lists every part that came from elsewhere, where it came
from and under which licence.

## In this repository

No third-party art or fonts: the app uses the system font and SF Symbols (23 November 2026).

## Downloaded at setup, not in this repository

Each part keeps its own licence. Nothing below is shipped in this repository; the scripts and the app fetch them.

### Models

| Part | Fetched by | Origin | Licence |
|---|---|---|---|
| Qwen3-1.7B, 4-bit MLX (`mlx-community/Qwen3-1.7B-4bit`) | `scripts/download_models.py`; catalog id `live` | Alibaba Qwen team; conversion by mlx-community | Apache-2.0 |
| Qwen3.5 2B Base, a community fine-tune in 4-bit MLX (`Muesli-HQ/qwen35-2b-base-cotypist-mlx-4bit`, pinned revision) | Settings > Typing > Model; catalog id `qwen35-2b` | Base model by the Alibaba Qwen team (`Qwen/Qwen3.5-2B-Base`); fine-tune and conversion by Muesli-HQ | Apache-2.0 |
| Qwen3-4B-Instruct-2507, 4-bit MLX (`mlx-community/Qwen3-4B-Instruct-2507-4bit`) | Settings > Typing > Model; catalog ids `qwen3-4b`, `qwen3-4b-mine` | Alibaba Qwen team; conversion by mlx-community | Apache-2.0 |
| Gemma 4 E2B, 4-bit MLX (`mlx-community/gemma-4-e2b-4bit`) | Settings > Typing > Model; catalog id `gemma4-e2b` | Google (`google/gemma-4-e2b`); conversion by mlx-community | Apache-2.0 (its model card) |
| Parakeet TDT 0.6B v3 (`mlx-community/parakeet-tdt-0.6b-v3`) | `scripts/download_models.py --voice` | NVIDIA; conversion by mlx-community | CC-BY-4.0 |
| Whisper large-v3-turbo (`mlx-community/whisper-large-v3-turbo`) | `scripts/download_models.py --voice` | OpenAI; conversion by mlx-community | MIT |
| 3D-Speaker ERes2Net base, speaker vectors (`3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx`) | `scripts/download_speakers.py` | Alibaba 3D-Speaker project; ONNX export from the sherpa-onnx releases (k2-fsa) | Apache-2.0 |

The typing models are listed in `engine/catalog.json`; a model added there must get a row here.

### Thesauri (synonyms on ⌥Tab)

Fetched by `scripts/download_thesaurus.py` from the LibreOffice dictionaries repository, pinned to one commit. The
script saves each licence text next to the file in `models/thesaurus/`.

| Part | Origin | Licence |
|---|---|---|
| `th_en_US_v2.dat`, English thesaurus | Princeton University, WordNet 2.1 | WordNet licence (`WordNet_license.txt`) |
| `th_uk_UA.dat`, Ukrainian thesaurus 1.6.0 | Andriy Rysin, after two published Ukrainian synonym dictionaries | GPL, LGPL or MPL, at your choice (`README_th_uk_UA.txt`) |

### Libraries

| Part | Origin | Licence |
|---|---|---|
| Python packages | `requirements-lock.txt` | Each package's own licence |
