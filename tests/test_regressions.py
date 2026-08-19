"""Focused regression checks for adaptive-music backend decisions."""

import os
import tempfile
import time
import unittest
from unittest.mock import patch

import numpy as np


# Do not extract the 100 MB music archive merely to import the application.
_music_dir = tempfile.mkdtemp(prefix="adaptive-music-test-")
os.environ.setdefault("STRESS_MUSIC", _music_dir)

import claude_music  # noqa: E402
import server  # noqa: E402


def spotify_track(name="Quiet Song", artist="Calm Artist"):
    return {
        "id": "track-id",
        "uri": "spotify:track:track-id",
        "name": name,
        "artists": [{"name": artist}],
        "album": {"name": "Album", "images": []},
        "duration_ms": 180_000,
        "external_urls": {},
    }


class StressFolderTests(unittest.TestCase):
    def test_stress_labels_map_to_their_bpm_folders(self):
        self.assertEqual(server._bpm_folders_for_stress_label("Calm"), (120, 130, 140, 150))
        self.assertEqual(server._bpm_folders_for_stress_label("Mild-stress"), (90, 100, 110, 120))
        self.assertEqual(server._bpm_folders_for_stress_label("Stressed"), (60, 70, 80, 90))
        self.assertEqual(server._bpm_folders_for_stress_label(None), (90, 100, 110, 120))

    def test_ppg_reset_discards_a_peak_from_the_prior_session(self):
        detector = server.PPGDetector(beat_callback=lambda *_args, **_kwargs: None)
        detector.sample([10.0, 12.0, 11.0], 123.0)
        detector.last_peak = 123.0
        detector.selected_channel = 1
        detector.selected_polarity = 1
        detector.reset()
        self.assertEqual(detector.last_peak, 0.0)
        self.assertIsNone(detector.selected_channel)
        self.assertIsNone(detector.selected_polarity)
        self.assertEqual(len(detector.samples), 0)

    def test_ppg_detector_finds_bpm_and_rr_intervals_despite_optical_drift(self):
        intervals = []

        def capture(_timestamp, rr_ms=None, **_kwargs):
            intervals.append(rr_ms)

        detector = server.PPGDetector(beat_callback=capture)
        rate = 64
        seconds = 12
        axis = np.arange(rate * seconds) / rate
        rng = np.random.default_rng(2026)
        pulse = np.sin(2 * np.pi * 1.2 * axis) + 0.35 * np.sin(2 * np.pi * 2.4 * axis)
        drift = 12_000 * np.sin(2 * np.pi * 0.08 * axis) + 250 * axis
        samples = np.stack([
            500_000 + drift + rng.normal(0, 1_500, axis.size),
            2_000_000 + drift + 18_000 * pulse + rng.normal(0, 900, axis.size),
            1_400_000 + 0.7 * drift + 11_000 * pulse + rng.normal(0, 1_100, axis.size),
        ], axis=1)
        started = time.time()
        for index, sample in enumerate(samples):
            detector.sample(sample, started + index / rate)

        self.assertGreaterEqual(len(intervals), 7)
        detected_bpm = 60_000.0 / np.median(intervals)
        self.assertAlmostEqual(detected_bpm, 72.0, delta=3.0)
        self.assertIn(detector.selected_channel, (1, 2))
        self.assertGreater(detector.signal_quality, 3.0)

    def test_ppg_detector_rejects_drift_and_nonperiodic_noise(self):
        intervals = []
        detector = server.PPGDetector(
            beat_callback=lambda _timestamp, rr_ms=None, **_kwargs: intervals.append(rr_ms)
        )
        rate = 64
        axis = np.arange(rate * 12) / rate
        rng = np.random.default_rng(8)
        drift = 10_000 * np.sin(2 * np.pi * 0.1 * axis)
        samples = (
            np.stack([500_000 + drift, 2_000_000 + drift, 1_400_000 + drift], axis=1)
            + rng.normal(0, 250, (axis.size, 3))
        )
        started = time.time()
        for index, sample in enumerate(samples):
            detector.sample(sample, started + index / rate)

        self.assertEqual(intervals, [])
        self.assertEqual(detector.signal_quality, 0.0)


