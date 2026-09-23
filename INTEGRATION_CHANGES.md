# Integration changes — September 2026

## Spotify and Claude

Claude receives only independently typed preferences, the stress estimate/label, and a wellness goal. It returns up to six title/artist pairs before any Spotify search. Spotify responses, account details, playlist names and listening history are never included in prompts. Python (computer) and Swift (mobile) match titles/artists locally: punctuation, case and accents are normalized; remasters may match, while live/remix versions must be explicitly requested. Unreliable matches are skipped.

Playlist forward/back navigation fetches the requested entry, not the entire library. Stress-based playlist adaptation matches independent Claude suggestions against a bounded 25-entry window locally. If none match, the current song continues. No AI is asked to choose from Spotify metadata.

Computer playback uses Spotify's Web Playback SDK and Web API. Mobile uses PKCE and the Web API to control an active Spotify Connect device. Premium and an authorized developer-app account remain required. Artwork is unmodified; playback UI includes the official Spotify logo and a track link. Play-along is blocked while Spotify owns audio, and source handoffs stop the other source first.

Disconnect cancels/invalidates in-flight lookups, deletes retained tokens, playlist data, preferences and listening history, and requests a playback pause. If offline, remote playback may need to be stopped in Spotify. Revoking authorization at Spotify is a separate action at https://www.spotify.com/account/apps/. Saved Adaptune session charts are not Spotify data and are not deleted by disconnect.

## Keys, consent and request limits

Mobile stores the Anthropic key (and Spotify refresh token) in device-only iOS Keychain, migrating legacy UserDefaults values only after a successful secure write. Remove API key deletes it and cancels active analysis. Sign-out clears credentials.

Computer keys stay only in temporary server memory: 30-minute absolute expiry, clear on removal/session end/sign-out/disconnect; inactive browser sessions expire in one hour. The browser does not persist keys. Provider exception bodies and keys are never logged or returned. A running request can retain its captured credential until its 25-second timeout; its result is discarded after cancellation/expiry.

Deployment: copy .env.example to .env on computer, set ADAPTUNE_ENV=production, use HTTPS and a matching HTTPS Spotify redirect URI. Terminate TLS at a trusted reverse proxy; configure uvicorn --proxy-headers --forwarded-allow-ips with that proxy's address only, never '*'. HTTP is allowed only for loopback development. Use a single application worker because sensor state and credential sessions are in memory. Disable request-body/header logging in proxies and monitoring. Supabase values stay in root .env on computer and AdaptiveMusic/Info.plist on iOS; never ship a service-role key or Spotify client secret on iOS.

Before optional session analysis, the user explicitly permits sending relative timestamps, stress scores and the recomputed average. Emails, account IDs and absolute dates are excluded. Responses are validated and labeled AI-generated wellness information that may be inaccurate, not diagnosis. Preferences/score transmission and API-account billing are disclosed next to personalization.

One in-flight AI request, at least five seconds between requests, at most eight per minute, and automatic stress adaptations at most once every 10 seconds. No automatic Anthropic SDK retries. Validation and cooldowns also run server-side/on-device, not just on buttons.

## Replacement music and karaoke

BPM_folder.zip contains exactly one supplied song per bucket, 60–150 BPM in steps of ten. music_manifest.json records each filename and SHA-256. The owner confirmed on September 22, 2026 that these were generated during an active Suno Pro/Premier subscription. No subscription purchase or regeneration was performed by this change.

The latest owner instruction supersedes the proposed public-domain karaoke catalog: karaoke now plays **Ransom — Jade Key (ft. Mary Sweet)** and displays the supplied transcript verbatim. Opening karaoke replaces the current music; leaving it stops the recording. Pausing Spotify must succeed before local karaoke starts. There is no Claude call, API-key requirement, LRCLIB lookup, instrumental search, timestamp synchronization or automated lyric scrolling.

The supplied recording was named "Jade Key - Ransom (ft. Mary Sweet) Copyright Free Music.mp3". That filename is not license evidence. No redistribution license, source URL, or cleared territories were supplied or independently verified. The app does not label this work public domain. Retain/obtain permission for distributing the recording and lyrics before public distribution. This implementation does not certify legal compliance or guarantee Spotify app approval.

THIRD_PARTY_NOTICES.txt and existing license/copyright notices are preserved. Spotify branding assets come from the official 2024 full-logo package:
https://developer.spotify.com/images/guidelines/design/2024-spotify-full-logo.zip
Branding remains subject to Spotify's terms and design guidelines, not the app's software license:
https://developer.spotify.com/documentation/design
https://developer.spotify.com/policy

## Verification

Computer: python -m unittest discover -s tests; node --check static/app.js; node --check static/portal.js.
Mobile: xcodebuild -project AdaptiveMusic.xcodeproj -scheme AdaptiveMusic -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build.
Matcher: swiftc AdaptiveMusic/Services/SpotifyTrackMatcher.swift tests/MatcherChecks.swift -o /tmp/adaptune-matcher-checks && /tmp/adaptune-matcher-checks.

Live Spotify playback/paid Anthropic calls and physical-device audio handoffs still require an account/device smoke test. No camera, Muse, Watch sensor processing, JEPA weights, Supabase schema, app identifiers or signing settings were changed.
