# Adaptive Music for Stress Management — Mobile (iOS + watchOS)

The native mobile edition: a SwiftUI iPhone app with an embedded Apple Watch companion.
It reads your pulse from the **camera + flashlight** or streams live heart data from an
**Apple Watch workout session**, scores your stress 0–100, and adapts the music.

## Requirements

- **Xcode 16 or newer** (the project uses folder-synchronized groups)
- iOS 17+ iPhone; watchOS 10+ Apple Watch (optional, for the watch input)
- **Git LFS** for the song library: `git lfs pull` must leave `BPM_folder.zip` at
  ~105 MB (a 134-byte file is the pointer, and the build will stop with a clear error)
- An Apple ID for code signing (free personal team works; HealthKit is supported)

## Setup

1. `git lfs pull` (if you haven't).
2. Open `AdaptiveMusic.xcodeproj` in Xcode.
3. Select the **AdaptiveMusic** target → *Signing & Capabilities* → pick your Team.
   Do the same for **AdaptiveMusicWatch**.
4. Run the **AdaptiveMusic** scheme on your iPhone. The *Bundle SUNO Songs* build phase
   unzips `BPM_folder.zip` into the app bundle automatically.

### Spotify (for the Personalize section)

1. Create an app at <https://developer.spotify.com/dashboard>.
2. Add the redirect URI **`adaptivemusic://spotify-callback`** in the app settings
   (type: iOS / mobile is fine — PKCE is used, no client secret on the device).
3. Put your **Client ID** into `AdaptiveMusic/Info.plist` under the `SpotifyClientID` key.
4. Playback is controlled through the **Spotify app** on the same iPhone (install it and
   sign in with a **Premium** account — the app checks and tells you if the account
   isn't Premium).
5. Your **Anthropic API key** is entered inside the app (Personalize card) and stored
   only on the device.

## The inputs

- **Read data from mobile** — accept the camera permission; the flashlight turns on and
  the camera reads your BPM from your fingertip, one reading per heartbeat, with the
  HRV differential starting on the third beat.
- **Stream data live from Apple Watch** — tap **Activate workout session**; HealthKit
  launches the watch companion, which runs an `HKWorkoutSession` and streams live BPM
  over WatchConnectivity. If no paired watch (with the app installed) is found you'll
  see: *"I apologize, but you must first connect your apple watch to your apple mobile
  device."* (Install the watch app once from Xcode, or from the Watch app on iPhone.)

## The dashboard

Same four modals as the computer edition — **Graphs** (EEG stays blank on mobile: no
Muse input here), **Meter**, **Personalize** (SUNO player + Spotify/Claude tabs), and
**Relief** (Karaoke with synced lyrics, Breathe with the beat-locked circle and
waveform, Play-along piano & drums — tap to play).

## Project layout

```
AdaptiveMusic.xcodeproj      # open this
AdaptiveMusic/               # iPhone app (SwiftUI)
  Models/SignalHub.swift     # beats -> BPM/HRV differential -> baseline -> stress meter
  Sensors/CameraPPGReader…   # camera+torch PPG · WatchLink (HealthKit + WCSession)
  Audio/SunoPlayer.swift     # BPM-bucket engine player with fades + waveform tap
  Audio/InstrumentEngine…    # synthesized piano + drum kit
  Services/                  # Spotify (PKCE + Web API) · Claude · LRCLIB · orchestration
  Views/                     # flow + the four dashboard cards + relief views
AdaptiveMusicWatch/          # watch companion: HKWorkoutSession streaming
BPM_folder.zip               # SUNO AI library (Git LFS), bundled at build time
```
