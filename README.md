# Adaptive Music for Stress Management

A closed-loop biofeedback app: it reads your heart (and brain) in real time, scores your
stress on a 0–100 meter, and adapts the music you hear to bring it down.

Two editions live in this repository:

| Edition | Branch | What it is |
|---|---|---|
| **Computer** | `final_computer` | Python web dashboard · Muse 2 headband (MuseLSL) or demo mode |
| **Mobile** | `final_mobile` | Native iOS app (open in Xcode) · camera-PPG reader or Apple Watch streaming |

This branch carries both: the computer app at the repo root and the Xcode project in
`AdaptiveMusicMobile/`.

```
 Muse 2 ── MuseLSL (EEG + PPG) ──►┐
 iPhone camera + flashlight ─────►│  BPM · HRV differential · EEG
 Apple Watch workout session ────►┘        │
                                           ▼
                        baseline ──► stress meter (0–100)
                     Calm 0–33 · Mild-stress 33–66 · Stressed 66–100
                                           │
                                           ▼
        ┌── SUNO AI songs (BPM_folder/60…150, three per folder, no-repeat cycles)
        ├── Spotify + Claude personalization (Vibe · Artist · Playlist · Song)
        └── Relief: Karaoke (instrumental + synced lyrics) · Breathe · Play-along
```

## The flow

1. **Choose your device** — Mobile or Computer.
2. **Choose the input** — Computer: stream live from a Muse 2 headband (or demo mode).
   Mobile: read BPM from the camera + flashlight, or stream live from an Apple Watch.
3. **"Are you stressed?"** — *Yes*: the baseline is fixed at the average person's
   60 BPM and 20 ms HRV differential. *No*: your first 30 seconds are averaged into a
   personal baseline (EEG displays instantly either way).

## The dashboard

- **Graphs** — BPM (sampled once per heartbeat), HRV differential (needs three
  heartbeats to start), and four EEG channels — right brain (AF8), left brain (AF7),
  right ear (TP10), left ear (TP9). Each EEG graph contains five simultaneous band-power
  traces (Delta 1–4 Hz, Theta 4–8 Hz, Alpha 8–13 Hz, Beta 13–30 Hz, Gamma 30–45 Hz).
  The Signal-JEPA classification contributes to the meter without adding status text to
  the individual graphs. Inactive inputs stay blank.
- **Meter** — the stress label (Calm / Mild-stress / Stressed) above the actual meter
  value, colored green / yellow / red, over a horizontal meter with all three labels.
  The empty card below the meter is where the Relief UI renders.
- **Personalize** — the SUNO AI player (song name, adjustable timeline, « ▶ »): the
  current song always comes from the `((BPM // 10) * 10) - 10` folder (clamped 60–150), fading
  out and in when the bucket changes, never repeating a song within a cycle. Below it,
  enter your **Anthropic API key** → **Connect Spotify** (Premium required) → pick
  **Vibe / Artist / Playlist / Song**; Claude names real songs, Spotify Search resolves
  them, and they play with a full timeline + transport. Playlist mode walks your actual
  playlist with « and ».
- **Relief** — three options:
  - **Karaoke** — Claude finds an *instrumental version* of the song and LRCLIB supplies
    Spotify-style time-synced lyrics; the track name and timeline switch to the
    instrumental. Pausing the song pauses the lyrics.
  - **Breathe** — an expanding/contracting circle locked to the actual beats of the
    song (live waveform-spike analysis) at `((BPM // 10) * 10) − 10`, re-targeting as
    your heart slows until it reaches your baseline. A waveform visualizer rides below
    the circle. Spotify songs are blocked here — only the AI-generated songs work.
  - **Play-along** — a piano (keys **A–J** = C–B, **W/E** = C♯/D♯, **T/Y/U** = F♯/G♯/A♯)
    and a drum kit (**A S D F G H J K** = kick, hi-hat, snare, low/mid/high tom, crash,
    ride). Tap to play on mobile.

