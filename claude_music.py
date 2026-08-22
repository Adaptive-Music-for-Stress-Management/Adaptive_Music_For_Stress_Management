#!/usr/bin/env python3
"""
claude_music.py — Claude-powered music personalization for the stress dashboard.

Claude (the user's own Anthropic API key) is the music brain:
    vibe     -> "output the name of a song for this vibe"
    artist   -> a song by that artist
    song     -> the exact song first; next/prev = other songs by the same artist
    playlist -> resolved directly from the user's Spotify library (no Claude needed)

Every Claude suggestion is resolved through the Spotify Search API into a real,
playable track (uri + duration + artists), because Spotify's own recommender
endpoints are deprecated for new apps.

Karaoke:
    For a given (or category-picked) song, find BOTH
      1) an instrumental / karaoke version on Spotify (Search + Claude filtering)
      2) the song's lyrics — time-synced when available — from LRCLIB
         (https://lrclib.net — free, keyless, returns LRC-style synced lyrics)
    If either half is missing the caller shows the spec'd apology message.
"""

import os
import re
import sys
import json
import time
import base64
import random
import threading
import unicodedata

import requests

# ----------------------------- config -----------------------------
SPOTIFY_CLIENT_ID     = os.environ.get("SPOTIFY_CLIENT_ID", "")
SPOTIFY_CLIENT_SECRET = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
ANTHROPIC_API_KEY     = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL       = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5")
SPOTIFY_MARKET        = os.environ.get("SPOTIFY_MARKET", "US")
LRCLIB_BASE           = os.environ.get("LRCLIB_BASE", "https://lrclib.net")

STRESS_GOAL = {
    "Calm":        "keep the listener settled and relaxed",
    "Mild-stress": "gently steady the listener and ease tension",
    "Stressed":    "actively calm the listener down and reduce acute stress",
}


# ------------------- Spotify auth (client credentials, search only) -------------------
_token = {"value": None, "exp": 0.0}
_token_lock = threading.Lock()

def _spotify_app_token():
    """Client-credentials token — enough for /v1/search (no user context)."""
    with _token_lock:
        if _token["value"] and time.time() < _token["exp"] - 30:
            return _token["value"]
        if not (SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET):
            raise RuntimeError("Set SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET")
        basic = base64.b64encode(f"{SPOTIFY_CLIENT_ID}:{SPOTIFY_CLIENT_SECRET}".encode()).decode()
        r = requests.post("https://accounts.spotify.com/api/token",
                          data={"grant_type": "client_credentials"},
                          headers={"Authorization": f"Basic {basic}"}, timeout=15)
        r.raise_for_status()
        j = r.json()
        _token["value"] = j["access_token"]
        _token["exp"] = time.time() + float(j.get("expires_in", 3600))
        return _token["value"]


def _search(params, user_token=None):
    """GET /v1/search with one automatic 401 retry. Uses the user's token when given
    (works even when server client credentials aren't configured)."""
    url = "https://api.spotify.com/v1/search"
    for attempt in (1, 2):
        tok = user_token or _spotify_app_token()
        r = requests.get(url, headers={"Authorization": f"Bearer {tok}"}, params=params, timeout=15)
        if r.status_code == 401 and attempt == 1 and not user_token:
            _token["value"] = None
            continue
        r.raise_for_status()
        return r.json()
    return {}


def _track_dict(t):
    imgs = t.get("album", {}).get("images", [])
    return {
        "id": t["id"],
        "uri": t["uri"],
        "name": t["name"],
        "artist": ", ".join(a["name"] for a in t.get("artists", [])),
        "album": t.get("album", {}).get("name", ""),
        "image": imgs[0]["url"] if imgs else None,
        "duration_ms": t.get("duration_ms"),
        "external_url": t.get("external_urls", {}).get("spotify"),
    }


def search_track(artist, title, market=None, user_token=None):
    """Resolve (artist, title) to a real Spotify track dict, or None."""
    market = market or SPOTIFY_MARKET
    try:
        for q in (f'track:"{title}" artist:"{artist}"', f"{title} {artist}"):
            items = (_search({"q": q, "type": "track", "limit": 5, "market": market},
                             user_token=user_token).get("tracks", {}) or {}).get("items", [])
            if items:
                return _track_dict(items[0])
    except Exception as e:
        print(f"[spotify] search failed for {artist!r} - {title!r}: {e}", file=sys.stderr)
    return None


