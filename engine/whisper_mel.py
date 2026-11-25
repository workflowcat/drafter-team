"""Whisper's log-Mel spectrogram a block of frames at a time (engine memory round, 2026-11-17).

mlx_whisper 0.4.3 builds the whole recording's STFT at once: for an 84 min call that is ~0.8 GB of complex frames and
~0.4 GB of magnitudes next to Whisper's 1.6 GB, which is where the voice engine's 3.2 GB peak came from. Each frame
depends only on its own 400 samples, so the same numbers come out block by block (tests/test_whisper_mel.py checks
them against mlx_whisper's own function); only the last clamp needs the whole, and it runs on the small Mel array.
install() puts it in place of mlx_whisper.transcribe's log_mel_spectrogram; nothing else changes."""
import sys

import mlx.core as mx

FRAMES = 6000          # 60 s of frames a block: ~10 MB of complex STFT
MIN_FRAMES = 1000      # smaller blocks take other FFT and matmul kernels: the last bit of a number can differ


def log_mel_spectrogram(audio, n_mels=80, padding=0, frames=FRAMES):
    from mlx_whisper.audio import HOP_LENGTH, N_FFT, hanning, load_audio, mel_filters
    if isinstance(audio, str): audio = load_audio(audio)
    elif not isinstance(audio, mx.array): audio = mx.array(audio)
    if padding > 0: audio = mx.pad(audio, (0, padding))
    window, half = hanning(N_FFT), N_FFT // 2
    x = mx.concatenate([audio[1:half + 1][::-1], audio, audio[-(half + 1):-1][::-1]])   # stft's reflect padding
    t = (x.size - N_FFT + HOP_LENGTH) // HOP_LENGTH
    # MLX's rfft reads two real rows as one complex row: blocks start on even rows and the frame mlx_whisper drops
    # (freqs[:-1]) is still read, so every row meets the same partner as in the whole and the numbers are the same
    frames = max(MIN_FRAMES, frames + frames % 2)
    filters = mel_filters(n_mels)
    parts = []
    for s in range(0, t, frames):
        # a short last block is read from an earlier even row (a whole block's worth) and cut: small blocks take other
        # kernels whose last bit differs
        a = s if t - s >= frames else max(0, t - frames) // 2 * 2
        seg = x[a * HOP_LENGTH:(t if s + frames >= t else s + frames) * HOP_LENGTH - HOP_LENGTH + N_FFT]
        n = (seg.size - N_FFT) // HOP_LENGTH + 1
        seg = mx.as_strided(seg, shape=[n, N_FFT], strides=[HOP_LENGTH, 1])
        part = mx.maximum(mx.fft.rfft(seg * window).abs().square() @ filters.T, 1e-10).log10()[s - a:]
        if s + frames >= t: part = part[:-1]
        mx.eval(part)
        parts.append(part)
    log_spec = mx.concatenate(parts) if parts else mx.zeros((0, n_mels))
    log_spec = mx.maximum(log_spec, log_spec.max() - 8.0)
    return (log_spec + 4.0) / 4.0


def install():
    """Use it inside mlx_whisper.transcribe. -> True when in place, False when that module is not there (a stand-in)."""
    import mlx_whisper  # noqa: F401  (the package's `transcribe` name is the function, the module is in sys.modules)
    wt = sys.modules.get("mlx_whisper.transcribe")
    if wt is None or not hasattr(wt, "log_mel_spectrogram"): return False
    wt.log_mel_spectrogram = log_mel_spectrogram
    return True
