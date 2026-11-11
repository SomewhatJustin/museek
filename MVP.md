# Museek: Bare-Bones MVP

The original MVP scope below is retained as history. The November 2026 browser
manager extends it with a shared song library, editable playlists, uploads and
playlist-specific notes. See [the current manager guide](docs/WEB-MANAGER.md).

Status: product definition  
Primary user: a family member who should be able to listen without understanding files  
Primary platform: iPhone  

## The problem

Sharing an MP3 file is easy. Giving someone—especially a child—a durable, friendly way to listen to a small, privately shared music library is not.

The listener should not need to understand downloads, folders, file formats, servers, or music-library import. The owner is willing to provide the music files and run a server. What is missing is the experience between those two things: private access, a recognizable library, and a player that continues working when the phone is locked.

## Product promise

> Put MP3s in a folder on your server. Invite one person. They open Museek and listen.

Museek is a private, self-hosted music player for small, explicitly shared collections. It is not a streaming service, music store, or general-purpose media server.

## The one MVP scenario

1. The owner creates `/music/Bedtime Favorites/` on the server and copies MP3s into it.
2. Museek discovers the folder and treats it as a collection called “Bedtime Favorites.”
3. From the server, the owner creates an invite for “Listener” and grants access to that collection.
4. The owner sends her a pairing link that remains valid for 24 hours.
5. She installs the iPhone app, enters those two values once, and sees the collection.
6. She taps a track. It streams, keeps playing with the screen locked, and exposes play/pause/next/previous on the lock screen.
7. When the owner adds or removes an MP3, the app reflects the change after its next refresh.

If this flow feels dependable and understandable to her, the MVP succeeds.

## Core product model

The only content primitive in the MVP is a **collection**.

- One immediate child folder inside `/music` equals one collection.
- Each MP3 inside that folder equals one track in the collection.
- A track belongs to exactly one collection. Duplicating a track across two folders is acceptable in the MVP.
- The folder name is the collection name.
- Track title, artist, album, track number, and embedded artwork come from ID3 tags.
- `cover.jpg` or `cover.png` in the folder is the collection artwork; otherwise Museek uses embedded artwork or a default image.
- Tracks sort by disc and track number, then filename as a fallback.

This deliberately avoids separate album, artist, playlist, and library concepts. Those can be introduced only after real use shows they are needed.

## Required features

### Owner/server

- Read a mounted music directory without modifying the original files.
- Scan on startup and periodically while running. A change should appear within one minute.
- Index MP3 metadata and artwork.
- Add a named recipient from a command-line tool.
- Grant or revoke that recipient’s access to a collection.
- Create a pairing link that can pair multiple devices and expires after 24 hours.
- List and revoke paired devices.
- Persist its index, grants, and sessions across restarts.
- Serve audio with the correct content type, content length, and HTTP byte-range support so seeking and duration detection work correctly.
- Provide one health endpoint for deployment checks.

There is no owner-facing web interface in the MVP. File management stays in the filesystem; access management stays in a few server commands.

### Listener app

- Pair using a server URL and temporary code; no email address or password is required.
- Remember the session securely.
- Show only collections shared with the paired recipient.
- Show collection artwork and a track list.
- Play, pause, seek, skip forward, and skip back.
- Continue playback in the background and while the iPhone is locked.
- Show lock-screen artwork and controls.
- Show a persistent mini-player and a full Now Playing screen.
- Refresh the library on launch and by pull-to-refresh.
- Display clear empty, loading, unavailable-server, and playback-error states.
- Sign out and forget the local session.

## Explicit non-goals

The MVP does **not** include:

- Uploading or editing music in the app
- A server administration website
- Offline downloads or full device sync
- Formats other than MP3
- Audio transcoding, normalization, or format repair
- Search, shuffle, repeat, queues that survive relaunch, or custom playlists
- Lyrics, recommendations, ratings, play counts, favorites, or social features
- Anonymous listening without pairing
- Collaborative collection editing
- Push notifications or real-time updates
- Import from Spotify, Apple Music, or the device’s Music library
- Payments, purchases, or DRM
- Password recovery, email delivery, OAuth, or household account management
- General releases for Android, web, Chromebook, Windows, Linux, or macOS

The client is intentionally iPhone-only and uses native Apple frameworks throughout.

## Technology choices

### Mobile app

- **SwiftUI** for the interface, using the Observation framework for shared state and native NavigationStack, sheets, refresh, forms, and accessibility behavior.
- **AVFoundation** for queued MP3 playback and seeking, with **MediaPlayer** for lock-screen metadata and remote controls.
- **Keychain Services** for the long-lived session token and the application-support directory for downloaded originals.
- Platform secure storage for the long-lived session token.
- No local database in the MVP. The server is the source of truth and the app holds only its current fetched state.

### Server

