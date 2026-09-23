"""Focused regression checks for adaptive-music backend decisions."""

import json
import math
import os
import tempfile
import unittest
from unittest.mock import patch


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


class SignalAndSongTests(unittest.TestCase):
    def test_song_bpm_is_inverse_user_bpm_with_requested_limits(self):
        self.assertEqual(server._song_bucket_for_bpm(35), 150)
        self.assertEqual(server._song_bucket_for_bpm(60), 150)
        self.assertEqual(server._song_bucket_for_bpm(70), 140)
        self.assertEqual(server._song_bucket_for_bpm(100), 110)
        self.assertEqual(server._song_bucket_for_bpm(140), 70)
        self.assertEqual(server._song_bucket_for_bpm(150), 60)
        self.assertEqual(server._song_bucket_for_bpm(200), 60)
        self.assertEqual(server._song_bucket_for_bpm(None), 60)

    def test_suno_response_uses_song_title_but_keeps_the_audio_filename(self):
        with tempfile.TemporaryDirectory(prefix="adaptune-suno-test-") as library:
            folder = os.path.join(library, "150")
            os.makedirs(folder)
            filename = "Moonlit Key Drift.mp3"
            with open(os.path.join(folder, filename), "wb") as handle:
                handle.write(b"test")
            with patch.object(server, "MUSIC_DIR", library), \
                 patch.object(server.random, "choice", return_value=filename):
                server.PLAYED.clear()
                response = server.api_suno_next(bucket=150)
        payload = json.loads(response.body)
        self.assertEqual(payload["name"], "Moonlit Key Drift")
        self.assertEqual(payload["file"], filename)
        self.assertIn("Moonlit%20Key%20Drift.mp3", payload["url"])

    def test_ppg_reset_discards_a_peak_from_the_prior_session(self):
        detector = server.PPGDetector()
        detector.dc = 12.0
        detector.last_peak = 123.0
        detector.above = True
        detector.reset()
        self.assertIsNone(detector.dc)
        self.assertEqual(detector.last_peak, 0.0)
        self.assertFalse(detector.above)

    def test_ppg_detector_recovers_from_contact_spike_and_detects_very_weak_pulses(self):
        intervals = []
        detector = server.PPGDetector()
        detector.dc = 2_000_000.0
        detector.env = 2_000.0
        started = 100.0

        def capture(_timestamp, rr_ms=None):
            intervals.append(rr_ms)

        with patch.object(server, "register_beat", side_effect=capture):
            for index in range(64 * 5):
                elapsed = index / 64.0
                weak_pulse = 8.0 * math.sin(2.0 * math.pi * 1.2 * elapsed)
                detector.sample(2_000_000.0 + weak_pulse, started + elapsed)

        self.assertGreaterEqual(len(intervals), 2)
        self.assertAlmostEqual(sum(intervals) / len(intervals), 833.3, delta=35.0)


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


    def test_playlist_metadata_never_enters_prompt_and_selection_is_local(self):
        session = server._new_session()
        session["typed_preference"] = "quiet piano"
        playlist = {"id": "private-id", "name": "PRIVATE_PLAYLIST", "count": 20, "index": 8}
        candidates = [
            {"position": 8, "track": {"name": "SECRET_SONG", "artist": "SECRET_ARTIST"}},
            {"position": 9, "track": {"name": "Yellow", "artist": "Coldplay"}},
        ]
        with patch.object(claude_music, "_complete", return_value='[{"title":"Yellow","artist":"Coldplay"}]') as ai, \
             patch.object(server, "_playlist_stress_sample", return_value=candidates):
            result = server._playlist_track_for_direction(session, playlist, "stress", api_key="fake")
        self.assertEqual(result["name"], "Yellow")
        self.assertEqual(playlist["index"], 9)
        prompt = ai.call_args.args[0]
        self.assertIn("quiet piano", prompt)
        for private in ("PRIVATE_PLAYLIST", "private-id", "SECRET_SONG", "SECRET_ARTIST"):
            self.assertNotIn(private, prompt)


class MatchingTests(unittest.TestCase):
    def test_search_ignores_first_wrong_result_and_versions(self):
        wrong = spotify_track("Yellow - Live", "Coldplay")
        tribute = spotify_track("Yellow", "Coldplay Tribute")
        right = spotify_track("YELLOW (2011 Remastered)", "Coldplay")
        with patch.object(claude_music, "_search", return_value={"tracks": {"items": [wrong, tribute, right]}}):
            self.assertEqual(claude_music.search_track("coldplay", "Yellow")["name"], right["name"])

    def test_explicit_version_is_required(self):
        self.assertFalse(claude_music.track_matches("Artist", "Song", spotify_track("Song - Remix", "Artist")))
        self.assertTrue(claude_music.track_matches("Artist", "Song (Live)", spotify_track("Song - Live", "Artist")))
        self.assertFalse(claude_music.artists_match("Queen", "Queen Tribute"))
        self.assertTrue(claude_music.artists_match("Beyoncé", "Beyonce feat. Jay-Z"))

    def test_history_not_sent_to_claude(self):
        with patch.object(claude_music, "_complete", return_value='[{"title":"Yellow","artist":"Coldplay"}]') as ai, \
             patch.object(claude_music, "search_track", return_value=None):
            claude_music.resolve_one("song", "my typed song", "Calm", {"SECRET_PLAYED"}, api_key="fake", stress_score=12)
        prompt = ai.call_args.args[0]
        self.assertIn("my typed song", prompt)
        self.assertIn("12", prompt)
        self.assertNotIn("SECRET_PLAYED", prompt)

    def test_bad_ai_json_is_rejected(self):
        for reply in ('{"title":"Song"}', '[{"title":1,"artist":"Artist"}]', 'not JSON'):
            with patch.object(claude_music, "_complete", return_value=reply), self.assertRaises(ValueError):
                claude_music.pick_songs("vibe", "gentle", "Calm", api_key="fake")


class SessionAnalysisTests(unittest.TestCase):
    def test_analysis_strips_identifiers_and_recomputes_average(self):
        with patch.object(claude_music, "_complete", return_value='{"analysis":"Stress eased steadily."}') as ai:
            result = claude_music.analyze_stress_session(
                [{"x": 0, "y": 58.2, "email": "PRIVATE"}, {"x": 15, "y": 41.8}], 999, api_key="test")
        self.assertEqual(result, "Stress eased steadily.")
        self.assertNotIn("PRIVATE", ai.call_args.args[0])
        self.assertIn("50.0", ai.call_args.args[0])

    def test_rejects_invalid_points_before_billing(self):
        with patch.object(claude_music, "_complete") as ai:
            for points in ([], [{"x": 0, "y": float("nan")}], [{"x": 1, "y": 101}]):
                with self.assertRaises(ValueError):
                    claude_music.analyze_stress_session(points, api_key="test")
            ai.assert_not_called()

    def test_karaoke_is_local_and_never_calls_claude(self):
        with patch.object(claude_music, "_complete") as ai:
            response = server.api_karaoke()
        self.assertEqual(response["song"]["id"], "ransom")
        self.assertEqual(response["song"]["author"], "Jade Key (ft. Mary Sweet)")
        self.assertIn("You were like a ransom note.", response["song"]["lyrics"])
        ai.assert_not_called()


if __name__ == "__main__":
    unittest.main()
