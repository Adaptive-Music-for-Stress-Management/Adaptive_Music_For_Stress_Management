#!/usr/bin/env python3
"""
Adaptive Music for Stress Management — computer edition.

Signal path
    Muse 2 headband ── MuseLSL (EEG 256 Hz + PPG 64 Hz) ──► this server
                                                           │  PPG peak detection -> BPM + HRV differential
                                                           │  EEG -> five bands + joint JEPA stress probability
        demo mode (no hardware) ────────────────────────┤
                                                        ▼
                                       baseline -> 0-100 stress meter
                                                        │
                                                        ▼
                                    dashboard (Graphs · Meter · Personalize · Relief)

Baseline
    "Are you stressed?"  YES -> population baseline: 60 BPM, 20 ms HRV differential
                         NO  -> average of the first 30 seconds of readings
    EEG is displayed and classified immediately; only BPM and HRV are baselined.

Music
    SUNO AI library:   BPM_folder/<60..150>/song_*.mp3 — bucket = clamp((bpm//10)*10 - 10, 60, 150),
                       random song per bucket, no repeats within a cycle (cycle = all songs in the folder).
    Spotify + Claude:  the user's Anthropic key drives vibe / artist / playlist / song personalization,
                       karaoke (instrumental + LRCLIB synced lyrics). Spotify Premium required (Web
                       Playback SDK).
"""

import os
import sys
import json
import time
import glob
import math
import random
import re
import zipfile
import threading
import webbrowser
import urllib.parse
from collections import deque

import numpy as np
from scipy.signal import butter, detrend, find_peaks, sosfiltfilt, welch

from eeg_pipeline import (
    BANDS,
    EEG_CHANNELS,
    EEGStressPredictor,
    LiveEEGAnalyzer,
    MUSE_EEG_RATE,
    MUSE_PPG_RATE,
)

# ============================ CONFIG ============================
ROOT       = os.path.dirname(os.path.abspath(__file__))
MUSIC_DIR  = os.environ.get("STRESS_MUSIC", os.path.join(ROOT, "BPM_folder"))
MUSIC_ZIP  = os.path.join(ROOT, "BPM_folder.zip")
STATIC_DIR = os.path.join(ROOT, "static")

PORT = int(os.environ.get("PORT", "8000"))
HOST = os.environ.get("HOST", "0.0.0.0" if os.environ.get("PORT") else "127.0.0.1")

MUSE_CONNECT_TIMEOUT = float(os.environ.get("MUSE_CONNECT_TIMEOUT", "30"))
EEG_MODEL_PATH = os.environ.get(
    "EEG_MODEL_PATH",
    os.path.join(ROOT, "models", "universe-signal-jepa-stress-detector"),
)

SPOTIFY_CLIENT_ID     = os.environ.get("SPOTIFY_CLIENT_ID", "")
SPOTIFY_CLIENT_SECRET = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
SPOTIFY_REDIRECT_URI  = os.environ.get("SPOTIFY_REDIRECT_URI", f"http://127.0.0.1:{PORT}/callback")
SPOTIFY_SCOPES = ("streaming user-read-email user-read-private user-modify-playback-state "
                  "user-read-playback-state playlist-read-private playlist-read-collaborative")

BASELINE_SEC   = 30.0        # calibration window when the user is NOT stressed at start
STRESSED_BASE  = {"bpm": 60.0, "hrv_diff": 20.0}   # population baseline when they ARE stressed
EMA_ALPHA      = 0.30        # smoothing on the stress meter
HRVD_EMA_ALPHA = 0.25        # smoothing on HRV differential used for scoring (graphs show raw)
EEG_STALE_SEC  = 3.0         # EEG lead shows blank after this long without data
BEAT_STALE_SEC = 6.0         # BPM/HRV show blank after this long without a beat
# ================================================================

# Extract the SUNO library on first run.
if not os.path.isdir(MUSIC_DIR) and os.path.isfile(MUSIC_ZIP):
    if zipfile.is_zipfile(MUSIC_ZIP):
        print("[music] extracting BPM_folder.zip ...")
        with zipfile.ZipFile(MUSIC_ZIP) as zf:
            zf.extractall(ROOT, members=[m for m in zf.namelist()
                                         if not m.startswith("__MACOSX/") and "/.DS_Store" not in m
                                         and not m.endswith(".DS_Store")])
        print(f"[music] extracted to {MUSIC_DIR}")
    else:
        print("[music] BPM_folder.zip is a Git LFS pointer — run `git lfs pull` first")


# ---------------------------------------------------------------------------
# Signal hub
# ---------------------------------------------------------------------------
class Hub:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset_session()
        self.input = None                  # "muse" | "demo" | None
        self.muse_last_ts = 0.0            # last time any MuseLSL EEG packet arrived
        self.muse_error = None

    def reset_session(self):
        now = time.time()
        self.bpm = None
        self.hrv_diff = None               # ms, per-beat successive RR difference
        self.hrv_diff_ema = None
        self.last_beat_ts = 0.0
        self.beat_seq = 0                  # increments once per detected heartbeat (drives UI glow)
        self.rr_prev = None                # previous RR interval (ms)
        self.eeg = {c: None for c in EEG_CHANNELS}
        self.eeg_bands = {c: {band: None for band in BANDS} for c in EEG_CHANNELS}
        self.eeg_stressed_probability = {c: None for c in EEG_CHANNELS}
        self.eeg_ts = {c: 0.0 for c in EEG_CHANNELS}
        self.ppg_last_ts = 0.0
        self.stressed_start = None         # True/False once the user answers
        self.baseline = None               # {"bpm":..., "hrv_diff":...} once frozen
        self.base_t0 = None
        self.base_bpm_sum = 0.0;  self.base_bpm_n = 0
        self.base_hrvd_sum = 0.0; self.base_hrvd_n = 0
        self.stress = None                 # smoothed 0-100
        self.stress_raw = None
        self.session_t0 = now

HUB = Hub()


def _stress_label(v):
    if v is None: return None
    if v < 33:  return "Calm"
    if v < 66:  return "Mild-stress"
    return "Stressed"


def _update_score_locked(now=None):
    """Update the score from whichever requested metrics are currently usable.

    Signal-JEPA's joint four-channel probability is copied into the four graph
    slots. Averaging available copies contributes it to the 0–100 meter exactly
    once. BPM and HRV deltas are included independently when their baseline and
    current value exist:
      P(high stress) * 100 + BPM delta + HRV delta
    """
    now = time.time() if now is None else float(now)
    components = []
    probabilities = [
        HUB.eeg_stressed_probability[channel]
        for channel in EEG_CHANNELS
        if HUB.eeg_stressed_probability[channel] is not None
        and now - HUB.eeg_ts[channel] < EEG_STALE_SEC
    ]
    if probabilities:
        components.append(100.0 * sum(probabilities) / len(probabilities))
    heart_fresh = now - HUB.last_beat_ts < BEAT_STALE_SEC
    if HUB.baseline is not None and heart_fresh:
        if HUB.bpm is not None:
            components.append(HUB.bpm - HUB.baseline["bpm"])
        if HUB.hrv_diff is not None:
            components.append(HUB.hrv_diff - HUB.baseline["hrv_diff"])
    if not components:
        HUB.stress_raw = None
        HUB.stress = None
        return
    raw = max(0.0, min(100.0, sum(components)))
    HUB.stress_raw = raw
    HUB.stress = raw if HUB.stress is None else (EMA_ALPHA * raw + (1 - EMA_ALPHA) * HUB.stress)


