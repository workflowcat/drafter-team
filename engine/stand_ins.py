"""Narrow optional-dependency adapters for the pinned Parakeet/Whisper readers.

Install before importing either reader. Real packages always win, including a real
package whose import is broken (we must not hide that error). This is deliberately
not a general replacement for librosa, numba or scipy. Whisper segment times work;
word alignment needs the real scipy package.
"""
import importlib.util
from importlib.machinery import ModuleSpec
import sys
from types import ModuleType

import numpy as np


def mel(*, sr, n_fft, n_mels=128, fmin=0.0, fmax=None, htk=False,
        norm="slaney", dtype=np.float32):
    """Slaney triangular filters, with librosa's float64 math / float32 rounding.

    Supported contract: parakeet_mlx.audio.PreprocessArgs in parakeet-mlx 0.5.3.
    Reject other normalization/scales instead of silently changing the audio.
    """
    if htk or norm != "slaney":
        raise ValueError("Drafter's mel adapter supports only Slaney scale and normalization")
    fmax = float(sr) / 2 if fmax is None else fmax
    if sr <= 0 or n_fft <= 0 or n_mels <= 0 or not 0 <= fmin < fmax <= sr / 2:
        raise ValueError("Invalid mel filterbank dimensions or frequency limits")
    n_mels = int(n_mels)
    step = 200.0 / 3
    log_step = np.log(6.4) / 27.0

    def hz_to_mel(hz):
        return hz / step if hz < 1000 else 15.0 + np.log(hz / 1000.0) / log_step

    points = np.linspace(hz_to_mel(fmin), hz_to_mel(fmax), n_mels + 2)
    frequencies = step * points
    logarithmic = points >= 15.0
    frequencies[logarithmic] = 1000.0 * np.exp(log_step * (points[logarithmic] - 15.0))
    bins = np.fft.rfftfreq(n=n_fft, d=1.0 / sr)
    widths = np.diff(frequencies)
    ramps = np.subtract.outer(frequencies, bins)
    weights = np.zeros((n_mels, 1 + n_fft // 2), dtype=dtype)
    for i in range(n_mels):
        weights[i] = np.maximum(0, np.minimum(-ramps[i] / widths[i], ramps[i + 2] / widths[i + 1]))
    # Round each triangle into dtype BEFORE normalization, just as librosa does.
    weights *= (2.0 / (frequencies[2:] - frequencies[:-2]))[:, np.newaxis]
    return weights


def jit(function=None, **options):
    """The two @numba.jit(...) uses in Whisper timing need only a decorator."""
    if function is None:
        return lambda fn: fn
    if not callable(function):
        raise TypeError("Drafter's jit adapter accepts a function, not a signature")
    return function


def _word_timestamps_unavailable(*args, **kwargs):
    raise RuntimeError("Whisper word timestamps require real scipy; Drafter uses segment timestamps only")


def _module(name, package=False):
    module = ModuleType(name)
    module.__spec__ = ModuleSpec(name, loader=None, is_package=package)
    module.__package__ = name if package else name.rpartition(".")[0]
    module.__drafter_stand_in__ = True
    if package:
        module.__path__ = []
    return module


def _missing(name):
    return name not in sys.modules and importlib.util.find_spec(name) is None


def install():
    """Register only absent top-level packages; repeated calls are harmless."""
    installed = []
    if _missing("librosa"):
        package, filters = _module("librosa", True), _module("librosa.filters")
        filters.mel = mel
        package.filters = filters
        sys.modules.update({"librosa": package, "librosa.filters": filters})
        installed.append("librosa")
    if _missing("numba"):
        package = _module("numba")
        package.jit = jit
        sys.modules["numba"] = package
        installed.append("numba")
    if _missing("scipy"):
        package, signal = _module("scipy", True), _module("scipy.signal")
        signal.medfilt = _word_timestamps_unavailable
        package.signal = signal
        sys.modules.update({"scipy": package, "scipy.signal": signal})
        installed.append("scipy")
    return installed