- **Go**, using the standard HTTP stack wherever practical. The target is one small, easily deployed binary with low operational overhead.
- **SQLite** for recipients, grants, pairing codes, device sessions, and indexed metadata. Run it in WAL mode. This is a single-server, household-scale product; PostgreSQL and a separate cache would add operations without solving an MVP problem.
- The host filesystem for MP3s, mounted read-only into the service.
- A small on-disk cache for extracted/resized artwork.
- A versioned JSON HTTP API shared by the native app and server.
- **Tailscale Funnel** for a publicly trusted HTTPS address. Plain HTTP is acceptable only on a local development machine.
- A Docker image and example Compose file with `/music:ro` and `/data:rw` mounts.

### Repository shape

```text
/app       Native SwiftUI application
/server    Go server and owner CLI
/api       API contract and fixtures
/deploy    Docker and example reverse-proxy configuration
```

## Minimal server interface

The exact names can change, but the responsibilities should remain this small:

```text
POST /v1/pair                         exchange a temporary code for a device session
GET  /v1/collections                  list the recipient's collections
GET  /v1/collections/{id}             collection details and tracks
POST /v1/tracks/{id}/play-url         create a short-lived authorized stream URL
GET  /v1/streams/{id}?token=...       stream MP3 with byte-range support
GET  /v1/artwork/{id}                 fetch artwork
GET  /healthz                         liveness check
```

Normal API calls use the device session token. Playback uses a short-lived signed URL so the native audio player does not need to attach the permanent credential to its media requests. Stream tokens should expire quickly and must never grant access to another track.

Suggested owner commands:

```text
museek scan
museek invite --recipient "Listener" --collection "Bedtime Favorites"
museek share --recipient "Listener" --collection "Road Trip"
museek unshare --recipient "Listener" --collection "Road Trip"
museek devices --recipient "Listener"
museek revoke-device <device-id>
```

## Minimal stored data

- **Collection:** stable ID, relative folder path, display name, artwork fingerprint, scan timestamps
- **Track:** stable ID, collection ID, relative file path, size, modified time, parsed tags, duration, artwork fingerprint
- **Recipient:** stable ID and display name
- **Grant:** recipient ID and collection ID
- **Pairing code:** hashed code, recipient ID, expiry, last-used timestamp
- **Device session:** hashed token, recipient ID, device name, created/last-used/revoked timestamps

Moving or renaming a file may make it look like a deletion plus a new track. Preserving identity across moves is not an MVP requirement.

## Security and rights boundaries

- The service is private by default: every collection and stream requires an explicit grant.
- Pairing codes are reusable for 24 hours, stored hashed, and rate-limited.
- Device tokens are random, stored hashed on the server, and revocable.
- Music paths are never accepted directly from a client. The server resolves opaque IDs and rejects path traversal.
- The music mount is read-only.
- Internet-facing use requires HTTPS.
- Access logs must not retain signed stream URLs.
- The operator is responsible for sharing only audio they have the right to share. Museek should not include discovery, public indexing, or mechanisms intended to bypass DRM.

## Acceptance criteria

The MVP is complete when all of the following are demonstrated on a real iPhone (can use simulator) against the remotely hosted server (elitedesk-1, accessible over ssh, justin@elitedesk-1):

1. Copy a tagged MP3 into a collection folder; it appears in the app within one minute without rebuilding or reconfiguring the app.
2. Delete that MP3; it disappears after refresh and can no longer be streamed.
3. Pair a new phone with a temporary code and begin playback without creating a password.
4. A recipient sees only collections granted to them.
5. An unpaired client cannot list metadata, fetch artwork, or stream audio.
6. Play, pause, seek, next, and previous work over an ordinary internet connection.
7. Playback continues with the app backgrounded and the screen locked; lock-screen controls work.
8. Restart the server and app without losing grants or the paired session.
9. Revoke a device and confirm it can no longer refresh or start a new stream.
10. A non-technical listener can reach and play an invited collection without help after installation and pairing.

## What to borrow from Immich—and what not to

Immich’s self-hosted product posture and explicit sharing model remain useful references, while Museek’s client is native SwiftUI.

Immich’s server is much larger: TypeScript/NestJS with PostgreSQL, background-job infrastructure, Valkey/Redis-compatible storage, and a separate machine-learning service in its standard deployment ([server package](https://github.com/immich-app/immich/blob/main/server/package.json), [Compose definition](https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml)). Its web client uses SvelteKit. Those choices make sense for Immich’s broad feature set—uploads, video processing, search, machine learning, shared albums, and multiple kinds of background work—but that rationale is an inference from the repository rather than a published stack manifesto.

Museek should borrow Immich’s self-hosted product posture, server-address login, polished client, and explicit sharing model. It should not inherit Immich’s operational architecture before it has Immich-sized problems.

## Release boundary

The first family pilot can use TestFlight. This is a testing channel, not permanent distribution: Apple makes a TestFlight build unavailable after 90 days ([Apple TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)). If Museek becomes something a listener depends on, a normal App Store release—or another durable Apple-approved distribution route—must follow.

## First decision after the MVP

After real use, ask only this:

> Is the biggest pain unreliable connectivity, managing collections, or reaching another device?

- If connectivity: build explicit offline downloads.
- If management: build a tiny owner web interface.
- If another device: build a dedicated web or Android client next.

Do not choose that branch before the iPhone streaming loop is proven.