def register_beat(ts, rr_ms=None, bpm=None):
    """One heartbeat. Either rr_ms (preferred) or bpm must be given.
    Derives BPM + HRV differential, feeds the baseline window, updates the score."""
    with HUB.lock:
        if rr_ms is None and bpm:
            rr_ms = 60000.0 / max(bpm, 1e-6)
        if rr_ms is None or not (300.0 <= rr_ms <= 2000.0):    # 30-200 bpm sanity window
            return
        HUB.bpm = 60000.0 / rr_ms
        if HUB.rr_prev is not None:
            HUB.hrv_diff = abs(rr_ms - HUB.rr_prev)            # needs three beats: two RR intervals
            HUB.hrv_diff_ema = (HUB.hrv_diff if HUB.hrv_diff_ema is None
                                else HRVD_EMA_ALPHA * HUB.hrv_diff + (1 - HRVD_EMA_ALPHA) * HUB.hrv_diff_ema)
        HUB.rr_prev = rr_ms
        HUB.last_beat_ts = ts
        HUB.beat_seq += 1

        # --- baseline ---
        if HUB.baseline is None and HUB.stressed_start is not None:
            if HUB.stressed_start:
                HUB.baseline = dict(STRESSED_BASE)             # population norms, no calibration
            else:
                if HUB.base_t0 is None:
                    HUB.base_t0 = ts
                HUB.base_bpm_sum += HUB.bpm; HUB.base_bpm_n += 1
                if HUB.hrv_diff is not None:
                    HUB.base_hrvd_sum += HUB.hrv_diff; HUB.base_hrvd_n += 1
                if ts - HUB.base_t0 >= BASELINE_SEC and HUB.base_bpm_n > 0:
                    HUB.baseline = {
                        "bpm": HUB.base_bpm_sum / HUB.base_bpm_n,
                        "hrv_diff": (HUB.base_hrvd_sum / HUB.base_hrvd_n) if HUB.base_hrvd_n else 20.0,
                    }
                    print(f"[baseline] captured: bpm={HUB.baseline['bpm']:.1f} "
                          f"hrv_diff={HUB.baseline['hrv_diff']:.1f} ms")
        _update_score_locked(ts)


def push_eeg(tp9, af7, af8, tp10):
    now = time.time()
    with HUB.lock:
        for c, v in (("left_ear", tp9), ("left_brain", af7), ("right_brain", af8), ("right_ear", tp10)):
            if v is not None and math.isfinite(v):
                HUB.eeg[c] = float(v); HUB.eeg_ts[c] = now


def push_eeg_metrics(raw_values, bands, stressed_probabilities, timestamp=None):
    """Publish one analyzed four-channel EEG window and refresh the score."""
    now = time.time() if timestamp is None else timestamp
    with HUB.lock:
        for channel in EEG_CHANNELS:
            raw = raw_values.get(channel)
            if raw is not None and math.isfinite(raw):
                HUB.eeg[channel] = float(raw)
            for band in BANDS:
                value = bands.get(channel, {}).get(band)
                if value is not None and math.isfinite(value):
                    HUB.eeg_bands[channel][band] = float(value)
            probability = stressed_probabilities.get(channel)
            if probability is not None and math.isfinite(probability):
                HUB.eeg_stressed_probability[channel] = max(0.0, min(1.0, float(probability)))
            HUB.eeg_ts[channel] = now
        _update_score_locked(now)


_EEG_PREDICTOR = EEGStressPredictor(EEG_MODEL_PATH)
_EEG_ANALYZER = LiveEEGAnalyzer(_EEG_PREDICTOR, push_eeg_metrics)