def search_query(query, market=None, limit=5, user_token=None):
    """Free-text search; returns a list of track dicts (may be empty)."""
    market = market or SPOTIFY_MARKET
    try:
        items = (_search({"q": query, "type": "track", "limit": limit, "market": market},
                         user_token=user_token).get("tracks", {}) or {}).get("items", [])
        return [_track_dict(t) for t in items]
    except Exception as e:
        print(f"[spotify] query search failed for {query!r}: {e}", file=sys.stderr)
        return []


def artists_match(expected, candidate):
    """Return whether two Spotify artist credits refer to the same artist.

    Spotify sometimes removes accents or appends credits such as "feat.". The
    comparison tolerates those harmless presentation differences while rejecting
    unrelated karaoke/tribute artists.
    """
    def normalise(value):
        value = unicodedata.normalize("NFKD", value or "")
        value = "".join(ch for ch in value if not unicodedata.combining(ch))
        return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", value.casefold())).strip()

    wanted, actual = normalise(expected), normalise(candidate)
    if not wanted or not actual:
        return False
    return wanted == actual or f" {wanted} " in f" {actual} " or f" {actual} " in f" {wanted} "


# ------------------- Claude -------------------
_SYS = (
    "You are the music supervisor of a real-time stress-management app. The app measures the "
    "listener's stress from their heart rate and HRV and plays music to regulate it. You choose "
    "real, existing songs that are available on Spotify. Always answer with ONLY the JSON that "
    "was requested — no prose, no code fences."
)

def _complete(user_prompt, api_key=None, model=None, max_tokens=700, system=None):
    key = api_key or ANTHROPIC_API_KEY
    mdl = model or ANTHROPIC_MODEL
    if not key:
        raise RuntimeError("No Anthropic API key provided")
    try:
        import anthropic
        client = anthropic.Anthropic(api_key=key)
        msg = client.messages.create(model=mdl, max_tokens=max_tokens, system=system or _SYS,
                                     messages=[{"role": "user", "content": user_prompt}])
        return "".join(b.text for b in msg.content if getattr(b, "type", "") == "text")
    except ImportError:
        r = requests.post("https://api.anthropic.com/v1/messages",
                          headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                                   "content-type": "application/json"},
                          json={"model": mdl, "max_tokens": max_tokens, "system": system or _SYS,
                                "messages": [{"role": "user", "content": user_prompt}]},
                          timeout=30)
        r.raise_for_status()
        return "".join(b.get("text", "") for b in r.json().get("content", []) if b.get("type") == "text")


def _parse_json(text):
    """Pull the first JSON object/array out of a model reply (tolerates fences/prose)."""
    text = (text or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text).strip()
    for opener, closer in (("[", "]"), ("{", "}")):
        i, j = text.find(opener), text.rfind(closer)
        if i != -1 and j > i:
            try:
                return json.loads(text[i:j + 1])
            except Exception:
                continue
    return None


def analyze_stress_session(points, average, api_key=None, model=None):
    """Return a concise wellness-oriented interpretation of one saved session."""
    cleaned = []
    for point in (points or [])[:3600]:
        if not isinstance(point, dict):
            continue
        try:
            x, y = float(point.get("x")), float(point.get("y"))
        except (TypeError, ValueError):
            continue
        if math.isfinite(x) and math.isfinite(y):
            cleaned.append({"seconds": round(x, 1), "stress": round(max(0, min(100, y)), 1)})
    avg = max(0.0, min(100.0, float(average or 0.0)))
    system = (
        "You interpret wellness stress-session charts. Be concise, supportive, and evidence-based. "
        "Do not diagnose medical conditions. Return only the requested JSON."
    )
    prompt = (
        f"Analyze this Adaptune session. Average stress score: {avg:.1f}/100. "
        f"Time-series points: {json.dumps(cleaned)}. Identify the overall pattern, notable rises or "
        "recoveries, and one practical suggestion. Answer as JSON: {\"analysis\": \"...\"}"
    )
    data = _parse_json(_complete(prompt, api_key=api_key, model=model, max_tokens=500, system=system))
    if not isinstance(data, dict) or not str(data.get("analysis") or "").strip():
        raise RuntimeError("Claude did not return a session analysis")
    return str(data["analysis"]).strip()