## Running the computer edition

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 server.py            # opens http://127.0.0.1:8000
```

- **Muse 2** — turn on the headband, make sure no other phone/computer app is connected
  to it, then click *Connect and read Muse 2 headband*. The server uses
  [MuseLSL](https://github.com/alexandrebarachant/muse-lsl) directly and consumes all
  native TP9/AF7/AF8/TP10 EEG samples at 256 Hz plus the three-channel 64 Hz PPG stream.
  BPM and successive-RR HRV are derived from all three PPG wavelengths: the server removes
  optical drift, filters to the physiological heart-rate range, and automatically uses the
  clearest channel and pulse polarity. On macOS, allow Bluetooth access for Terminal/Python
  if prompted. The server can also attach to an already-running `muselsl stream --ppg`
  process.
- **Demo mode** — no hardware needed; coherent simulated biosignals drive everything.
- **Spotify** — create an app at <https://developer.spotify.com/dashboard>, add
  `http://127.0.0.1:8000/callback` as a redirect URI, then:
  ```bash
  export SPOTIFY_CLIENT_ID=...  SPOTIFY_CLIENT_SECRET=...
  ```
  Spotify **Premium** is required for in-browser playback (Web Playback SDK).
- Your **Anthropic API key** is entered in the dashboard (per-browser session; never
  written to disk).

> **Git LFS**: `BPM_folder.zip` (~105 MB) is stored with Git LFS — run `git lfs pull`
> if you only got a 134-byte pointer file. The server auto-extracts it on first run.

## EEG model and stress score

The bundled `models/universe-signal-jepa-stress-detector/` is a two-class Braindecode
`SignalJEPA_PreLocal` classifier fine-tuned on the UNIVERSE Wild-session recordings.
It consumes TP9, AF7, AF8, and TP10 jointly as a `4 × 256` window: two seconds at
128 Hz. Class 0 is very-low/low stress and class 1 is high/very-high stress.

Live Muse data remains buffered at its native 256 Hz. On every half-second graph
refresh, the latest four-channel context is average-referenced, filtered from
0.5–50 Hz with a 50 Hz notch, resampled to 128 Hz, cropped to two seconds, and
standardized per channel. The model then runs once on all four channels together.
The joint `P(high stress)` contributes to the meter; it is not four independent
channel classifications.

The complete training and evaluation package is in `create_JEPA/`, including the
script, exact dependencies, selected checkpoint, machine-readable metrics, and held-out
test report. Its participant-held-out recording balanced accuracy is 56.25%; this is
an experimental wellness signal, not a medical diagnostic. See
`create_JEPA/README.md` for the reproducible command and limitations.

The 0–100 meter applies the requested formula using every currently available term
(probabilities expressed as percentages):

```text
clamp(P(high stress) × 100
      + (current BPM − baseline BPM)
      + (current HRV − baseline HRV), 0, 100)
```

If BPM or HRV is missing, its delta is omitted. If both heart metrics are missing,
Signal-JEPA still drives the meter. Likewise, a fresh heart metric can drive the meter
when EEG is unavailable. BPM/HRV terms require their baseline; EEG does not.

Choosing **No** during setup calibrates only BPM and HRV for 30 seconds. EEG is never
included in baseline calibration.

## Running the mobile edition

See [`AdaptiveMusicMobile/README.md`](AdaptiveMusicMobile/README.md) — or check out the
`final_mobile` branch, where the Xcode project sits at the repository root.

## Repository layout (this branch)

```
server.py               # FastAPI: MuseLSL ingest, PPG beat detection, scoring, music APIs
eeg_pipeline.py         # 256 Hz buffers, five EEG bands, live Signal-JEPA inference
create_JEPA/            # reproducible UNIVERSE Signal-JEPA training/evaluation package
models/                 # deployed Signal-JEPA weights and configuration
claude_music.py         # Claude song-picking · Spotify search · instrumental finder · LRCLIB
static/                 # the dashboard (index.html, style.css, app.js)
BPM_folder.zip          # SUNO AI library (Git LFS) — auto-extracted on first run
AdaptiveMusicMobile/    # the iOS + watchOS Xcode project (see final_mobile)
```