# ---------------------------------------------------------------------------
# Muse 2 via MuseLSL. EEG is consumed at its native 256 Hz; the separate
# 64 Hz PPG stream is converted to heartbeat intervals server-side.
# ---------------------------------------------------------------------------
class PPGDetector:
    """Robust multi-wavelength Muse PPG detector -> beat timestamps.

    Muse sends ambient, infrared, and red optical samples at 64 Hz. Slow contact
    and motion drift can be much larger than the pulse, so each analysis removes
    the trend, band-passes 0.65--3.5 Hz, and selects the channel/polarity with the
    clearest physiologically spaced peaks.
    """

    CHANNEL_NAMES = ("ambient", "infrared", "red")
    MIN_SECONDS = 4.0
    BUFFER_SECONDS = 10.0
    ANALYSIS_INTERVAL = 0.25
    MIN_RR_SECONDS = 0.30
    MAX_RR_SECONDS = 2.0

    def __init__(self, beat_callback=None, sample_rate=MUSE_PPG_RATE):
        self._lock = threading.Lock()
        self._beat_callback = beat_callback or register_beat
        self.sample_rate = float(sample_rate)
        self._bandpass = butter(
            3, (0.65, 3.5), btype="bandpass", fs=self.sample_rate, output="sos"
        )
        self.reset()

    def reset(self):
        """Discard detector state when a new input or baseline session begins."""
        # This method may be called before the first packet as well as while the
        # LSL reader is live, so keep it safe to call independently of sample().
        with getattr(self, "_lock", threading.Lock()):
            self._reset_locked()

    def _reset_locked(self):
        length = max(1, int(round(self.sample_rate * self.BUFFER_SECONDS)))
        self.timestamps = deque(maxlen=length)
        self.samples = deque(maxlen=length)
        self.last_analysis = 0.0
        self.last_peak = 0.0
        self.selected_channel = None
        self.selected_polarity = None
        self.signal_quality = 0.0

    def sample(self, values, ts):
        """Add one Muse PPG sample (ambient, infrared, red)."""
        if not math.isfinite(ts):
            return
        array = np.asarray(values, dtype=np.float64).reshape(-1)
        row = np.full(3, np.nan, dtype=np.float64)
        if array.size == 1:
            row[1] = array[0]  # scalar callers are treated as infrared
        else:
            row[:min(3, array.size)] = array[:3]
        if not np.isfinite(row).any():
            return
        with self._lock:
            if self.timestamps and (
                ts <= self.timestamps[-1] or ts - self.timestamps[-1] > 0.5
            ):
                self._reset_locked()
            self.timestamps.append(float(ts))
            self.samples.append(row)
            if ts - self.last_analysis < self.ANALYSIS_INTERVAL:
                return
            self.last_analysis = float(ts)
            self._analyze_locked()

    def _candidate(self, signal, timestamps, channel_index, polarity):
        finite = np.isfinite(signal)
        if np.count_nonzero(finite) < 0.95 * signal.size:
            return None
        if not finite.all():
            positions = np.arange(signal.size)
            signal = np.interp(positions, positions[finite], signal[finite])
        if np.ptp(signal) < 1e-6:
            return None
        filtered = sosfiltfilt(self._bandpass, detrend(signal, type="linear"))
        robust_range = float(np.percentile(filtered, 95) - np.percentile(filtered, 5))
        if not math.isfinite(robust_range) or robust_range < 1e-6:
            return None
        centered = filtered - np.median(filtered)
        robust_sigma = 1.4826 * float(np.median(np.abs(centered)))
        prominence = max(0.12 * robust_range, 0.75 * robust_sigma, 1e-6)
        peaks, properties = find_peaks(
            polarity * filtered,
            distance=max(1, int(round(self.MIN_RR_SECONDS * self.sample_rate))),
            prominence=prominence,
        )
        if peaks.size < 2:
            return None
        stable = (
            (timestamps[peaks] >= timestamps[0] + 0.20)
            & (timestamps[peaks] <= timestamps[-1] - 0.15)
        )
        peaks = peaks[stable]
        prominences = properties["prominences"][stable]
        if peaks.size < 2:
            return None
        intervals = np.diff(timestamps[peaks])
        valid = (intervals >= self.MIN_RR_SECONDS) & (intervals <= self.MAX_RR_SECONDS)
        if not np.any(valid):
            return None
        valid_intervals = intervals[valid]
        median_interval = float(np.median(valid_intervals))
        interval_cv = float(np.std(valid_intervals) / max(median_interval, 1e-6))
        valid_ratio = float(np.mean(valid))
        prominence_ratio = float(np.median(prominences) / max(robust_sigma, 1e-6))

        # Reject narrow-band noise that happens to cross the peak threshold.
        # A genuine pulse repeats at the detected RR lag and concentrates power
        # around the corresponding heart frequency.
        lag = int(round(median_interval * self.sample_rate))
        correlations = []
        for candidate_lag in range(max(1, lag - 2), min(filtered.size - 1, lag + 2) + 1):
            left = centered[:-candidate_lag]
            right = centered[candidate_lag:]
            denominator = float(np.linalg.norm(left) * np.linalg.norm(right))
            if denominator > 1e-9:
                correlations.append(float(np.dot(left, right) / denominator))
        periodicity = max(correlations, default=0.0)
        frequencies, density = welch(
            filtered,
            fs=self.sample_rate,
            nperseg=min(256, filtered.size),
            nfft=1024,
        )
        heart_band = (frequencies >= 0.65) & (frequencies <= 3.5)
        target_frequency = 1.0 / max(median_interval, 1e-6)
        target_band = heart_band & (np.abs(frequencies - target_frequency) <= 0.18)
        band_power = float(np.sum(density[heart_band]))
        spectral_concentration = float(np.sum(density[target_band]) / max(band_power, 1e-12))
        if periodicity < 0.35 or spectral_concentration < 0.25:
            return None
        quality = (
            2.0 * valid_ratio
            + 2.0 * max(0.0, 1.0 - min(interval_cv, 1.0))
            + 0.35 * min(prominence_ratio, 4.0)
            + min(peaks.size / 6.0, 1.0)
            + periodicity
            + spectral_concentration
        )
        return {
            "channel": channel_index,
            "polarity": polarity,
            "quality": quality,
            "peak_times": timestamps[peaks],
        }

    def _analyze_locked(self):
        minimum = int(round(self.sample_rate * self.MIN_SECONDS))
        if len(self.timestamps) < minimum:
            return
        timestamps = np.asarray(self.timestamps, dtype=np.float64)
        samples = np.asarray(self.samples, dtype=np.float64)
        candidates = {}
        for channel_index in range(samples.shape[1]):
            for polarity in (1, -1):
                candidate = self._candidate(
                    samples[:, channel_index], timestamps, channel_index, polarity
                )
                if candidate is not None:
                    candidates[(channel_index, polarity)] = candidate
        if not candidates:
            self.signal_quality = 0.0
            return

        best = max(candidates.values(), key=lambda item: item["quality"])
        selected_key = None
        if self.selected_channel is not None and self.selected_polarity is not None:
            selected_key = (self.selected_channel, self.selected_polarity)
        current = candidates.get(selected_key)
        if current is None or (
            self.last_peak
            and timestamps[-1] - self.last_peak > 2.5
            and best["quality"] > current["quality"] + 0.5
        ):
            current = best
        self.selected_channel = current["channel"]
        self.selected_polarity = current["polarity"]
        self.signal_quality = float(current["quality"])

        for peak_time in current["peak_times"]:
            peak_time = float(peak_time)
            if not self.last_peak:
                self.last_peak = peak_time
                continue
            interval = peak_time - self.last_peak
            if interval < self.MIN_RR_SECONDS:
                continue  # the same peak shifted slightly after re-filtering
            if interval > self.MAX_RR_SECONDS:
                self.last_peak = peak_time  # reacquire without publishing a false RR
                continue
            self.last_peak = peak_time
            self._beat_callback(peak_time, rr_ms=interval * 1000.0)

_PPG = PPGDetector()

def _lsl_channel_labels(info):
    labels = []
    channel = info.desc().child("channels").child("channel")
    for _ in range(info.channel_count()):
        labels.append(channel.child_value("label"))
        channel = channel.next_sibling()
    return labels


