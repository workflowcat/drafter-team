# The layer trainer for your server (integrations.server) (no GPU): Python, CPU-only PyTorch, transformers, peft.
# Built on the server by bench/remote_train.py:  docker build -q -t drafter-train ~/drafter-train/image
# The Hugging Face base lives in the named volume drafter-hf-cache (mounted at /cache), never in the image or a run.
FROM python:3.12-slim
ENV PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    HF_HOME=/cache HF_HUB_DISABLE_TELEMETRY=1 TOKENIZERS_PARALLELISM=false
RUN pip install --index-url https://download.pytorch.org/whl/cpu torch==2.6.0 \
 && pip install numpy==2.2.4 transformers==4.51.3 peft==0.15.2 accelerate==1.6.0 safetensors==0.5.3
COPY train_lora.py /app/train_lora.py
WORKDIR /app
