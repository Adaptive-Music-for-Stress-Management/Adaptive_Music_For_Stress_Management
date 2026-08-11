# Adaptive Music for Stress Management

A closed-loop biofeedback system: it reads your body's stress signals in real time, turns them into a 0–100 **stress index**, and continuously adapts the music you hear to bring that stress down. Sensors feed a live clinical-style dashboard; the dashboard drives a music player whose songs are chosen to match (and counteract) your current stress state.

```
 Arduino sensors ──serial──┐
 Apple Watch ──HTTP POST──►│  server.py  ──► stress index (0–100) ──► band: calm / neutral / elevated
 (simulator when neither)──┘      │                                          │
                                  ▼                                          ▼
                          live web dashboard  ◄──────────────  adaptive music player
                          (traces, gauge, music)         (local library or Spotify + Claude)
```

## How it works

### 1. Signal acquisition

Three input sources feed the same pipeline; you pick the device in the dashboard on first load:

| Source | Channels | How it arrives |
|---|---|---|
| **Arduino kit** (default) | BPM, HRV (RMSSD), EDA, skin temp | USB serial, one line per heartbeat |
| **Apple Watch** | BPM, HRV, motion | An iPhone app POSTs HealthKit / CoreMotion data to `/api/score` |
| **Simulator** | whatever the selected device would provide | Runs automatically whenever no real data is arriving |

The serial reader auto-detects two line formats: labeled (`BPM:72,RMSSD:41.2,EDA:5.34,TEMP:33.8`) or bare CSV mapped by `CSV_ORDER`. The watch endpoint accepts raw material — beat-to-beat RR intervals (converted server-side to BPM + RMSSD) and raw accelerometer samples (converted to mean g-force) — or already-computed values.

The **simulator** stands in whenever no hardware is connected (`SIM_WHEN_NO_SERIAL`). It drives all channels coherently from a latent "arousal" random walk (HR up, HRV down, EDA up, skin temp down, with occasional stress episodes), beats in real time, and is device-aware: in Apple Watch mode it only fabricates the channels a watch would provide. The dashboard shows a SIMULATION MODE badge whenever it's active.

### 2. Baseline

Stress is scored **relative to a resting baseline**, captured per session. When you launch the server it asks:

```
[baseline] Are you feeling stressed right now? [y/N]:
```

- **No** — the first 30 seconds (`BASELINE_SEC`) of readings are averaged per channel and frozen as the baseline. Sit still during "capturing baseline".
- **Yes** — a stressed launch can't produce a valid resting baseline, so calibration is skipped and literature-typical resting norms are frozen in instead (`NORMAL_BASELINE`): BPM 70, RMSSD 70 ms, EDA 5 µS, skin temp 34 °C. Tune these to your own known resting values for best accuracy.

Switching devices in the dashboard resets the session and re-forms the baseline.

### 3. Stress index

On every new HRV reading (~every 2 heartbeats), each active channel's deviation from baseline — **in the stressward direction only** — is scaled, capped at 1, and the channels are averaged × 100:

| Channel | Stress direction | Full-scale deviation |
|---|---|---|
| BPM | above baseline | +40 bpm |
| HRV (RMSSD) | below baseline | −50 ms |
| EDA | above baseline | +10 µS |
| Skin temp | below baseline (vasoconstriction) | −3 °C |

Deviations against the stress direction clamp to 0 (a low heart rate never produces a negative score). Channels that are stale, absent, or not provided by the selected device simply drop out — the score forms from whatever is active (the dashboard shows this as "4/4 leads" or "degraded"). The raw score is smoothed with an EMA (`EMA_ALPHA = 0.30`).

### 4. Music bands

The smoothed score maps to three therapy bands, with hysteresis so songs don't flap at a boundary:

- **calm** (0–38) → "Calm program"
- **neutral** (38–68) → "Steadying program"
- **elevated** (68–100) → "Down-regulation program"

A band switch requires crossing the boundary by a 5-point margin **and** at least 12 seconds in the current band. When the band changes, the music changes with it.

### 5. Adaptive music player

Two sources, toggled in the dashboard:

**LOCAL** — plays from `suno_ai_songs/<band>/` (mp3/wav/ogg/m4a/flac). The server keeps a per-band "played bin" so no song repeats until the whole band has been heard, then the cycle resets. Playback uses two `<audio>` elements with a 2.5 s crossfade; a 10 Hz watchdog guarantees the audible song always matches the current stress band, and another watchdog guarantees only the selected source is audible. The library ships as `suno_ai_songs.zip` (Git LFS) and is **auto-extracted on first run**.

**SPOTIFY** — full adaptive streaming via `fetch_spotify.py`:

1. **Claude** (the user's own Anthropic API key, entered in the dashboard) acts as the music supervisor: given the stress band's therapeutic goal plus your stated preference, it proposes real songs as JSON.
2. Each candidate is resolved through the **Spotify Search API** into a playable track (Spotify deprecated its own Recommendations API for new apps, hence the LLM-generates → Search-resolves shape).
3. The track plays in-browser through the **Spotify Web Playback SDK** (requires Spotify Premium + OAuth, done via a popup so the dashboard never reloads), with volume-fade transitions.

Three preference modes, changeable any time: **Vibe** (free-text taste, e.g. "lo-fi, acoustic, ambient"), **Artist** (only that artist's songs, picked to fit the state), and **Song** (plays that exact song; on a state change, other songs *by the same artist* that fit the new state). Per-band queues and played-bins avoid repeats.

**Owner gate** — Spotify/Claude features are restricted to the app owner. Local (loopback) browsers unlock automatically; a remote browser must enter the owner key printed in the server terminal (or set via `STRESS_OWNER_KEY`). Each browser gets its own cookie session with its own key, taste, Spotify token, and queue, so the app is safely multi-user.

### 6. Dashboard

Single-page app served at `/`, streamed a full state snapshot at 10 Hz over a WebSocket:

- **Device modal** on first load (Arduino vs Apple Watch) — sets which channels the score expects; switchable later from the header.
- **Live traces** (~24 s of history) for each channel the device provides, with per-beat value flashes and NO SIGNAL flatlines for inactive leads.
- **Stress gauge** — the 0–100 index, its band, calibration status, and lead degradation.
- **Music card** — play/pause, skip, volume, source toggle, Spotify setup (owner key → Anthropic key → Connect → preference).
- **Status rail** — serial/simulation state, baseline state, lead count, session clock.

## Hardware (Arduino kit)

Sketch: `BPM_RMSSD_EDA_TEMP/BPM_RMSSD_EDA_TEMP.ino` (Arduino Uno, no libraries needed).

| Pin | Connection |
|---|---|
| A0 | PulseSensor signal (red → 5 V, black → GND) |
| A1 | Grove GSR VCC (pin driven HIGH as the module's power rail) |
| A2 | Grove GSR signal |
| A3 | Thermistor leg 1 (internal pull-up acts as the divider resistor) |
| A4 | Thermistor leg 2 (pin driven LOW as ground) |

The sketch samples the pulse at 500 Hz with the classic PulseSensor threshold-tracking beat detector, keeps a rolling 20-beat IBI buffer for RMSSD, converts GSR to µS (Seeed formula) and the 10 k NTC to °C, and prints one labeled line per detected heartbeat at 115200 baud. If skin temperature reads offset, tune `THERM_PULLUP` in the sketch.

## Running it

```bash
pip install -r requirements.txt
python3 server.py
```

On launch you'll be asked two questions (terminal runs only):

1. `Are you feeling stressed right now? [y/N]` — picks calibration vs population-norm baseline (see above).
2. `digits after /dev/cu.usbmodem` — e.g. `11301` to select `/dev/cu.usbmodem11301` (`ls /dev/cu.*` to find yours; Enter keeps the default).

The dashboard opens automatically at `http://127.0.0.1:8000`. No Arduino? It runs in simulation mode out of the box.

> **Git LFS:** `suno_ai_songs.zip` (~121 MB) is stored with Git LFS. Clone with `git lfs` installed (`git lfs pull` if you only got a 134-byte pointer file). GitHub's "Download ZIP" does **not** include LFS content. The server detects a pointer file and tells you rather than crashing.

### Environment variables (all optional)

| Variable | Default | Purpose |
|---|---|---|
| `STRESS_PORT` | `/dev/cu.usbmodem11301` | Arduino serial port (skips the startup prompt) |
| `STRESS_BAUD` | `115200` | Serial baud (must match the sketch) |
| `STRESS_MUSIC` | `./suno_ai_songs` | Local music folder (subfolders `calm/ neutral/ elevated/`) |
| `PORT` / `HOST` | `8000` / loopback | Web bind; cloud hosts (Render etc.) inject `PORT` and get `0.0.0.0` |
| `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` | — | Spotify app credentials (server-side; required for the Spotify source) |
| `SPOTIFY_REDIRECT_URI` | `http://<host>:<port>/callback` | Must exactly match the Spotify app dashboard |
| `STRESS_OWNER_KEY` | random, printed at startup | Owner key that unlocks Spotify features remotely |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL` | — / `claude-sonnet-4-6` | Fallback Claude credentials for `fetch_spotify.py`'s CLI (the dashboard uses per-user keys) |
| `SPOTIFY_MARKET` | `US` | Search market |

### API endpoints

| Endpoint | Purpose |
|---|---|
| `GET /` | The dashboard |
| `WS /ws` | 10 Hz state snapshots (readings, active leads, stress, band, device, session) |
| `GET/POST /api/device` | Read / set the input device (switching resets the session baseline) |
| `POST /api/score` | Apple Watch / external ingest: RR intervals, accel samples, or computed values |
| `GET /api/track?band=` | Next local track for a band (no-repeat bin) |
| `GET /api/spotify/track?band=&exact=` | Next Claude-picked Spotify track for a band |
| `POST /api/config` | Save the session's Anthropic key |
| `POST /api/pref` | Set music preference (`taste` / `artist` / `song`) |
| `POST /api/owner` | Unlock Spotify with the owner key |
| `GET /login`, `GET /callback` | Spotify OAuth (popup) |
| `GET /api/spotify/status`, `GET /api/spotify/token` | Connection status / SDK token |

## Repository layout

```
server.py                      # everything server-side: ingest, scoring, web app, dashboard HTML
fetch_spotify.py               # Claude → Spotify Search pipeline (also a standalone CLI)
BPM_RMSSD_EDA_TEMP/            # Arduino Uno sketch (PulseSensor + GSR + thermistor)
suno_ai_songs.zip              # local music library (Git LFS; auto-extracted on first run)
requirements.txt               # fastapi, uvicorn, numpy, requests, anthropic, pyserial
```

`fetch_spotify.py` also works standalone: `python3 fetch_spotify.py --state elevated` prints a Claude-picked, Spotify-resolved track for that state using `ANTHROPIC_API_KEY` + Spotify client credentials from the environment.
