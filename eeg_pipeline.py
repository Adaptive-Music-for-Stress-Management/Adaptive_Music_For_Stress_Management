"""Muse EEG preprocessing, band-power graphs, and live Signal-JEPA inference.

The Muse 2 emits TP9, AF7, AF8, and TP10 at 256 Hz. Every graph refresh uses
the latest four-channel signal to create the joint two-second, 128 Hz window
expected by the bundled UNIVERSE Signal-JEPA classifier.
"""

from __future__ import annotations

from collections import OrderedDict, deque
from fractions import Fraction
import json
import math
import os
import time

import numpy as np
from scipy.signal import butter, filtfilt, iirnotch, resample_poly, sosfiltfilt, welch


MUSE_EEG_RATE = 256.0
MUSE_PPG_RATE = 64.0
MODEL_SAMPLE_RATE = 128.0
MODEL_WINDOW_SECONDS = 2.0
FILTER_CONTEXT_SECONDS = 4.0
MODEL_WINDOW_SAMPLES = int(MODEL_SAMPLE_RATE * MODEL_WINDOW_SECONDS)
MUSE_WINDOW_SAMPLES = int(MUSE_EEG_RATE * FILTER_CONTEXT_SECONDS)

EEG_CHANNELS = ("left_ear", "left_brain", "right_brain", "right_ear")
MUSE_CHANNEL_LABELS = ("TP9", "AF7", "AF8", "TP10")
STRESS_CLASS_LABELS = ("Low stress", "High stress")
STRESSED_CLASS_INDEX = 1

BANDS = OrderedDict((
    ("delta", (1.0, 4.0)),
    ("theta", (4.0, 8.0)),
    ("alpha", (8.0, 13.0)),
    ("beta", (13.0, 30.0)),
    ("gamma", (30.0, 45.0)),
))


def _resample(values: np.ndarray, source_rate: float, target_rate: float) -> np.ndarray:
    if math.isclose(source_rate, target_rate, rel_tol=0.0, abs_tol=1e-6):
        return values
    ratio = Fraction(target_rate / source_rate).limit_denominator(1000)
    return resample_poly(values, ratio.numerator, ratio.denominator, axis=-1)


def prepare_model_window(values, source_rate: float) -> np.ndarray:
    """Create the four-channel window expected by the trained Signal-JEPA model.

    Live Muse data is average-referenced, filtered like the UNIVERSE source,
    resampled to 128 Hz, cropped to the most recent two seconds, and then
    standardized independently per channel/window.
    """
    data = np.asarray(values, dtype=np.float64)
    if data.ndim != 2 or data.shape[0] != len(EEG_CHANNELS):
        raise ValueError("EEG model input must contain TP9, AF7, AF8 and TP10")
    minimum = int(round(source_rate * MODEL_WINDOW_SECONDS))
    if data.shape[1] < minimum:
        raise ValueError(
            f"need at least {minimum} EEG samples per channel, received {data.shape[1]}"
        )
    if not np.isfinite(data).all():
        raise ValueError("EEG model input contains non-finite samples")

    context = int(round(source_rate * FILTER_CONTEXT_SECONDS))
    data = data[:, -context:].copy()

    # Match the preprocessing recorded for the UNIVERSE training data. Filtering
    # the longer live context before cropping reduces edge effects in the model
    # window while preserving the model's exact two-second input shape.
    data -= data.mean(axis=0, keepdims=True)
    bandpass = butter(4, (0.5, 50.0), btype="bandpass", fs=source_rate, output="sos")
    data = sosfiltfilt(bandpass, data, axis=-1)
    notch_b, notch_a = iirnotch(50.0, 30.0, fs=source_rate)
    data = filtfilt(notch_b, notch_a, data, axis=-1)
    data = _resample(data, source_rate, MODEL_SAMPLE_RATE)
    data = data[:, -MODEL_WINDOW_SAMPLES:]
    if data.shape[1] != MODEL_WINDOW_SAMPLES:
        raise ValueError(
            f"resampling produced {data.shape[1]} samples; expected {MODEL_WINDOW_SAMPLES}"
        )

    data -= data.mean(axis=-1, keepdims=True)
    scale = data.std(axis=-1, keepdims=True)
    scale[~np.isfinite(scale) | (scale < 1e-6)] = 1.0
    data /= scale
    return np.clip(data, -20.0, 20.0).astype(np.float32)


def band_powers(values, sample_rate: float) -> dict[str, float]:
    """Return log power for Delta, Theta, Alpha, Beta, and Gamma bands."""
    data = np.asarray(values, dtype=np.float64).reshape(-1)
    if data.size < int(sample_rate * 2):
        raise ValueError("at least two seconds of EEG are required for band power")
    data = data - np.mean(data)
    segment = min(data.size, int(sample_rate * 2))
    frequencies, density = welch(
        data,
        fs=sample_rate,
        nperseg=segment,
        noverlap=segment // 2,
        detrend="constant",
        scaling="density",
    )
    powers = {}
    for name, (low, high) in BANDS.items():
        mask = (frequencies >= low) & (frequencies < high)
        if np.count_nonzero(mask) < 2:
            powers[name] = -120.0
            continue
        power = float(np.trapezoid(density[mask], frequencies[mask]))
        powers[name] = 10.0 * math.log10(max(power, 1e-12))
    return powers


