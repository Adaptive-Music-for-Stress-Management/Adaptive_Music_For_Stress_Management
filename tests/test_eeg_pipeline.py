"""Regression checks for Muse-native EEG processing and score integration."""

import os
import tempfile
import unittest

import numpy as np


os.environ.setdefault("STRESS_MUSIC", tempfile.mkdtemp(prefix="adaptive-music-eeg-test-"))

from eeg_pipeline import EEG_CHANNELS, LiveEEGAnalyzer, band_powers  # noqa: E402
import server  # noqa: E402


class FakePredictor:
    def stressed_probabilities(self, windows):
        return [0.2, 0.4, 0.6, 0.8]


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
        analyzer = LiveEEGAnalyzer(FakePredictor(), lambda *values: emitted.append(values), update_interval=0)
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
        self.assertEqual(probabilities["right_ear"], 0.8)


class EEGScoreTests(unittest.TestCase):
    def test_score_uses_average_stressed_percent_plus_bpm_and_hrv_deltas(self):
        with server.HUB.lock:
            server.HUB.reset_session()
            server.HUB.baseline = {"bpm": 60.0, "hrv_diff": 20.0}
            server.HUB.bpm = 80.0
            server.HUB.hrv_diff = 12.0
            server.HUB.eeg_stressed_probability = dict(zip(
                EEG_CHANNELS, (0.8, 0.7, 0.9, 0.6)
            ))
            server._update_score_locked()
            # average EEG percentage 75 + BPM delta 20 + HRV delta -8
            self.assertAlmostEqual(server.HUB.stress_raw, 87.0)
            self.assertAlmostEqual(server.HUB.stress, 87.0)


if __name__ == "__main__":
    unittest.main()
