"""Focused regression checks for adaptive-music backend decisions."""

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


class BucketTests(unittest.TestCase):
    def test_live_bpm_uses_the_next_lower_ten_bpm_bucket(self):
        self.assertEqual(server._bucket_of(60), 60)
        self.assertEqual(server._bucket_of(70), 60)
        self.assertEqual(server._bucket_of(89.9), 70)
        self.assertEqual(server._bucket_of(150), 140)
        self.assertEqual(server._bucket_of(160), 150)

    def test_ppg_reset_discards_a_peak_from_the_prior_session(self):
        detector = server.PPGDetector()
        detector.dc = 12.0
        detector.last_peak = 123.0
        detector.above = True
        detector.reset()
        self.assertIsNone(detector.dc)
        self.assertEqual(detector.last_peak, 0.0)
        self.assertFalse(detector.above)


class PlaylistTests(unittest.TestCase):
    def test_playlist_lookup_follows_pages_before_reporting_not_found(self):
        next_page = "https://api.spotify.com/v1/me/playlists?offset=50&limit=50"
        calls = []

        def fake_sp_get(_session, path, params=None):
            calls.append((path, params))
            if path == "/me/playlists":
                return {"items": [{"id": "first", "name": "Earlier list"}], "next": next_page}
            if path == next_page:
                return {"items": [{"id": "later", "name": "Focus Mix"}], "next": None}
            if path == "/playlists/later/tracks":
                return {"items": [{"track": spotify_track()}], "next": None}
            self.fail(f"unexpected Spotify path: {path}")

        with patch.object(server, "_sp_get", side_effect=fake_sp_get):
            playlist = server._load_playlist(
                {"access": "token", "exp": float("inf")}, "Focus Mix", playlist_id="later")

        self.assertEqual(playlist["id"], "later")
        self.assertEqual(playlist["name"], "Focus Mix")
        self.assertEqual(len(playlist["tracks"]), 1)
        self.assertIn((next_page, None), calls)

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