class PlaylistTests(unittest.TestCase):
    def test_playlist_selection_follows_pages_without_loading_any_tracks(self):
        next_page = "https://api.spotify.com/v1/me/playlists?offset=50&limit=50"
        calls = []

        def fake_sp_get(_session, path, params=None):
            calls.append((path, params))
            if path == "/me/playlists":
                return {"items": [{"id": "first", "name": "Earlier list", "tracks": {"total": 2}}],
                        "next": next_page}
            if path == next_page:
                return {"items": [{"id": "later", "name": "Focus Mix", "tracks": {"total": 3}}],
                        "next": None}
            self.fail(f"unexpected Spotify path: {path}")

        with patch.object(server, "_sp_get", side_effect=fake_sp_get):
            playlist = server._select_playlist(
                {"access": "token", "exp": float("inf")}, "Focus Mix", playlist_id="later")

        self.assertEqual(playlist["id"], "later")
        self.assertEqual(playlist["name"], "Focus Mix")
        self.assertEqual(playlist["count"], 3)
        self.assertIn((next_page, None), calls)
        self.assertFalse(any(path == "/playlists/later/tracks" for path, _ in calls))

    def test_sequential_playlist_request_fetches_only_the_requested_position(self):
        calls = []

        def fake_sp_get(_session, path, params=None):
            calls.append((path, params))
            self.assertEqual(path, "/playlists/focus/tracks")
            self.assertEqual(params, {"limit": 1, "offset": 2})
            return {"items": [{"track": spotify_track("Third Song")}]}

        playlist = {"id": "focus", "name": "Focus", "count": 5, "index": 2}
        with patch.object(server, "_sp_get", side_effect=fake_sp_get):
            track = server._playlist_track_at({"access": "token", "exp": float("inf")}, playlist, 2)

        self.assertEqual(track["name"], "Third Song")
        self.assertEqual(len(calls), 1)

    def test_playlist_catalog_exposes_button_ready_metadata_for_every_page(self):
        next_page = "https://api.spotify.com/v1/me/playlists?offset=50&limit=50"

        def fake_sp_get(_session, path, params=None):
            if path == "/me/playlists":
                return {"items": [{"id": "first", "name": "Morning", "tracks": {"total": 14}}],
                        "next": next_page}
            if path == next_page:
                return {"items": [{"id": "later", "name": "Evening", "tracks": {"total": 22}}],
                        "next": None}
            self.fail(f"unexpected Spotify path: {path}")

        with patch.object(server, "_sp_get", side_effect=fake_sp_get):
            catalog = server._playlist_catalog({"access": "token", "exp": float("inf")})

        self.assertEqual(catalog, [
            {"id": "first", "name": "Morning", "track_count": 14},
            {"id": "later", "name": "Evening", "track_count": 22},
        ])

    def test_claude_playlist_choice_is_limited_to_presented_tracks(self):
        tracks = [{"name": "Quiet Song", "artist": "Calm Artist"},
                  {"name": "Brighter Song", "artist": "Calm Artist"}]
        with patch.object(claude_music, "_complete", return_value='{"index": 1}'):
            self.assertEqual(claude_music.pick_playlist_track_index(tracks, "Stressed", api_key="test"), 1)
        with patch.object(claude_music, "_complete", return_value='{"index": 99}'):
            self.assertIsNone(claude_music.pick_playlist_track_index(tracks, "Stressed", api_key="test"))

    def test_claude_stress_choice_returns_only_an_actual_playlist_position(self):
        candidates = [
            {"position": 12, "track": {"name": "Quiet Song", "artist": "Calm Artist"}},
            {"position": 37, "track": {"name": "Brighter Song", "artist": "Calm Artist"}},
        ]
        with patch.object(claude_music, "_complete", return_value='{"index": 37}'):
            self.assertEqual(
                claude_music.pick_playlist_track_position(candidates, "Stressed", api_key="test"), 37)
        with patch.object(claude_music, "_complete", return_value='{"index": 20}'):
            self.assertIsNone(
                claude_music.pick_playlist_track_position(candidates, "Stressed", api_key="test"))


class PersonalizationGuardTests(unittest.TestCase):
    def test_artist_and_song_searches_reject_unrelated_spotify_results(self):
        track = {"name": "Billie Jean", "artist": "Michael Jackson"}
        self.assertTrue(server._matches_personalization("song", "Billie Jean", track))
        self.assertTrue(server._matches_personalization("artist", "Michael Jackson", track))
        self.assertFalse(server._matches_personalization("song", "Blue Monday", track))
        self.assertFalse(server._matches_personalization("artist", "Daft Punk", track))


class InstrumentalArtistTests(unittest.TestCase):
    def test_artist_matching_tolerates_accents_but_rejects_an_unrelated_artist(self):
        self.assertTrue(claude_music.artists_match("Beyoncé", "Beyonce feat. Jay-Z"))
        self.assertFalse(claude_music.artists_match("Beyoncé", "Piano Tribute Players"))

    def test_instrumental_search_filters_out_other_artists_before_claude_can_choose(self):
        wrong = {"id": "wrong", "name": "Song Instrumental", "artist": "Piano Tribute Players", "album": "Covers"}
        right = {"id": "right", "name": "Song Instrumental", "artist": "Beyonce", "album": "Singles"}
        with patch.object(claude_music, "search_query", return_value=[wrong, right]):
            result = claude_music.find_instrumental("Song", "Beyoncé")
        self.assertEqual(result["id"], "right")


if __name__ == "__main__":
    unittest.main()