# ------------------- song picking (vibe / artist / song modes) -------------------
def pick_songs(mode, value, stress_label, n=6, exclude=None, api_key=None, model=None):
    """Ask Claude for n candidate songs for the given personalization mode.
    Returns [{artist, title}, ...]. `exclude` lists 'Artist — Title' strings not to repeat."""
    goal = STRESS_GOAL.get(stress_label, STRESS_GOAL["Mild-stress"])
    avoid = ""
    if exclude:
        avoid = "\nDo NOT suggest any of these (already played): " + "; ".join(list(exclude)[-30:])
    if mode == "vibe":
        ask = (f'The listener described their vibe as: "{value}".\n'
               f"Their current stress level is {stress_label}; the therapeutic goal is to {goal}.\n"
               f"Output {n} real songs on Spotify matching that vibe AND the goal.")
    elif mode == "artist":
        ask = (f'The listener\'s favorite artist is: "{value}".\n'
               f"Their current stress level is {stress_label}; the therapeutic goal is to {goal}.\n"
               f'Output {n} real songs BY "{value}" ONLY (every "artist" field must be exactly "{value}") '
               f"that best serve the goal.")
    else:  # song: other songs by the same artist as the favorite song
        ask = (f'The listener\'s favorite song is: "{value}".\n'
               f"Their current stress level is {stress_label}; the therapeutic goal is to {goal}.\n"
               f"Identify that song's primary artist, then output {n} real songs by that same artist "
               f"(the favorite song itself may be included once) that fit the goal.")
    ask += avoid + '\nAnswer with ONLY a JSON array: [{"artist": "...", "title": "..."}]'
    data = _parse_json(_complete(ask, api_key=api_key, model=model))
    out = []
    for d in data if isinstance(data, list) else []:
        if isinstance(d, dict):
            a = str(d.get("artist") or "").strip()
            t = str(d.get("title") or d.get("song") or d.get("name") or "").strip()
            if a and t:
                out.append({"artist": a, "title": t})
    return out


def resolve_one(mode, value, stress_label, exclude_names, api_key=None, model=None, user_token=None):
    """Claude candidates -> Spotify-resolved track not in `exclude_names` ('artist — title' lowercased)."""
    cands = pick_songs(mode, value, stress_label, exclude=sorted(exclude_names),
                       api_key=api_key, model=model)
    random.shuffle(cands)
    fallback = None
    for c in cands:
        tr = search_track(c["artist"], c["title"], user_token=user_token)
        if not tr:
            continue
        key = f"{tr['artist']} — {tr['name']}".lower()
        if key in exclude_names:
            fallback = fallback or tr
            continue
        return tr
    return fallback           # everything already played -> allow a repeat rather than silence


def pick_playlist_track_position(candidates, stress_label, api_key=None, model=None):
    """Ask Claude to select only from Spotify playlist entries supplied by the server.

    Each candidate contains its actual zero-based Spotify playlist position and
    one already-fetched track. The caller deliberately supplies a small window;
    Claude therefore cannot invent a song or cause a whole playlist download.
    """
    if not candidates:
        return None
    choices = []
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        try:
            position = int(candidate.get("position"))
        except (TypeError, ValueError):
            continue
        track = candidate.get("track") or {}
        if track:
            choices.append((position, track))
    if not choices:
        return None
    listing = "\n".join(
        f'{position}: {track.get("artist", "Unknown artist")} — {track.get("name", "Untitled")}'
        for position, track in choices
    )
    goal = STRESS_GOAL.get(stress_label, STRESS_GOAL["Mild-stress"])
    ask = (
        f"The listener's stress level is {stress_label}. The therapeutic goal is to {goal}.\n"
        "Choose the one most suitable song from this exact Spotify playlist. "
        "You may choose ONLY one listed playlist position.\n"
        f"{listing}\n"
        'Answer ONLY JSON: {"index": <listed playlist position>}'
    )
    try:
        data = _parse_json(_complete(ask, api_key=api_key, model=model, max_tokens=60))
        index = int(data.get("index")) if isinstance(data, dict) else -1
        return index if any(index == listed for listed, _ in choices) else None
    except Exception as e:
        print(f"[playlist] Claude ranking failed: {e}", file=sys.stderr)
        return None


def pick_playlist_track_index(tracks, stress_label, api_key=None, model=None):
    """Compatibility wrapper for callers that hold a simple, local track list."""
    return pick_playlist_track_position(
        [{"position": index, "track": track} for index, track in enumerate(tracks or [])],
        stress_label, api_key=api_key, model=model)


# ------------------- karaoke: instrumental + lyrics -------------------
_INSTRUMENTAL_RE = re.compile(r"\b(instrumental|karaoke|backing\s*track)\b", re.I)