class EEGStressPredictor:
    """Load the bundled four-channel Signal-JEPA and return P(high stress)."""

    def __init__(self, model_path: str):
        self.model_path = model_path
        self.model = None
        self.torch = None
        self.metadata = {}
        self.load_error = None
        self._load()

    @property
    def available(self) -> bool:
        return self.model is not None

    def _load(self):
        config_path = os.path.join(self.model_path, "config.json")
        weights_path = os.path.join(self.model_path, "model.safetensors")
        if not os.path.isdir(self.model_path):
            self.load_error = f"model directory not found: {self.model_path}"
            return
        if not os.path.isfile(config_path) or not os.path.isfile(weights_path):
            self.load_error = f"Signal-JEPA config or Safetensors weights missing: {self.model_path}"
            return
        try:
            with open(config_path, encoding="utf-8") as handle:
                metadata = json.load(handle)
            expected = {
                "n_chans": len(EEG_CHANNELS),
                "n_times": MODEL_WINDOW_SAMPLES,
                "n_outputs": len(STRESS_CLASS_LABELS),
            }
            mismatches = {
                name: (metadata.get(name), value)
                for name, value in expected.items()
                if int(metadata.get(name, -1)) != value
            }
            sample_rate = float(metadata.get("sfreq", -1.0))
            if not math.isclose(sample_rate, MODEL_SAMPLE_RATE, abs_tol=1e-6):
                mismatches["sfreq"] = (metadata.get("sfreq"), MODEL_SAMPLE_RATE)
            if mismatches:
                details = ", ".join(
                    f"{name}={actual!r} (expected {wanted!r})"
                    for name, (actual, wanted) in mismatches.items()
                )
                raise ValueError(f"incompatible Signal-JEPA config: {details}")

            import torch
            from braindecode.models import SignalJEPA_PreLocal

            model = SignalJEPA_PreLocal.from_pretrained(self.model_path)
            model.eval()
            self.model = model
            self.torch = torch
            self.metadata = metadata
        except Exception as exc:  # keep graphs usable if optional ML deps are absent
            self.load_error = f"{type(exc).__name__}: {exc}"

    def stressed_probability(self, window: np.ndarray) -> float | None:
        """Classify one four-channel graph window and return P(high stress)."""
        if not self.available:
            return None
        values = np.asarray(window, dtype=np.float32)
        expected_shape = (len(EEG_CHANNELS), MODEL_WINDOW_SAMPLES)
        if values.shape != expected_shape:
            raise ValueError(f"Signal-JEPA input must have shape {expected_shape}, got {values.shape}")
        if not np.isfinite(values).all():
            raise ValueError("Signal-JEPA input contains non-finite samples")
        batch = self.torch.from_numpy(np.ascontiguousarray(values)[np.newaxis, ...])
        with self.torch.inference_mode():
            logits = self.model(batch)
            probability = self.torch.softmax(logits, dim=1)[0, STRESSED_CLASS_INDEX]
        return float(probability.cpu())


class LiveEEGAnalyzer:
    """Accumulate native Muse samples and classify each half-second graph update."""

    def __init__(self, predictor: EEGStressPredictor, callback, update_interval: float = 0.5):
        self.predictor = predictor
        self.callback = callback
        self.update_interval = update_interval
        self.buffers = {
            channel: deque(maxlen=MUSE_WINDOW_SAMPLES) for channel in EEG_CHANNELS
        }
        self.last_update = 0.0

    def reset(self):
        for values in self.buffers.values():
            values.clear()
        self.last_update = 0.0

    def add_samples(self, samples, sample_rate: float = MUSE_EEG_RATE, now: float | None = None):
        if not math.isclose(sample_rate, MUSE_EEG_RATE, rel_tol=0.0, abs_tol=0.5):
            raise ValueError(f"Muse EEG stream must be 256 Hz, received {sample_rate:g} Hz")
        array = np.asarray(samples, dtype=np.float64)
        if array.ndim == 1:
            array = array[np.newaxis, :]
        if array.ndim != 2 or array.shape[1] < len(EEG_CHANNELS):
            raise ValueError("Muse EEG samples must contain TP9, AF7, AF8 and TP10")
        for row in array:
            for index, channel in enumerate(EEG_CHANNELS):
                value = float(row[index])
                if math.isfinite(value):
                    self.buffers[channel].append(value)

        timestamp = time.time() if now is None else now
        if timestamp - self.last_update < self.update_interval:
            return False
        if any(len(values) < MUSE_WINDOW_SAMPLES for values in self.buffers.values()):
            return False

        native_channels = []
        bands = {}
        raw_values = {}
        for channel in EEG_CHANNELS:
            native = np.asarray(self.buffers[channel], dtype=np.float64)
            native_channels.append(native)
            raw_values[channel] = float(native[-1])
            bands[channel] = band_powers(native, MUSE_EEG_RATE)

        model_window = prepare_model_window(np.stack(native_channels), MUSE_EEG_RATE)
        stressed_probability = self.predictor.stressed_probability(model_window)
        # Signal-JEPA makes one joint four-channel classification. Each graph
        # displays that same current classification probability; their average
        # therefore contributes the joint P(high stress) to the score exactly once.
        probabilities = {channel: stressed_probability for channel in EEG_CHANNELS}
        self.last_update = timestamp
        self.callback(raw_values, bands, probabilities, timestamp)
        return True
