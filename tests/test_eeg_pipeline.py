"""Regression checks for Muse-native EEG processing and score integration."""

import os
import tempfile
import time
import unittest

import numpy as np


os.environ.setdefault("STRESS_MUSIC", tempfile.mkdtemp(prefix="adaptive-music-eeg-test-"))

from eeg_pipeline import (  # noqa: E402
    EEG_CHANNELS,
    MODEL_WINDOW_SAMPLES,
    LiveEEGAnalyzer,
    band_powers,
    prepare_model_window,
)
import server  # noqa: E402


class FakePredictor:
    def __init__(self):
        self.windows = []

    def stressed_probability(self, window):
        self.windows.append(window.copy())
        return 0.8


class EEGPipelineTests(unittest.TestCase):
    def test_ten_hertz_signal_is_alpha_dominant(self):
        rate = 256
        time_axis = np.arange(rate * 4) / rate
        powers = band_powers(np.sin(2 * np.pi * 10 * time_axis), rate)
        self.assertGreater(powers["alpha"], powers["theta"])
        self.assertGreater(powers["alpha"], powers["beta"])

    def test_live_analyzer_requires_native_muse_sample_rate(self):
        analyzer = LiveEEGAnalyzer(FakePredictor(), lambda *_: None)
        with self.assertRaisesRegex(ValueError, "256 Hz"):
            analyzer.add_samples(np.zeros((512, 4)), sample_rate=128)

    def test_live_analyzer_emits_all_bands_and_channel_probabilities(self):
        emitted = []
        predictor = FakePredictor()
        analyzer = LiveEEGAnalyzer(
            predictor, lambda *values: emitted.append(values), update_interval=0
        )
        time_axis = np.arange(1024) / 256
        samples = np.stack([
            np.sin(2 * np.pi * 3 * time_axis),
            np.sin(2 * np.pi * 6 * time_axis),
            np.sin(2 * np.pi * 10 * time_axis),
            np.sin(2 * np.pi * 35 * time_axis),
        ], axis=1)
        self.assertTrue(analyzer.add_samples(samples, sample_rate=256, now=100))
        _, bands, probabilities, _ = emitted[0]
        self.assertEqual(set(bands), set(EEG_CHANNELS))
        self.assertTrue(all(set(values) == {"delta", "theta", "alpha", "beta", "gamma"}
                            for values in bands.values()))
        self.assertEqual(len(predictor.windows), 1)
        self.assertEqual(predictor.windows[0].shape, (4, MODEL_WINDOW_SAMPLES))
        self.assertTrue(all(value == 0.8 for value in probabilities.values()))
        self.assertEqual(probabilities["right_ear"], 0.8)

    def test_joint_jepa_runs_again_on_every_graph_refresh(self):
        predictor = FakePredictor()
        analyzer = LiveEEGAnalyzer(predictor, lambda *_: None, update_interval=0.5)
        samples = np.random.default_rng(42).normal(size=(1024, 4))
        self.assertTrue(analyzer.add_samples(samples, sample_rate=256, now=100.0))
        self.assertFalse(analyzer.add_samples(samples[:64], sample_rate=256, now=100.25))
        self.assertTrue(analyzer.add_samples(samples[64:192], sample_rate=256, now=100.5))
        self.assertEqual(len(predictor.windows), 2)

    def test_model_window_matches_signal_jepa_contract(self):
        samples = np.random.default_rng(7).normal(size=(4, 1024))
        window = prepare_model_window(samples, source_rate=256)
        self.assertEqual(window.shape, (4, 256))
        self.assertEqual(window.dtype, np.float32)
        self.assertTrue(np.isfinite(window).all())
        self.assertTrue(np.all(np.abs(window) <= 20.0))

    def test_bundled_signal_jepa_checkpoint_is_loadable(self):
        predictor = server._EEG_PREDICTOR
        self.assertTrue(predictor.available, predictor.load_error)
        probability = predictor.stressed_probability(np.zeros((4, 256), dtype=np.float32))
        self.assertGreaterEqual(probability, 0.0)
        self.assertLessEqual(probability, 1.0)


class EEGScoreTests(unittest.TestCase):
    def test_score_uses_average_stressed_percent_plus_bpm_and_hrv_deltas(self):
        with server.HUB.lock:
            server.HUB.reset_session()
            now = 100.0
            server.HUB.baseline = {"bpm": 60.0, "hrv_diff": 20.0}
            server.HUB.bpm = 80.0
            server.HUB.hrv_diff = 12.0
            server.HUB.last_beat_ts = now
            server.HUB.eeg_stressed_probability = dict(zip(
                EEG_CHANNELS, (0.8, 0.7, 0.9, 0.6)
            ))
            server.HUB.eeg_ts = {channel: now for channel in EEG_CHANNELS}
            server._update_score_locked(now)
            # average EEG percentage 75 + BPM delta 20 + HRV delta -8
            self.assertAlmostEqual(server.HUB.stress_raw, 87.0)
            self.assertAlmostEqual(server.HUB.stress, 87.0)

    def test_score_uses_eeg_when_bpm_and_hrv_are_missing(self):
        with server.HUB.lock:
            server.HUB.reset_session()
            now = 100.0
            server.HUB.eeg_stressed_probability = {
                channel: 0.62 for channel in EEG_CHANNELS
            }
            server.HUB.eeg_ts = {channel: now for channel in EEG_CHANNELS}
            server._update_score_locked(now)
            self.assertAlmostEqual(server.HUB.stress_raw, 62.0)

    def test_score_uses_available_heart_metric_when_eeg_and_hrv_are_missing(self):
        with server.HUB.lock:
            server.HUB.reset_session()
            now = 100.0
            server.HUB.baseline = {"bpm": 60.0, "hrv_diff": 20.0}
            server.HUB.bpm = 82.0
            server.HUB.last_beat_ts = now
            server._update_score_locked(now)
            self.assertAlmostEqual(server.HUB.stress_raw, 22.0)

    def test_snapshot_shows_eeg_score_while_heart_baseline_is_calibrating(self):
        with server.HUB.lock:
            server.HUB.reset_session()
            now = time.time()
            server.HUB.stressed_start = False
            for channel in EEG_CHANNELS:
                server.HUB.eeg[channel] = 1.0
                server.HUB.eeg_ts[channel] = now
                server.HUB.eeg_stressed_probability[channel] = 0.54
                for band in server.BANDS:
                    server.HUB.eeg_bands[channel][band] = 1.0
            server._update_score_locked(now)
        state = server.snapshot()
        self.assertTrue(state["calibrating"])
        self.assertAlmostEqual(state["stress"], 54.0)


if __name__ == "__main__":
    unittest.main()
