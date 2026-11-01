# MVP Acceptance Audit

This file records the August 18, 2026 acceptance run against the production-like deployment on `elitedesk-1` and the dedicated iOS Simulator. The only remaining human step is letting the intended listener complete the flow without coaching.

| # | Criterion | Evidence | Status |
|---|---|---|---|
| 1 | A copied MP3 appears within one minute. | A temporary tagged MP3 copied into the live collection appeared through the HTTPS API after 41 seconds under the deployed 45-second scan cadence. The Simulator showed the live collection. | Proven remotely |
| 2 | A deleted MP3 disappears and cannot stream. | The temporary MP3 disappeared after 45 seconds, the collection returned to 15 tracks, and its previously valid signed stream URL returned 404. | Proven remotely |
| 3 | Pair a phone once and play without a password. | The Simulator paired to `elitedesk-1` with the server URL and a temporary code, displayed “Sadie mixtape — 15 tracks,” and began playback. | Proven in Simulator |
| 4 | A recipient sees only granted collections. | A second ungranted collection was indexed during the live audit. A newly paired recipient still received only “Sadie mixtape.” | Proven remotely |
| 5 | An unpaired client cannot list, fetch artwork, or stream. | Unauthenticated metadata, artwork, and stream requests against the deployed HTTPS endpoint each returned 401. | Proven remotely |
| 6 | Play, pause, seek, next, and previous work over an ordinary internet connection. | The Simulator played and paused, moved the progress slider from 7% to 75%, advanced from “Baby Blue” to “Complicated,” and returned with Previous. Byte ranges returned 206. The same service is now public through Tailscale Funnel. | Proven in Simulator |
| 7 | Background and lock-screen playback/controls work. | With the screen locked, iOS showed “Baby Blue,” Cindy Lee, embedded Diamond Jubilee artwork, and advancing progress in the native media card. The app pins the upstream iOS playing-state fix required by the current unpublished `audio_service` patch. Simulator transport glyphs have a known rendering issue, so a physical-iPhone visual check remains prudent. | Runtime media session proven |
| 8 | Restart server and app without losing grants/session. | The Compose service was recreated with its persistent volume, then the already-paired app refreshed “Sadie mixtape — 15 tracks.” The app was also stopped and relaunched without pairing again. | Proven remotely |
| 9 | Revoking a device stops refresh and new streaming. | Revoking the Simulator’s device changed the app to “Pair again.” A separate live API session returned 401 immediately after revocation. The Simulator was re-paired afterward so the final installation remains usable. | Proven remotely |
| 10 | A non-technical listener can pair and play without help. | The app is left paired and working, but this criterion requires the intended listener to try a fresh installation without coaching. | Human test pending |

## Final deployed state

- Public URL: `https://elitedesk-1.tail6900fe.ts.net/museek`
- Host binding: `127.0.0.1:18080`; Tailscale Funnel exposes `/museek` on standard HTTPS port 443. Port 10002 remains tailnet-only.
- Collection: `Sadie mixtape`, 15 MP3 tracks.
- Media: every remote SHA-256 hash matches `/Users/justin/Music/Sadie mixtape MP3`; the AAC/FLAC originals were not modified.
- Active listener device: one current Listener iPhone session; the device used for the revocation test remains recorded as revoked.
- Container: `museek:latest`, `amd64`, read-only root filesystem, read-only music bind, persistent database volume, non-root application process.

## Verification commands passing

```sh
cd server && go vet ./... && go test -race ./...
cd app && xcodegen generate && xcodebuild -project Museek.xcodeproj -scheme Museek -destination 'platform=iOS Simulator,name=Museek iPhone 17 Pro' test
docker compose -f deploy/elitedesk.compose.yaml config --quiet
```

XcodeBuildMCP also completed a clean native iOS build/install/launch on the “Museek iPhone 17 Pro” Simulator after the final dependency and accessibility changes.

## Remaining completion step

Give the fresh 24-hour invitation link to the intended listener on a fresh installation. Observe without coaching whether she can pair, open the collection, and start a track. If she can, criterion 10 and the MVP are complete.