class MuseLSLService:
    """Start MuseLSL when needed, then consume its synchronized EEG and PPG outlets."""

    def __init__(self):
        self._lock = threading.Lock()
        self._reader_thread = None
        self._producer_thread = None

    def start(self):
        with self._lock:
            if self._reader_thread is not None and self._reader_thread.is_alive():
                return True
            with HUB.lock:
                HUB.muse_error = None
            self._reader_thread = threading.Thread(target=self._run, daemon=True, name="muse-lsl-reader")
            self._reader_thread.start()
            return True

    def _set_error(self, message):
        print(f"[muse] {message}")
        with HUB.lock:
            HUB.muse_error = message

    def _start_producer(self):
        with self._lock:
            if self._producer_thread is not None and self._producer_thread.is_alive():
                return
            self._producer_thread = threading.Thread(
                target=self._produce,
                daemon=True,
                name="muse-lsl-producer",
            )
            self._producer_thread.start()

    def _produce(self):
        try:
            from muselsl import list_muses, stream

            devices = list_muses()
            if not devices:
                self._set_error("No Muse headband was found over Bluetooth.")
                return
            device = devices[0]
            print(f"[muse] connecting MuseLSL to {device.get('name') or device.get('address')} ...")
            stream(device["address"], ppg_enabled=True, retries=2)
        except Exception as exc:
            self._set_error(f"MuseLSL could not start: {exc}")

    @staticmethod
    def _resolve_stream(resolve_byprop, stream_type, timeout):
        streams = resolve_byprop("type", stream_type, timeout=timeout)
        return streams[0] if streams else None

    def _run(self):
        try:
            from pylsl import StreamInlet, proc_clocksync, proc_dejitter, resolve_byprop
        except ImportError:
            self._set_error("MuseLSL dependencies are missing. Run `pip install -r requirements.txt`.")
            return

        try:
            eeg_info = self._resolve_stream(resolve_byprop, "EEG", 1.0)
            if eeg_info is None:
                self._start_producer()
                eeg_info = self._resolve_stream(resolve_byprop, "EEG", MUSE_CONNECT_TIMEOUT)
            if eeg_info is None:
                self._set_error("No MuseLSL EEG stream appeared before the connection timeout.")
                return
            ppg_info = self._resolve_stream(resolve_byprop, "PPG", 10.0)
            if ppg_info is None:
                self._set_error("Muse 2 EEG connected, but its PPG stream is unavailable.")
                return

            eeg_rate = float(eeg_info.nominal_srate())
            ppg_rate = float(ppg_info.nominal_srate())
            if not math.isclose(eeg_rate, MUSE_EEG_RATE, abs_tol=0.5):
                self._set_error(f"Muse EEG reported {eeg_rate:g} Hz instead of 256 Hz.")
                return
            if not math.isclose(ppg_rate, MUSE_PPG_RATE, abs_tol=0.5):
                self._set_error(f"Muse PPG reported {ppg_rate:g} Hz instead of 64 Hz.")
                return

            labels = _lsl_channel_labels(eeg_info)
            required = ("TP9", "AF7", "AF8", "TP10")
            if all(label in labels for label in required):
                eeg_indices = [labels.index(label) for label in required]
            elif eeg_info.channel_count() >= 4:
                eeg_indices = [0, 1, 2, 3]
            else:
                self._set_error("Muse EEG stream does not contain all four required channels.")
                return
            ppg_labels = _lsl_channel_labels(ppg_info)
            ppg_required = ("PPG1", "PPG2", "PPG3")
            if all(label in ppg_labels for label in ppg_required):
                ppg_indices = [ppg_labels.index(label) for label in ppg_required]
            elif ppg_info.channel_count() >= 3:
                ppg_indices = [0, 1, 2]
            else:
                self._set_error("Muse PPG stream does not contain all three optical channels.")
                return

            flags = proc_clocksync | proc_dejitter
            eeg_inlet = StreamInlet(eeg_info, max_buflen=12, processing_flags=flags)
            ppg_inlet = StreamInlet(ppg_info, max_buflen=12, processing_flags=flags)
            _EEG_ANALYZER.reset()
            _PPG.reset()
            print("[muse] MuseLSL live: EEG 256 Hz (TP9/AF7/AF8/TP10), PPG 64 Hz")

            while HUB.input == "muse":
                eeg_samples, _ = eeg_inlet.pull_chunk(timeout=0.08, max_samples=128)
                if eeg_samples:
                    ordered = [[sample[index] for index in eeg_indices] for sample in eeg_samples]
                    now = time.time()
                    _EEG_ANALYZER.add_samples(ordered, sample_rate=eeg_rate, now=now)
                    with HUB.lock:
                        HUB.muse_last_ts = now
                        HUB.muse_error = None

                ppg_samples, ppg_timestamps = ppg_inlet.pull_chunk(timeout=0.02, max_samples=128)
                if ppg_samples:
                    wall_offset = time.time() - ppg_timestamps[-1]
                    last_wall_time = None
                    for sample, sample_time in zip(ppg_samples, ppg_timestamps):
                        if all(index < len(sample) for index in ppg_indices):
                            wall_time = float(sample_time) + wall_offset
                            _PPG.sample([sample[index] for index in ppg_indices], wall_time)
                            last_wall_time = wall_time
                    if last_wall_time is not None:
                        with HUB.lock:
                            HUB.ppg_last_ts = last_wall_time
        except Exception as exc:
            self._set_error(f"MuseLSL stream stopped: {exc}")


_MUSE_LSL = MuseLSLService()


# ---------------------------------------------------------------------------
# Demo mode — coherent synthetic biosignals so the whole dashboard works
# with no hardware. Beats happen in real time; EEG at ~10 Hz.
# ---------------------------------------------------------------------------
_demo_stop = threading.Event()
_demo_thread = None

def _demo_loop():
    rng = random.Random()
    arousal = 0.25
    next_eeg = 0.0
    phase = rng.random() * 1000.0
    while not _demo_stop.is_set():
        if HUB.input != "demo":
            time.sleep(0.3); continue
        arousal += (0.30 - arousal) * 0.02 + rng.gauss(0, 0.04)
        if rng.random() < 0.004:
            arousal += rng.uniform(0.20, 0.50)
        arousal = max(0.02, min(0.98, arousal))
        bpm = 62 + 50 * arousal + rng.gauss(0, 1.2)
        rr = 60000.0 / bpm
        # HRV shrinks with arousal: jitter successive beats less when stressed
        jitter = max(2.0, (34.0 - 26.0 * arousal)) * abs(rng.gauss(0, 1))
        register_beat(time.time(), rr_ms=rr + rng.choice((-1, 1)) * jitter * 0.5)

        # EEG between beats at ~10 Hz: alpha-dominant when calm and beta/gamma
        # dominant when aroused, with one synthetic joint stress probability.
        beat_gap = rr / 1000.0
        t_end = time.time() + beat_gap
        while not _demo_stop.is_set() and time.time() < t_end:
            now = time.time()
            if now >= next_eeg:
                next_eeg = now + 0.1
                def chan(seed):
                    a = (1.2 - arousal) * 40 * math.sin(2 * math.pi * 10 * (now + phase) + seed)
                    b = (0.3 + arousal) * 25 * math.sin(2 * math.pi * 22 * (now + phase) + seed * 2)
                    return a + b + rng.gauss(0, 8)
                values = dict(zip(EEG_CHANNELS, (chan(1.0), chan(2.0), chan(3.0), chan(4.0))))
                bands = {}
                for index, channel in enumerate(EEG_CHANNELS):
                    wobble = rng.gauss(0, 0.5) + index * 0.15
                    bands[channel] = {
                        "delta": 7.0 + 4.0 * arousal + wobble,
                        "theta": 9.0 + 2.0 * arousal + wobble,
                        "alpha": 18.0 - 10.0 * arousal + wobble,
                        "beta": 7.0 + 13.0 * arousal + wobble,
                        "gamma": 2.0 + 10.0 * arousal + wobble,
                    }
                probability = max(0.02, min(0.98, 0.05 + 0.90 * arousal))
                probabilities = {channel: probability for channel in EEG_CHANNELS}
                push_eeg_metrics(values, bands, probabilities, timestamp=now)
            time.sleep(0.02)

def start_demo():
    global _demo_thread
    if _demo_thread is None or not _demo_thread.is_alive():
        _demo_stop.clear()
        _demo_thread = threading.Thread(target=_demo_loop, daemon=True)
        _demo_thread.start()


# ---------------------------------------------------------------------------
# Web layer
# ---------------------------------------------------------------------------
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from starlette.concurrency import run_in_threadpool
import uvicorn, asyncio
import requests as _requests

import claude_music

app = FastAPI(title="Adaptive Music for Stress Management")
if os.path.isdir(MUSIC_DIR):
    app.mount("/music", StaticFiles(directory=MUSIC_DIR), name="music")
if os.path.isdir(STATIC_DIR):
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


# ---------------- session flow ----------------
@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    sid, _ = _session(request)
    resp = FileResponse(os.path.join(STATIC_DIR, "index.html"),
                        headers={"Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"})
    return _with_cookie(resp, sid)