def find_instrumental(track_name, artist, api_key=None, model=None, user_token=None):
    """Find an instrumental/karaoke version of a song on Spotify, or None.
    Search first; if several candidates, let Claude pick the most faithful one."""
    candidates = []
    for q in (f'track:"{track_name}" instrumental',
              f"{track_name} {artist} instrumental",
              f"{track_name} {artist} karaoke"):
        for tr in search_query(q, limit=5, user_token=user_token):
            if _INSTRUMENTAL_RE.search(tr["name"] or "") or _INSTRUMENTAL_RE.search(tr.get("album") or ""):
                candidates.append(tr)
    # de-dup by id, keep order
    seen, uniq = set(), []
    for tr in candidates:
        if tr["id"] not in seen and artists_match(artist, tr.get("artist", "")):
            uniq.append(tr); seen.add(tr["id"])
    if not uniq:
        return None
    if len(uniq) == 1 or not (api_key or ANTHROPIC_API_KEY):
        return uniq[0]
    try:
        listing = "\n".join(f'{i}: {t["artist"]} — {t["name"]} (album: {t["album"]})'
                            for i, t in enumerate(uniq[:8]))
        ask = (f'Which of these Spotify tracks is the best INSTRUMENTAL version of '
               f'"{track_name}" by {artist} (same melody, no vocals)?\n{listing}\n'
               'Answer ONLY JSON: {"index": <number>} — use {"index": -1} if none match.')
        d = _parse_json(_complete(ask, api_key=api_key, model=model, max_tokens=60))
        idx = int(d.get("index", 0)) if isinstance(d, dict) else 0
        if idx == -1:
            return None
        return uniq[idx] if 0 <= idx < len(uniq) else uniq[0]
    except Exception:
        return uniq[0]


def _parse_lrc(synced):
    """LRC text -> [[ms, line], ...] sorted by time."""
    out = []
    for raw in (synced or "").splitlines():
        for m in re.finditer(r"\[(\d+):(\d+(?:\.\d+)?)\]", raw):
            ms = int((int(m.group(1)) * 60 + float(m.group(2))) * 1000)
            text = re.sub(r"\[\d+:\d+(?:\.\d+)?\]", "", raw).strip()
            out.append([ms, text])
    out.sort(key=lambda x: x[0])
    return out


def fetch_lyrics(track_name, artist, duration_ms=None):
    """LRCLIB lookup. Returns {"synced": [[ms, line],...] or None, "plain": str or None}, or None."""
    try:
        params = {"track_name": track_name, "artist_name": artist}
        if duration_ms:
            params["duration"] = int(round(duration_ms / 1000.0))
        r = requests.get(f"{LRCLIB_BASE}/api/get", params=params, timeout=12)
        j = r.json() if r.ok else None
        if not j:                                       # fall back to fuzzy search
            r = requests.get(f"{LRCLIB_BASE}/api/search",
                             params={"track_name": track_name, "artist_name": artist}, timeout=12)
            hits = r.json() if r.ok else []
            j = hits[0] if isinstance(hits, list) and hits else None
        if not j or j.get("instrumental"):
            return None
        synced = _parse_lrc(j.get("syncedLyrics"))
        plain = (j.get("plainLyrics") or "").strip() or None
        if not synced and not plain:
            return None
        return {"synced": synced or None, "plain": plain}
    except Exception as e:
        print(f"[lyrics] lrclib failed for {artist!r} - {track_name!r}: {e}", file=sys.stderr)
        return None


def karaoke_package(track_name, artist, duration_ms=None, api_key=None, model=None, user_token=None):
    """Both halves of karaoke for one song: instrumental track + lyrics. None if either is missing."""
    lyrics = fetch_lyrics(track_name, artist, duration_ms)
    if not lyrics:
        return None
    inst = find_instrumental(track_name, artist, api_key=api_key, model=model, user_token=user_token)
    if not inst:
        return None
    return {"instrumental": inst, "lyrics": lyrics,
            "source": {"name": track_name, "artist": artist}}


def pick_karaoke_song(mode, value, stress_label, exclude_names, api_key=None, model=None, user_token=None):
    """For vibe/artist karaoke: keep asking Claude for songs until one has BOTH
    an instrumental version and lyrics. Returns a karaoke package or None."""
    tried = set(exclude_names)
    for _ in range(3):                                   # up to 3 Claude rounds
        cands = pick_songs(mode, value, stress_label, n=6, exclude=sorted(tried),
                           api_key=api_key, model=model)
        if not cands:
            break
        for c in cands:
            key = f"{c['artist']} — {c['title']}".lower()
            if key in tried:
                continue
            tried.add(key)
            tr = search_track(c["artist"], c["title"], user_token=user_token)
            if not tr:
                continue
            if mode == "artist" and not artists_match(value, tr.get("artist", "")):
                continue
            pkg = karaoke_package(tr["name"], tr["artist"], tr.get("duration_ms"),
                                  api_key=api_key, model=model, user_token=user_token)
            if pkg:
                pkg["original"] = tr
                return pkg
    return None
