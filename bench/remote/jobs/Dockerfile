# Drafter's background jobs on your server (no GPU): careful re-transcribe (faster-whisper, CTranslate2 int8 on CPU)
# and the journal index (a small multilingual embedding model, CPU-only PyTorch).
# Built on the server by bench/jobs.py:  docker build -q -t drafter-jobs ~/drafter-jobs/image
# Models live in the named volume drafter-hf-cache (mounted at /cache), never in the image or a job folder.
FROM python:3.12-slim
ENV PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    HF_HOME=/cache HF_HUB_DISABLE_TELEMETRY=1 TOKENIZERS_PARALLELISM=false
RUN pip install --index-url https://download.pytorch.org/whl/cpu torch==2.6.0 \
 && pip install numpy==2.2.4 transformers==4.51.3 safetensors==0.5.3 faster-whisper==1.1.1 sentencepiece==0.2.0
COPY job.py /app/job.py
COPY embed_np.py /app/embed_np.py
WORKDIR /app