@app.post("/api/input")
async def api_input(request: Request):
    """Select the computer input: Muse 2 through MuseLSL or demo mode."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    choice = (body.get("input") or "").strip().lower()
    if choice not in ("muse", "demo"):
        return JSONResponse({"ok": False, "error": "input must be 'muse' or 'demo'"}, status_code=400)

    with HUB.lock:
        HUB.input = choice
        HUB.reset_session()
    _PPG.reset()
    _EEG_ANALYZER.reset()

    if choice == "demo":
        start_demo()
        return JSONResponse({"ok": True, "input": "demo"})

    # Muse: start or attach to MuseLSL, then require an actual 256 Hz EEG packet.
    if not _MUSE_LSL.start():
        return JSONResponse({"ok": False, "error": "muse_connect_failed"})
    t0 = time.time()
    while time.time() - t0 < MUSE_CONNECT_TIMEOUT:
        if HUB.muse_last_ts > t0:
            return JSONResponse({"ok": True, "input": "muse"})
        if HUB.muse_error:
            return JSONResponse({"ok": False, "error": "muse_connect_failed",
                                 "detail": HUB.muse_error})
        await asyncio.sleep(0.25)
    return JSONResponse({"ok": False, "error": "muse_connect_failed",
                         "detail": HUB.muse_error or "MuseLSL connection timed out."})


@app.post("/api/baseline")
async def api_baseline(request: Request):
    """The final setup question: 'Are you stressed?' — sets how the baseline forms."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    stressed = bool(body.get("stressed"))
    with HUB.lock:
        keep = HUB.input
        HUB.reset_session()
        HUB.input = keep
        HUB.stressed_start = stressed
        if stressed:
            HUB.baseline = dict(STRESSED_BASE)
    _PPG.reset()
    _EEG_ANALYZER.reset()
    return JSONResponse({"ok": True, "stressed": stressed,
                         "baseline": HUB.baseline, "calibration_sec": 0 if stressed else BASELINE_SEC})


def snapshot():
    now = time.time()
    with HUB.lock:
        beats_fresh = (now - HUB.last_beat_ts) < BEAT_STALE_SEC and HUB.bpm is not None
        eeg_out, eeg_active, eeg_bands_out, eeg_stress_out = {}, {}, {}, {}
        for c in EEG_CHANNELS:
            fresh = (now - HUB.eeg_ts[c]) < EEG_STALE_SEC and HUB.eeg[c] is not None
            eeg_active[c] = fresh
            eeg_out[c] = round(HUB.eeg[c], 2) if fresh else None
            eeg_bands_out[c] = {
                band: round(HUB.eeg_bands[c][band], 3)
                if fresh and HUB.eeg_bands[c][band] is not None else None
                for band in BANDS
            }
            probability = HUB.eeg_stressed_probability[c]
            eeg_stress_out[c] = {
                "label": "Stressed",
                "probability": round(probability * 100.0, 1),
            } if fresh and probability is not None else None
        calibrating = (HUB.stressed_start is False and HUB.baseline is None)
        cal_left = None
        if calibrating and HUB.base_t0 is not None:
            cal_left = max(0.0, BASELINE_SEC - (now - HUB.base_t0))
        elif calibrating:
            cal_left = BASELINE_SEC
        eeg_score_fresh = any(
            eeg_active[channel] and HUB.eeg_stressed_probability[channel] is not None
            for channel in EEG_CHANNELS
        )
        heart_score_fresh = (
            beats_fresh
            and HUB.baseline is not None
            and (HUB.bpm is not None or HUB.hrv_diff is not None)
        )
        stress = round(HUB.stress, 1) if (
            HUB.stress is not None and (eeg_score_fresh or heart_score_fresh)
        ) else None
        stress_label = _stress_label(stress)
        return {
            "input": HUB.input,
            "bpm": round(HUB.bpm, 1) if beats_fresh else None,
            "hrv_diff": round(HUB.hrv_diff, 1) if (beats_fresh and HUB.hrv_diff is not None) else None,
            "beat_seq": HUB.beat_seq,
            "eeg": eeg_out,
            "eeg_bands": eeg_bands_out,
            "eeg_stress": eeg_stress_out,
            "eeg_active": eeg_active,
            "stress": stress,
            "stress_label": stress_label,
            "calibrating": calibrating,
            "calibration_left": None if cal_left is None else round(cal_left, 1),
            "baseline": HUB.baseline,
            "bpm_folders": _bpm_folders_for_stress_label(stress_label),
            "muse_streaming": (now - HUB.muse_last_ts) < 5.0,
            "ppg_streaming": (now - HUB.ppg_last_ts) < 2.0,
            "muse_error": HUB.muse_error,
            "eeg_model_ready": _EEG_PREDICTOR.available,
            "eeg_model_error": _EEG_PREDICTOR.load_error,
            "session_sec": int(now - HUB.session_t0),
        }


@app.websocket("/ws")
async def ws(sock: WebSocket):
    await sock.accept()
    try:
        while True:
            await sock.send_text(json.dumps(snapshot()))
            await asyncio.sleep(0.1)                    # 10 Hz
    except (WebSocketDisconnect, Exception):
        pass


# ---------------------------------------------------------------------------
# SUNO AI library — stress-driven BPM folders with a no-repeat cycle per folder.
# ---------------------------------------------------------------------------
PLAYED = {}                    # bucket -> set(filenames served this cycle)
PLAYED_LOCK = threading.Lock()

STRESS_BPM_FOLDERS = {
    "Calm": (120, 130, 140, 150),
    "Mild-stress": (90, 100, 110, 120),
    "Stressed": (60, 70, 80, 90),
}


def _bpm_folders_for_stress_label(label):
    """Playable folders for a stress label; unknown values use mild-stress."""
    return STRESS_BPM_FOLDERS.get(label, STRESS_BPM_FOLDERS["Mild-stress"])


def _bucket_for_stress_label(label):
    """Pick a folder in the label's therapeutic range, never from live BPM."""
    return random.choice(_bpm_folders_for_stress_label(label))

def _tracks_in(bucket):
    folder = os.path.join(MUSIC_DIR, str(bucket))
    out = []
    if os.path.isdir(folder):
        for ext in ("*.mp3", "*.wav", "*.ogg", "*.m4a", "*.flac"):
            out += [os.path.basename(p) for p in glob.glob(os.path.join(folder, ext))]
    return sorted(out)

