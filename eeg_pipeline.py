"""EEG preprocessing and live per-channel stress inference.

The Muse 2 emits TP9, AF7, AF8 and TP10 at 256 Hz.  Training recordings are
128 Hz EDF files, so inference keeps every native Muse sample in the live
buffer and resamples only the four-second model window to the training rate.
"""

from __future__ import annotations

from collections import OrderedDict, deque
from fractions import Fraction
import math
import os
import time

import numpy as np
from scipy.signal import butter, resample_poly, sosfiltfilt, welch


MUSE_EEG_RATE = 256.0
MUSE_PPG_RATE = 64.0
MODEL_SAMPLE_RATE = 128.0
WINDOW_SECONDS = 4.0
MODEL_WINDOW_SAMPLES = int(MODEL_SAMPLE_RATE * WINDOW_SECONDS)
MUSE_WINDOW_SAMPLES = int(MUSE_EEG_RATE * WINDOW_SECONDS)

EEG_CHANNELS = ("left_ear", "left_brain", "right_brain", "right_ear")
MUSE_CHANNEL_LABELS = ("TP9", "AF7", "AF8", "TP10")
CLASS_LABELS = ("Calm", "Mild-stress", "Stressed")
STRESSED_CLASS_INDEX = 2

BANDS = OrderedDict((
    ("delta", (1.0, 4.0)),
    ("theta", (4.0, 8.0)),
    ("alpha", (8.0, 13.0)),
    ("beta", (13.0, 30.0)),
    ("gamma", (30.0, 45.0)),
))
EEGMINER_FREQUENCIES = tuple((low + high) / 2.0 for low, high in BANDS.values())
EEGMINER_BANDWIDTHS = tuple(high - low for low, high in BANDS.values())


def build_braindecode_model(n_outputs: int = len(CLASS_LABELS)):
    """Create the five-band Braindecode EEGMiner used for training and inference."""
    from braindecode.models import EEGMiner

    count = len(BANDS)
    return EEGMiner(
        method="mag",
        n_chans=1,
        n_outputs=n_outputs,
        n_times=MODEL_WINDOW_SAMPLES,
        sfreq=MODEL_SAMPLE_RATE,
        filter_f_mean=EEGMINER_FREQUENCIES,
        filter_bandwidth=EEGMINER_BANDWIDTHS,
        filter_shape=(2.0,) * count,
        group_delay=(20.0,) * count,
        clamp_f_mean=(1.0, 45.0),
    )


def _resample(values: np.ndarray, source_rate: float, target_rate: float) -> np.ndarray:
    if math.isclose(source_rate, target_rate, rel_tol=0.0, abs_tol=1e-6):
        return values
    ratio = Fraction(target_rate / source_rate).limit_denominator(1000)
    return resample_poly(values, ratio.numerator, ratio.denominator)


def prepare_model_window(values, source_rate: float) -> np.ndarray:
    """Return one filtered, resampled and standardized 4-second window."""
    data = np.asarray(values, dtype=np.float64).reshape(-1)
    expected = int(round(source_rate * WINDOW_SECONDS))
    if data.size < expected:
        raise ValueError(f"need {expected} EEG samples, received {data.size}")
    data = data[-expected:]
    data = _resample(data, source_rate, MODEL_SAMPLE_RATE)
    if data.size != MODEL_WINDOW_SAMPLES:
        # Polyphase rounding can differ by one for unusual source rates.
        data = np.interp(
            np.linspace(0.0, 1.0, MODEL_WINDOW_SAMPLES, endpoint=False),
            np.linspace(0.0, 1.0, data.size, endpoint=False),
            data,
        )
    sos = butter(4, (1.0, 45.0), btype="bandpass", fs=MODEL_SAMPLE_RATE, output="sos")
    data = sosfiltfilt(sos, data)
    data -= np.mean(data)
    scale = float(np.std(data))
    if not math.isfinite(scale) or scale < 1e-6:
        scale = 1.0
    return (data / scale).astype(np.float32)


def band_powers(values, sample_rate: float) -> dict[str, float]:
    """Return log power for Delta, Theta, Alpha, Beta and Gamma bands."""
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
    """Load the trained Braindecode EEGMiner models and return P(stressed) per channel."""

    def __init__(self, model_path: str):
        self.model_path = model_path
        self.models = {}
        self.torch = None
        self.metadata = {}
        self.load_error = None
        self._load()

    @property
    def available(self) -> bool:
        return all(channel in self.models for channel in EEG_CHANNELS)

    def _load(self):
        if not os.path.isfile(self.model_path):
            self.load_error = f"model not found: {self.model_path}"
            return
        try:
            import torch
            try:
                payload = torch.load(self.model_path, map_location="cpu", weights_only=True)
            except TypeError:  # PyTorch before weights_only was introduced
                payload = torch.load(self.model_path, map_location="cpu")
            metadata = payload.get("metadata", {})
            state_dicts = payload.get("state_dicts")
            if state_dicts is None and "state_dict" in payload:
                # Backward-compatible loading for an early shared-model artifact.
                state_dicts = {channel: payload["state_dict"] for channel in EEG_CHANNELS}
            for channel in EEG_CHANNELS:
                model = build_braindecode_model(
                    n_outputs=int(metadata.get("n_outputs", len(CLASS_LABELS)))
                )
                model.load_state_dict(state_dicts[channel])
                model.eval()
                self.models[channel] = model
            self.torch = torch
            self.metadata = metadata
        except Exception as exc:  # keep graphs usable if optional ML deps are absent
            self.load_error = f"{type(exc).__name__}: {exc}"

    def stressed_probabilities(self, windows: list[np.ndarray]) -> list[float | None]:
        if not self.available:
            return [None] * len(windows)
        probabilities = []
        with self.torch.no_grad():
            for channel, window in zip(EEG_CHANNELS, windows):
                batch = self.torch.from_numpy(window[np.newaxis, np.newaxis, :])
                logits = self.models[channel](batch)
                probability = self.torch.softmax(logits, dim=1)[0, STRESSED_CLASS_INDEX]
                probabilities.append(float(probability.cpu()))
        return probabilities


class LiveEEGAnalyzer:
    """Accumulate all native Muse samples and emit metrics every half second."""

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

        windows = []
        bands = {}
        raw_values = {}
        for channel in EEG_CHANNELS:
            native = np.asarray(self.buffers[channel], dtype=np.float64)
            raw_values[channel] = float(native[-1])
            bands[channel] = band_powers(native, MUSE_EEG_RATE)
            windows.append(prepare_model_window(native, MUSE_EEG_RATE))
        probabilities = dict(zip(
            EEG_CHANNELS,
            self.predictor.stressed_probabilities(windows),
        ))
        self.last_update = timestamp
        self.callback(raw_values, bands, probabilities, timestamp)
        return True
