"""HTTP lifecycle regression tests; providers are mocked, so no paid API requests."""
import asyncio
import json
import os
import tempfile
import time
import unittest
from unittest.mock import patch

os.environ.setdefault("STRESS_MUSIC", tempfile.mkdtemp(prefix="adaptune-api-test-"))
import server
import claude_music
from fastapi.testclient import TestClient

class APISafetyTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(server.app, base_url="https://testserver")
        self.client.post("/api/anthropic_key", json={"key": "test-only-key"})
        self.session = server.SESSIONS[self.client.cookies.get("sid")]
    def tearDown(self):
        self.client.post("/api/session/clear")
        self.client.close()

    def test_analysis_requires_permission_before_provider_call(self):
        with patch.object(claude_music, "analyze_stress_session") as ai:
            response = self.client.post("/api/session-analysis", json={"stress_points":[{"x":0,"y":30}]})
        self.assertEqual(response.status_code, 403)
        ai.assert_not_called()

    def test_repeated_click_is_rate_limited_and_error_never_echoes_key(self):
        with patch.object(claude_music, "analyze_stress_session", side_effect=RuntimeError("test-only-key")) as ai:
            first = self.client.post("/api/session-analysis", json={"consent":True,"stress_points":[{"x":0,"y":30}]})
            second = self.client.post("/api/session-analysis", json={"consent":True,"stress_points":[{"x":0,"y":30}]})
        self.assertNotIn("test-only-key", first.text)
        self.assertEqual(second.status_code, 429)
        self.assertEqual(ai.call_count, 1)
        self.assertEqual(first.headers["cache-control"], "no-store")

    def test_automatic_requests_have_one_minute_cooldown(self):
        async def run():
            self.session["last_auto"] = time.time()
            result = await server._limited_work("test", self.session, lambda: self.fail("called provider"), automatic=True)
            self.assertEqual(result.status_code, 429)
        asyncio.run(run())

    def test_expired_key_is_cleared_even_without_client_removal(self):
        self.session["key_exp"] = time.time() - 1
        response = self.client.get("/api/spotify/status").json()
        self.assertFalse(response["key_set"])
        self.assertEqual(self.session["key"], "")

    def test_disconnect_clears_tokens_preferences_and_history(self):
        self.session.update(access="spotify-token", refresh="refresh-token", product="premium",
                            history={"PRIVATE"}, playlist={"name":"PRIVATE"}, typed_preference="PRIVATE")
        with patch.object(server._requests, "put"):
            self.assertTrue(self.client.post("/api/spotify/disconnect").json()["ok"])
        for field in ("access", "refresh", "product", "playlist", "typed_preference", "key"):
            self.assertFalse(self.session[field])
        self.assertEqual(self.session["history"], set())

    def test_stale_work_result_discarded_after_disconnect(self):
        async def run():
            def work():
                server._clear_session(self.session)
                return {"ok":True, "track":"stale"}
            result = await server._limited_work("test", self.session, work)
            self.assertFalse(json.loads(result.body)["ok"])
            self.assertNotIn("stale", result.body.decode())
        asyncio.run(run())

    def test_https_required_in_production_and_cookie_is_secure(self):
        with patch.object(server, "PRODUCTION", True):
            with TestClient(server.app, base_url="http://testserver") as plain:
                self.assertEqual(plain.get("/api/spotify/status").status_code, 400)
            response = self.client.get("/api/spotify/status")
            self.assertIn("Secure", response.headers["set-cookie"])
            self.assertIn("HttpOnly", response.headers["set-cookie"])

    def test_cross_origin_write_rejected(self):
        result = self.client.post("/api/anthropic_key", headers={"Origin":"https://evil.example"}, json={"key":"bad"})
        self.assertEqual(result.status_code, 403)
        self.assertEqual(self.session["key"], "test-only-key")

    def test_karaoke_needs_no_key_or_ai(self):
        self.client.delete("/api/anthropic_key")
        with patch.object(claude_music, "_complete") as ai:
            response = self.client.get("/api/karaoke")
        self.assertEqual(response.json()["song"]["audio"], "ransom.mp3")
        ai.assert_not_called()

    def test_oauth_never_echoes_untrusted_error(self):
        response = self.client.get("/callback", params={"error":"<script>test-secret</script>"})
        self.assertNotIn("test-secret", response.text)

if __name__ == "__main__":
    unittest.main()