@app.get("/api/suno/next")
def api_suno_next(bucket: int = None, stress_label: str = None, current: str = ""):
    """Next SUNO song for a stress-selected BPM folder.
    Never repeats a song until the whole folder (cycle of 3) has been played."""
    if bucket is None:
        if stress_label is None:
            with HUB.lock:
                stress_label = _stress_label(HUB.stress)
        bucket = _bucket_for_stress_label(stress_label)
    bucket = max(60, min(150, int(bucket // 10) * 10))
    files = _tracks_in(bucket)
    if not files:
        return JSONResponse({"url": None, "name": None, "bucket": bucket, "error": "no tracks"})
    with PLAYED_LOCK:
        played = PLAYED.setdefault(bucket, set()) & set(files)
        pool = [f for f in files if f not in played]
        if not pool:                                   # full cycle played -> start a new cycle
            played = set()
            pool = [f for f in files if f != current] or files[:]
        name = random.choice(pool)
        played.add(name)
        PLAYED[bucket] = played
    url = f"/music/{bucket}/{urllib.parse.quote(name)}"
    return JSONResponse({"url": url, "name": name, "bucket": bucket,
                         "remaining": len(files) - len(PLAYED[bucket])})


# ---------------------------------------------------------------------------
# Per-browser sessions (cookie 'sid') for Anthropic key + Spotify + preference.
# ---------------------------------------------------------------------------
import secrets as _secrets, base64 as _b64
SESSIONS, SESS_LOCK = {}, threading.Lock()

def _new_session():
    return {"key": "", "model": None,
            "mode": None, "value": "", "history": set(), "karaoke_tried": set(),
            "seed_artist": None,      # resolved artist for Song mode follow-up suggestions
            "playlist_id": None,      # stable selection from the playlist picker
            "playlist": None,         # {"id", "name", "count", "index"}; tracks stay in Spotify
            "access": None, "refresh": None, "exp": 0.0, "state": None,
            "product": None}

def _session(request):
    sid = request.cookies.get("sid")
    with SESS_LOCK:
        s = SESSIONS.get(sid)
        if not sid or s is None:
            sid = _secrets.token_urlsafe(24)
            s = _new_session(); SESSIONS[sid] = s
        return sid, s

def _with_cookie(resp, sid):
    resp.set_cookie("sid", sid, httponly=True, samesite="lax", max_age=7 * 24 * 3600, path="/")
    return resp

def _sp_basic():
    return _b64.b64encode(f"{SPOTIFY_CLIENT_ID}:{SPOTIFY_CLIENT_SECRET}".encode()).decode()

_sp_lock = threading.Lock()
def _sp_token(s):
    """Valid user access token for this session (refreshes when near expiry)."""
    with _sp_lock:
        if not s.get("access"):
            return None
        if time.time() < s["exp"] - 30:
            return s["access"]
        if s.get("refresh"):
            try:
                r = _requests.post("https://accounts.spotify.com/api/token",
                                   data={"grant_type": "refresh_token", "refresh_token": s["refresh"]},
                                   headers={"Authorization": f"Basic {_sp_basic()}"}, timeout=15)
                if r.ok:
                    j = r.json()
                    s["access"] = j["access_token"]
                    s["exp"] = time.time() + j.get("expires_in", 3600)
                    if j.get("refresh_token"):
                        s["refresh"] = j["refresh_token"]
            except Exception as e:
                print("[spotify] refresh failed:", e)
        return s["access"]

def _sp_get(s, path, params=None):
    tok = _sp_token(s)
    if not tok:
        return None
    # Spotify's pagination links are absolute. Accept only its API URLs so a
    # response cannot turn a server-side request into an arbitrary fetch.
    if path.startswith("https://api.spotify.com/v1/"):
        url = path
    elif path.startswith("/"):
        url = f"https://api.spotify.com/v1{path}"
    else:
        return None
    r = _requests.get(url,
                      headers={"Authorization": f"Bearer {tok}"}, params=params or {}, timeout=15)
    if not r.ok:
        return None
    return r.json()


@app.post("/api/anthropic_key")
async def api_anthropic_key(request: Request):
    sid, s = _session(request)
    try:
        body = await request.json()
    except Exception:
        body = {}
    s["key"] = (body.get("key") or "").strip()
    if body.get("model"):
        s["model"] = (body.get("model") or "").strip() or None
    return _with_cookie(JSONResponse({"ok": True, "key_set": bool(s["key"])}), sid)


@app.get("/api/spotify/status")
def sp_status(request: Request):
    sid, s = _session(request)
    return _with_cookie(JSONResponse({
        "configured": bool(SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET),
        "key_set": bool(s["key"]),
        "connected": bool(s["access"]),
        "premium": (s.get("product") == "premium"),
        "product": s.get("product"),
    }), sid)


@app.get("/api/spotify/token")
def sp_token_ep(request: Request):
    sid, s = _session(request)
    return _with_cookie(JSONResponse({"access_token": _sp_token(s)}), sid)


@app.get("/api/playlists")
def api_playlists(request: Request):
    """List every playlist available to the connected Spotify account."""
    sid, s = _session(request)
    if not s.get("access"):
        return _with_cookie(JSONResponse({"ok": False, "error": "not_connected"}, status_code=401), sid)
    if s.get("product") != "premium":
        return _with_cookie(JSONResponse({"ok": False, "error": "not_premium"}, status_code=403), sid)
    # A picker only needs stable IDs and names. In particular, do not imply that
    # the playlist's contents have been read just to show the picker.
    playlists = [{"id": p["id"], "name": p["name"]} for p in _playlist_catalog(s)]
    return _with_cookie(JSONResponse({"ok": True, "playlists": playlists}), sid)


@app.get("/login")
def sp_login(request: Request):
    sid, s = _session(request)
    if not (SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET):
        return HTMLResponse("<p>Server is missing SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET.</p>")
    st = _secrets.token_urlsafe(16); s["state"] = st
    q = urllib.parse.urlencode({"client_id": SPOTIFY_CLIENT_ID, "response_type": "code",
                                "redirect_uri": SPOTIFY_REDIRECT_URI, "scope": SPOTIFY_SCOPES,
                                "state": st})
    return _with_cookie(RedirectResponse("https://accounts.spotify.com/authorize?" + q), sid)


@app.get("/callback", response_class=HTMLResponse)
def sp_callback(request: Request, code: str = "", state: str = "", error: str = ""):
    sid, s = _session(request)
    if error:
        return HTMLResponse(f"<p>Spotify auth failed: {error}.</p>")
    if not code or state != s.get("state"):
        return HTMLResponse("<p>State mismatch or missing code — close this window and retry.</p>")
    try:
        r = _requests.post("https://accounts.spotify.com/api/token",
                           data={"grant_type": "authorization_code", "code": code,
                                 "redirect_uri": SPOTIFY_REDIRECT_URI},
                           headers={"Authorization": f"Basic {_sp_basic()}"}, timeout=15)
        if not r.ok:
            return HTMLResponse(f"<p>Token exchange failed ({r.status_code}): {r.text}</p>")
        j = r.json()
        with _sp_lock:
            s["access"] = j["access_token"]; s["refresh"] = j.get("refresh_token")
            s["exp"] = time.time() + j.get("expires_in", 3600)
        me = _sp_get(s, "/me")
        s["product"] = (me or {}).get("product")
    except Exception as e:
        return HTMLResponse(f"<p>Token exchange error: {e}</p>")
    return HTMLResponse("""<!doctype html><html><body style="background:#0b0f14;color:#dce6f0;font-family:sans-serif">
<p style="padding:20px">Spotify connected. You can close this window.</p>
<script>
  try{ if(window.opener){ window.opener.postMessage("spotify-connected", "*"); } }catch(e){}
  setTimeout(function(){ window.close(); }, 400);
  if(!window.opener){ location.href = "/"; }
</script></body></html>""")


# ---------------- personalization: vibe / artist / playlist / song ----------------
def _track_key(tr):
    return f"{tr.get('artist','')} — {tr.get('name','')}".lower()

def _current_label():
    with HUB.lock:
        return _stress_label(HUB.stress) or "Mild-stress"

def _playlist_catalog(s):
    """Return every playlist in the user's library, following Spotify pages."""
    playlists, seen = [], set()
    page = _sp_get(s, "/me/playlists", {"limit": 50}) or {}
    while page:
        for p in page.get("items", []) or []:
            playlist_id = p.get("id")
            if not playlist_id or playlist_id in seen:
                continue
            seen.add(playlist_id)
            playlists.append({
                "id": playlist_id,
                "name": (p.get("name") or "Untitled playlist").strip(),
                "track_count": (p.get("tracks") or {}).get("total", 0),
            })
        next_page = page.get("next")
        page = _sp_get(s, next_page) if next_page else None
    return playlists


def _select_playlist(s, name="", playlist_id=None):
    """Remember playlist metadata without fetching its track collection."""
    catalog = _playlist_catalog(s)
    target = next((p for p in catalog if playlist_id and p["id"] == playlist_id), None)
    if target is None:
        name_l = (name or "").strip().casefold()
        target = next((p for p in catalog if p["name"].casefold() == name_l), None)
        target = target or next((p for p in catalog if name_l and name_l in p["name"].casefold()), None)
    if target is None:
        return None
    return {"id": target["id"], "name": target.get("name"),
            "count": max(0, int(target.get("track_count") or 0)), "index": 0}


def _playlist_track_at(s, playlist, index):
    """Fetch precisely one playlist entry, by its zero-based Spotify offset."""
    count = int(playlist.get("count") or 0)
    if count <= 0:
        return None
    index %= count
    data = _sp_get(s, f"/playlists/{playlist['id']}/tracks", {"limit": 1, "offset": index}) or {}
    for item in data.get("items", []) or []:
        track = item.get("track") or {}
        if track.get("uri") and not track.get("is_local"):
            return claude_music._track_dict(track)
    return None


def _playlist_stress_sample(s, playlist, maximum=25):
    """Read one small window only when Claude needs to adapt a playlist to stress."""
    count = int(playlist.get("count") or 0)
    if count <= 0:
        return []
    limit = min(maximum, count)
    # Centre the small window on the last prompt position. This keeps the change
    # related to what the listener was hearing while never downloading the list.
    offset = max(0, min(int(playlist.get("index") or 0) - limit // 2, count - limit))
    data = _sp_get(s, f"/playlists/{playlist['id']}/tracks", {"limit": limit, "offset": offset}) or {}
    candidates = []
    for relative_index, item in enumerate(data.get("items", []) or []):
        track = item.get("track") or {}
        if track.get("uri") and not track.get("is_local"):
            candidates.append({"position": offset + relative_index,
                               "track": claude_music._track_dict(track)})
    return candidates


def _playlist_track_for_direction(s, playlist, direction, api_key=None, model=None):
    """Resolve a playlist track without ever materialising the entire playlist."""
    count = int(playlist.get("count") or 0)
    if count <= 0:
        return None
    if direction == "stress":
        candidates = _playlist_stress_sample(s, playlist)
        position = claude_music.pick_playlist_track_position(
            candidates, _current_label(), api_key=api_key, model=model)
        if position is None:
            return None
        playlist["index"] = position
        return next((candidate["track"] for candidate in candidates
                     if candidate["position"] == position), None)
    if direction == "next":
        playlist["index"] = (int(playlist.get("index") or 0) + 1) % count
    elif direction == "prev":
        playlist["index"] = (int(playlist.get("index") or 0) - 1) % count
    return _playlist_track_at(s, playlist, playlist["index"])


def _playlist_response(playlist):
    return {"id": playlist["id"], "name": playlist["name"],
            "index": playlist["index"], "count": playlist["count"]}


def _matches_personalization(mode, value, track, artist=None):
    """Ensure a Spotify search did not silently resolve an unrelated result."""
    if mode not in ("artist", "song"):
        return True
    wanted = (artist if mode == "artist" and artist else value).casefold().strip()
    haystack = (track.get("artist", "") if mode == "artist" else track.get("name", "")).casefold()
    if not wanted or not haystack:
        return False
    if wanted in haystack:
        return True
    words = [word for word in re.findall(r"[\w]+", wanted) if len(word) > 1]
    return any(re.search(rf"(?<!\w){re.escape(word)}(?!\w)", haystack) for word in words)


@app.post("/api/personalize")
async def api_personalize(request: Request):
    """Resolve the next track for the chosen mode.
       body: {mode: vibe|artist|playlist|song, value, playlist_id?, direction: init|next|prev}"""
    sid, s = _session(request)
    try:
        body = await request.json()
    except Exception:
        body = {}
    mode = (body.get("mode") or "").strip().lower()
    value = (body.get("value") if body.get("value") is not None else s.get("value") or "").strip()
    playlist_id = (body.get("playlist_id") or s.get("playlist_id") or "").strip()
    direction = (body.get("direction") or "init").strip().lower()
    if mode not in ("vibe", "artist", "playlist", "song"):
        return _with_cookie(JSONResponse({"ok": False, "error": "bad mode"}, status_code=400), sid)
    if not s["key"]:
        return _with_cookie(JSONResponse({"ok": False, "error": "no_key"}), sid)
    if not s["access"]:
        return _with_cookie(JSONResponse({"ok": False, "error": "not_connected"}), sid)
    if s.get("product") != "premium":
        return _with_cookie(JSONResponse({"ok": False, "error": "not_premium"}), sid)

    playlist_changed = mode == "playlist" and playlist_id != (s.get("playlist_id") or "")
    if mode != s.get("mode") or (value and value != s.get("value")) or playlist_changed:
        s["history"] = set(); s["karaoke_tried"] = set()
        s["playlist"] = None
        s["seed_artist"] = None
    s["mode"], s["value"] = mode, value or s.get("value", "")
    s["playlist_id"] = playlist_id if mode == "playlist" else None

    # all the network work (Spotify, Claude) is blocking I/O — run it in the
    # threadpool so the event loop keeps serving the 10 Hz /ws stream
    def _work():
        tok = _sp_token(s)
        try:
            if mode == "playlist":
                if s["playlist"] is None:
                    if not value:
                        return {"ok": False, "error": "no_value"}
                    pl = _select_playlist(s, value, s.get("playlist_id"))
                    if pl is None:
                        return {"ok": False, "error": "playlist_not_found"}
                    s["playlist"] = pl
                pl = s["playlist"]
                if not pl["count"]:
                    return {"ok": False, "error": "playlist_empty"}
                tr = _playlist_track_for_direction(
                    s, pl, direction, api_key=s["key"], model=s["model"])
                if not tr:
                    error = "playlist_selection_failed" if direction == "stress" else "playlist_track_unavailable"
                    return {"ok": False, "error": error}
                return {"ok": True, "track": tr, "mode": mode,
                        "playlist": _playlist_response(pl)}

            if mode == "song" and direction == "init":
                hits = claude_music.search_query(value, limit=10, user_token=tok)
                tr = next((hit for hit in hits if _matches_personalization("song", value, hit)), None)
                if not tr:
                    return {"ok": False, "error": "not_found"}
                s["seed_artist"] = tr["artist"]
            elif mode == "song":
                # After the exact requested song, every next/previous/stress
                # request remains with that resolved artist rather than asking
                # Claude to infer it again from a title.
                artist = s.get("seed_artist")
                if not artist:
                    hits = claude_music.search_query(value, limit=10, user_token=tok)
                    seed = next((hit for hit in hits if _matches_personalization("song", value, hit)), None)
                    if not seed:
                        return {"ok": False, "error": "not_found"}
                    artist = s["seed_artist"] = seed["artist"]
                tr = claude_music.resolve_one("artist", artist, _current_label(), s["history"],
                                              api_key=s["key"], model=s["model"], user_token=tok)
                if not tr or not _matches_personalization("artist", artist, tr, artist=artist):
                    return {"ok": False, "error": "not_found"}
            else:
                tr = claude_music.resolve_one(mode, value, _current_label(), s["history"],
                                              api_key=s["key"], model=s["model"], user_token=tok)
                if not tr:
                    return {"ok": False, "error": "not_found"}
                if not _matches_personalization(mode, value, tr):
                    return {"ok": False, "error": "not_found"}
            s["history"].add(_track_key(tr))
            return {"ok": True, "track": tr, "mode": mode}
        except Exception as e:
            print("[personalize] failed:", e)
            return {"ok": False, "error": str(e)}

    payload = await run_in_threadpool(_work)
    return _with_cookie(JSONResponse(payload), sid)


# ---------------- karaoke ----------------
@app.post("/api/karaoke")
async def api_karaoke(request: Request):
    """Fetch an instrumental + lyrics package.
       body: {current: {name, artist, duration_ms} | null, mode?, value?, playlist_id?, direction?}
       mode/value (when sent) update the session first — a category chosen WHILE
       karaoke is open must reach the server too."""
    sid, s = _session(request)
    try:
        body = await request.json()
    except Exception:
        body = {}
    b_mode = (body.get("mode") or "").strip().lower()
    b_value = (body.get("value") or "").strip()
    b_playlist_id = (body.get("playlist_id") or "").strip()
    direction = (body.get("direction") or "init").strip().lower()
    if b_mode in ("vibe", "artist", "playlist", "song"):
        playlist_changed = b_mode == "playlist" and b_playlist_id != (s.get("playlist_id") or "")
        if b_mode != s.get("mode") or (b_value and b_value != s.get("value")) or playlist_changed:
            s["history"] = set(); s["karaoke_tried"] = set(); s["playlist"] = None
            s["seed_artist"] = None
        s["mode"] = b_mode
        if b_value:
            s["value"] = b_value
        s["playlist_id"] = b_playlist_id if b_mode == "playlist" else None
    if not (s["key"] and s["access"]):
        return _with_cookie(JSONResponse({"ok": False, "error": "not_initialized"}), sid)
    if not s.get("mode"):
        return _with_cookie(JSONResponse({"ok": False, "error": "no_choice"}), sid)
    mode = s["mode"]

    def _work():
        tok = _sp_token(s)
        try:
            cur = body.get("current") or None
            if cur and cur.get("name"):
                pkg = claude_music.karaoke_package(cur["name"], cur.get("artist", ""),
                                                   cur.get("duration_ms"),
                                                   api_key=s["key"], model=s["model"], user_token=tok)
                if pkg:
                    s["karaoke_tried"].add(f"{cur.get('artist','')} — {cur['name']}".lower())
                    return {"ok": True, **pkg}
                if mode not in ("vibe", "artist"):
                    # the spec's message for a failing CURRENT song is the song one, in every mode
                    return {"ok": False, "error": "song"}
                # vibe/artist: the current song failed -> find another in-category

            if mode == "playlist":
                pl = s.get("playlist")
                if not pl:
                    pl = _select_playlist(s, s.get("value", ""), s.get("playlist_id"))
                    if pl is None:
                        return {"ok": False, "error": "playlist"}
                    s["playlist"] = pl
                if not pl["count"]:
                    return {"ok": False, "error": "playlist"}
                first_track = _playlist_track_for_direction(
                    s, pl, direction, api_key=s["key"], model=s["model"])
                if not first_track:
                    return {"ok": False, "error": "playlist"}
                # Karaoke may need to reject a track without lyrics or an
                # instrumental, but probes at most 25 one-item Spotify reads.
                order = [(pl["index"] + step) % pl["count"]
                         for step in range(min(25, pl["count"]))]
                attempted = False
                for index in order[:25]:
                    tr = first_track if index == pl["index"] else _playlist_track_at(s, pl, index)
                    if not tr:
                        continue
                    key = _track_key(tr)
                    if key in s["karaoke_tried"]:
                        continue
                    attempted = True
                    s["karaoke_tried"].add(key)
                    pkg = claude_music.karaoke_package(tr["name"], tr["artist"], tr.get("duration_ms"),
                                                       api_key=s["key"], model=s["model"], user_token=tok)
                    if pkg:
                        pl["index"] = index
                        pkg["original"] = tr
                        pkg["playlist"] = _playlist_response(pl)
                        return {"ok": True, **pkg}
                if not attempted:                     # whole window already tried -> let a retry start over
                    s["karaoke_tried"] = set()
                return {"ok": False, "error": "playlist"}

            if mode == "song":
                # first request plays the exact favorite song's karaoke; after that the loop
                # continues with other songs by that artist (like « / » in song mode)
                exact_key = (s.get("value") or "").strip().lower()
                if exact_key and ("exact:" + exact_key) not in s["karaoke_tried"]:
                    s["karaoke_tried"].add("exact:" + exact_key)
                    hits = claude_music.search_query(s["value"], limit=10, user_token=tok)
                    tr = next((hit for hit in hits if _matches_personalization("song", s["value"], hit)), None)
                    if tr:
                        pkg = claude_music.karaoke_package(tr["name"], tr["artist"], tr.get("duration_ms"),
                                                           api_key=s["key"], model=s["model"], user_token=tok)
                        if pkg:
                            pkg["original"] = tr
                            s["karaoke_tried"].add(_track_key(tr))
                            return {"ok": True, **pkg}
                    return {"ok": False, "error": "song"}

            # vibe / artist / song-loop: keep asking Claude until a song has both halves
            pkg = claude_music.pick_karaoke_song(mode, s["value"], _current_label(),
                                                 s["karaoke_tried"],
                                                 api_key=s["key"], model=s["model"], user_token=tok)
            if pkg:
                s["karaoke_tried"].add(_track_key(pkg["original"]))
                return {"ok": True, **pkg}
            return {"ok": False, "error": "song"}
        except Exception as e:
            print("[karaoke] failed:", e)
            return {"ok": False, "error": "playlist" if mode == "playlist" else "song"}

    payload = await run_in_threadpool(_work)
    return _with_cookie(JSONResponse(payload), sid)


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    url = f"http://127.0.0.1:{PORT}"
    print(f"[app] Adaptive Music dashboard at {url}")
    print("[muse] MuseLSL will scan Bluetooth for Muse 2 EEG (256 Hz) and PPG (64 Hz)")
    try:
        threading.Timer(1.2, lambda: webbrowser.open(url)).start()
    except Exception:
        pass
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
