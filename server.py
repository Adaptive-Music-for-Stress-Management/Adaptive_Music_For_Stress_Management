#!/usr/bin/env python3
"""
Adaptive Music for Stress Management — computer edition.

Signal path
    Muse 2 headband ── Petal Metrics (OSC over UDP) ──► this server
                                                        │  PPG peak detection -> BPM + HRV differential
                                                        │  EEG -> left/right brain + left/right ear traces
        demo mode (no hardware) ────────────────────────┤
                                                        ▼
                                       baseline -> 0-100 stress meter
                                                        │
                                                        ▼
                                    dashboard (Graphs · Meter · Personalize · Relief)

Baseline
    "Are you stressed?"  YES -> population baseline: 60 BPM, 20 ms HRV differential
                         NO  -> average of the first 30 seconds of readings
    EEG is displayed instantly (it is not part of the stress score for now).

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

# ============================ CONFIG ============================
ROOT       = os.path.dirname(os.path.abspath(__file__))
MUSIC_DIR  = os.environ.get("STRESS_MUSIC", os.path.join(ROOT, "BPM_folder"))
MUSIC_ZIP  = os.path.join(ROOT, "BPM_folder.zip")
STATIC_DIR = os.path.join(ROOT, "static")

PORT = int(os.environ.get("PORT", "8000"))
HOST = os.environ.get("HOST", "0.0.0.0" if os.environ.get("PORT") else "127.0.0.1")

# Petal Metrics streams OSC to localhost; set the SAME port in the Petal Metrics app.
MUSE_OSC_HOST = os.environ.get("MUSE_OSC_HOST", "0.0.0.0")
MUSE_OSC_PORT = int(os.environ.get("MUSE_OSC_PORT", "14739"))
MUSE_CONNECT_TIMEOUT = float(os.environ.get("MUSE_CONNECT_TIMEOUT", "12"))   # s to wait for first packet

SPOTIFY_CLIENT_ID     = os.environ.get("SPOTIFY_CLIENT_ID", "")
SPOTIFY_CLIENT_SECRET = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
SPOTIFY_REDIRECT_URI  = os.environ.get("SPOTIFY_REDIRECT_URI", f"http://127.0.0.1:{PORT}/callback")
SPOTIFY_SCOPES = ("streaming user-read-email user-read-private user-modify-playback-state "
                  "user-read-playback-state playlist-read-private playlist-read-collaborative")

BASELINE_SEC   = 30.0        # calibration window when the user is NOT stressed at start
STRESSED_BASE  = {"bpm": 60.0, "hrv_diff": 20.0}   # population baseline when they ARE stressed
BPM_SCALE      = 40.0        # +40 bpm over baseline = full-scale stress contribution
HRVD_SCALE     = 15.0        # -15 ms of HRV differential below baseline = full-scale contribution
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
EEG_CHANNELS = ["left_ear", "left_brain", "right_brain", "right_ear"]   # TP9, AF7, AF8, TP10

class Hub:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset_session()
        self.input = None                  # "muse" | "demo" | None
        self.osc_last_ts = 0.0             # last time ANY Muse OSC packet arrived
        self.osc_started = False

    def reset_session(self):
        now = time.time()
        self.bpm = None
        self.hrv_diff = None               # ms, per-beat successive RR difference
        self.hrv_diff_ema = None
        self.last_beat_ts = 0.0
        self.beat_seq = 0                  # increments once per detected heartbeat (drives UI glow)
        self.rr_prev = None                # previous RR interval (ms)
        self.eeg = {c: None for c in EEG_CHANNELS}
        self.eeg_ts = {c: 0.0 for c in EEG_CHANNELS}
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


def _update_score_locked():
    """Recompute the 0-100 meter from the current beat-derived readings. Call with lock held."""
    if HUB.baseline is None or HUB.bpm is None:
        return
    terms = [max(0.0, min(1.0, (HUB.bpm - HUB.baseline["bpm"]) / BPM_SCALE))]
    if HUB.hrv_diff_ema is not None:
        terms.append(max(0.0, min(1.0, (HUB.baseline["hrv_diff"] - HUB.hrv_diff_ema) / HRVD_SCALE)))
    raw = 100.0 * sum(terms) / len(terms)
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
        _update_score_locked()


def push_eeg(tp9, af7, af8, tp10):
    now = time.time()
    with HUB.lock:
        for c, v in (("left_ear", tp9), ("left_brain", af7), ("right_brain", af8), ("right_ear", tp10)):
            if v is not None and math.isfinite(v):
                HUB.eeg[c] = float(v); HUB.eeg_ts[c] = now


# ---------------------------------------------------------------------------
# Muse 2 via Petal Metrics (OSC).  Robust to address-prefix differences:
# accepts /PetalStream/eeg, /muse/eeg, etc.  PPG -> heartbeats server-side.
# ---------------------------------------------------------------------------
class PPGDetector:
    """Adaptive-threshold peak detector over the PPG stream -> beat timestamps.
    ThreadingOSCUDPServer handles packets on worker threads, so sample() locks."""
    def __init__(self):
        self._lock = threading.Lock()
        self.reset()

    def reset(self):
        """Discard detector state when a new input or baseline session begins."""
        # This method may be called before the first packet as well as while the
        # OSC server is live, so keep it safe to call independently of sample().
        with getattr(self, "_lock", threading.Lock()):
            self._reset_locked()

    def _reset_locked(self):
        self.dc = None            # slow DC baseline
        self.env = 1.0            # amplitude envelope
        self.prev = 0.0
        self.above = False
        self.last_peak = 0.0

    def sample(self, v, ts):
        if not math.isfinite(v):
            return
        with self._lock:
            self._sample_locked(v, ts)

    def _sample_locked(self, v, ts):
        self.dc = v if self.dc is None else 0.995 * self.dc + 0.005 * v
        x = v - self.dc
        self.env = max(abs(x), self.env * 0.999, 1e-6)
        thresh = 0.45 * self.env
        if not self.above and x > thresh and self.prev <= thresh:
            self.above = True
            if self.last_peak and 0.30 <= (ts - self.last_peak) <= 2.0:
                register_beat(ts, rr_ms=(ts - self.last_peak) * 1000.0)
            self.last_peak = ts
        elif self.above and x < 0.1 * self.env:
            self.above = False
        self.prev = x

_PPG = PPGDetector()

def _floats(args):
    return [float(a) for a in args if isinstance(a, (int, float)) and math.isfinite(float(a))]

def _osc_handler(address, *args):
    if HUB.input != "muse":            # Petal may keep streaming while demo mode is active
        return
    HUB.osc_last_ts = time.time()
    addr = address.lower()
    vals = _floats(args)
    if addr.endswith("/eeg") or "/eeg" in addr:
        if len(vals) >= 4:
            tp9, af7, af8, tp10 = vals[-4:]        # Muse order: TP9, AF7, AF8, TP10
            push_eeg(tp9, af7, af8, tp10)
    elif addr.endswith("/ppg") or "/ppg" in addr:
        if vals:
            # Petal streams [sample_id, timestamps..., ambient, IR, red]; IR carries the pulse.
            v = vals[-2] if len(vals) >= 3 else vals[-1]
            _PPG.sample(v, time.time())
    elif "heart" in addr or addr.endswith("/hr"):
        if vals and 30.0 <= vals[-1] <= 220.0:
            register_beat(time.time(), bpm=vals[-1])

def start_osc():
    """Start the OSC listener once. Returns True if listening."""
    if HUB.osc_started:
        return True
    try:
        from pythonosc.dispatcher import Dispatcher
        from pythonosc.osc_server import ThreadingOSCUDPServer
    except ImportError:
        print("[muse] python-osc not installed — `pip install python-osc`")
        return False
    try:
        disp = Dispatcher()
        disp.set_default_handler(_osc_handler)
        server = ThreadingOSCUDPServer((MUSE_OSC_HOST, MUSE_OSC_PORT), disp)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        HUB.osc_started = True
        print(f"[muse] OSC listener on udp://{MUSE_OSC_HOST}:{MUSE_OSC_PORT} (point Petal Metrics here)")
        return True
    except Exception as e:
        print(f"[muse] could not open OSC port {MUSE_OSC_PORT}: {e}")
        return False


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

        # EEG between beats at ~10 Hz: alpha-dominant when calm, beta-dominant when aroused
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
                push_eeg(chan(1.0), chan(2.0), chan(3.0), chan(4.0))
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
    """Select the computer input: Muse 2 (Petal Metrics OSC) or demo mode."""
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

    if choice == "demo":
        start_demo()
        return JSONResponse({"ok": True, "input": "demo"})

    # Muse: open the OSC port and wait for Petal Metrics data to actually arrive.
    if not start_osc():
        return JSONResponse({"ok": False, "error": "muse_connect_failed"})
    t0 = time.time()
    while time.time() - t0 < MUSE_CONNECT_TIMEOUT:
        if HUB.osc_last_ts > t0:
            return JSONResponse({"ok": True, "input": "muse"})
        await asyncio.sleep(0.25)
    return JSONResponse({"ok": False, "error": "muse_connect_failed"})


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
    return JSONResponse({"ok": True, "stressed": stressed,
                         "baseline": HUB.baseline, "calibration_sec": 0 if stressed else BASELINE_SEC})


def snapshot():
    now = time.time()
    with HUB.lock:
        beats_fresh = (now - HUB.last_beat_ts) < BEAT_STALE_SEC and HUB.bpm is not None
        eeg_out, eeg_active = {}, {}
        for c in EEG_CHANNELS:
            fresh = (now - HUB.eeg_ts[c]) < EEG_STALE_SEC and HUB.eeg[c] is not None
            eeg_active[c] = fresh
            eeg_out[c] = round(HUB.eeg[c], 2) if fresh else None
        calibrating = (HUB.stressed_start is False and HUB.baseline is None)
        cal_left = None
        if calibrating and HUB.base_t0 is not None:
            cal_left = max(0.0, BASELINE_SEC - (now - HUB.base_t0))
        elif calibrating:
            cal_left = BASELINE_SEC
        stress = round(HUB.stress, 1) if (HUB.stress is not None and not calibrating) else None
        return {
            "input": HUB.input,
            "bpm": round(HUB.bpm, 1) if beats_fresh else None,
            "hrv_diff": round(HUB.hrv_diff, 1) if (beats_fresh and HUB.hrv_diff is not None) else None,
            "beat_seq": HUB.beat_seq,
            "eeg": eeg_out, "eeg_active": eeg_active,
            "stress": stress,
            "stress_label": _stress_label(stress),
            "calibrating": calibrating,
            "calibration_left": None if cal_left is None else round(cal_left, 1),
            "baseline": HUB.baseline,
            "bucket": None if not beats_fresh else _bucket_of(HUB.bpm),
            "muse_streaming": (now - HUB.osc_last_ts) < 5.0,
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
# SUNO AI library — BPM buckets with a no-repeat cycle per folder.
# ---------------------------------------------------------------------------
PLAYED = {}                    # bucket -> set(filenames served this cycle)
PLAYED_LOCK = threading.Lock()

def _bucket_of(bpm):
    """Return the calming song/circle bucket for a live heart rate.

    The intervention intentionally starts one ten-BPM step below the listener's
    current bucket. Values outside the available 60…150 BPM library clamp to
    the nearest playable folder.
    """
    return max(60, min(150, int(bpm // 10) * 10 - 10))

def _tracks_in(bucket):
    folder = os.path.join(MUSIC_DIR, str(bucket))
    out = []
    if os.path.isdir(folder):
        for ext in ("*.mp3", "*.wav", "*.ogg", "*.m4a", "*.flac"):
            out += [os.path.basename(p) for p in glob.glob(os.path.join(folder, ext))]
    return sorted(out)

@app.get("/api/suno/next")
def api_suno_next(bpm: float = None, bucket: int = None, current: str = ""):
    """Next SUNO song for the given BPM (or explicit bucket, used by Breathe).
    Never repeats a song until the whole folder (cycle of 3) has been played."""
    if bucket is None:
        if bpm is None:
            with HUB.lock:
                bpm = HUB.bpm
        if bpm is None:
            bpm = 60.0
        bucket = _bucket_of(bpm)
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
    print(f"[muse] Petal Metrics should stream OSC to udp://127.0.0.1:{MUSE_OSC_PORT}")
    try:
        threading.Timer(1.2, lambda: webbrowser.open(url)).start()
    except Exception:
        pass
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
