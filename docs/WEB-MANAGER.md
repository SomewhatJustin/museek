# Browser playlist manager

Museek serves a minimal responsive manager at `/manage/` using its existing Go
server, SQLite database, and ordinary HTML forms. No Node runtime, package install,
frontend build, CDN, or public hosting service is needed. JavaScript provides
upload feedback, selection validation, and an unsaved-note warning; all editing
operations work without it. The layout supports laptop and phone widths, with
44-pixel reorder buttons rather than depending on desktop drag-and-drop.

## Run locally

```sh
cd server
go run ./cmd/museek manage --music /path/to/music --data /path/to/data
```

Open **http://127.0.0.1:8082/manage/**. This command binds to loopback and rejects
non-local Host headers. It scans at startup. For continuous folder scanning, run
the normal server as well, pointing at the same directories.

- Create a playlist with **New playlist** and select the existing listener who
  should see it in their iPhone app. Additional sharing uses the existing `share`
  command. Creating a playlist does not share it with every listener.
- Open a playlist to move songs up/down, save a note for each song, or remove
  songs. Removing an entry leaves its audio in the library and removes that
  entry's note. Re-adding it starts with an empty note.
- **Add from library** lets you search and select existing songs. Adding an
  existing member does not duplicate it or change its note/order.
- Upload MP3s from a playlist to add them to both the playlist and the library.
  Upload from **All songs** to add only to the library. Files retain embedded
  title/artist/album/artwork; files without a title use the original filename.
- Upload up to 50 files at once, 128 MiB per file, 512 MiB per request including
  multipart overhead. Museek validates MP3 audio before saving the batch. Invalid
  files fail the whole batch. Identical browser uploads reuse one library song.
- The iPhone API returns the saved playlist order and its notes. Pull to refresh
  the app's library for new playlists and each playlist for changes. Existing
  playback queues and downloaded snapshots retain their version; re-download to
  update an offline copy. No iPhone release is needed for the server feature.

## Tailnet deployment

`MUSEEK_MANAGE_LISTEN` enables a separate management listener. It is disabled by
default. `MUSEEK_MANAGE_USERS` must be a nonempty JSON array of **exact owner
Tailscale logins**, independent of the listener/join mapping. These owners can
manage the entire library and every playlist. Ordinary recipients are not owners.

Use `deploy/manage.compose.yaml` with the existing pilot Compose file. Set the
real owner's login in the deployment environment, for example (placeholder):

```sh
export MUSEEK_MANAGE_USERS='["owner@example.com"]'
docker compose -f elitedesk.compose.yaml -f manage.compose.yaml config --quiet
docker compose -f elitedesk.compose.yaml -f manage.compose.yaml up -d
```

Build/load the updated `museek:latest` image first. Preserve any other Compose
overlays already used by that installation. The overlay publishes only
`127.0.0.1:18082:8082`; uploads use the existing writable data volume, and the
source music mount stays read-only. Back up the SQLite database and data volume
before upgrading. The first startup transactionally migrates existing playlists,
order, IDs, grants and notes. Older server binaries do not support editing the
new membership model; restore the pre-upgrade backup if reverting.

Proxy that loopback port through a **private** Tailscale Serve listener, for
example on unused HTTPS port 10003:

```sh
tailscale serve --bg --https=10003 http://127.0.0.1:18082
```

Then open `https://HOST.TAILNET.ts.net:10003/manage/` on a device connected to the
tailnet. Permit this port in the tailnet ACLs if your policy restricts it. Use the
real host's existing DNS name. Check that 10003 is unused before adding it, and
preserve existing Serve/Funnel routes (including the iPhone join port 10002 and
public `/museek` route). Do not enable Funnel for the management port.

Every management request, including static assets, requires exactly one allowed
`Tailscale-User-Login`. Missing, duplicate, unknown, comma-combined or Funnel-marked
identities are rejected. The management socket trusts the local Serve ingress;
it must never be directly exposed to the LAN, tailnet, or internet. The normal
public API never mounts `/manage/`, even with spoofed identity headers. CSRF
tokens, same-origin forms, HTML escaping and a restrictive CSP protect edits.

Verify on the deployment:

1. Allowed owner: open `/manage/`, create a test playlist, upload an MP3, reorder,
   save notes, remove/re-add, and refresh the iPhone app.
2. Unlisted tailnet user: all management paths return 403.
3. Public/Funnel listener: `/manage/` returns 404, including with spoofed headers.
4. Restart and rescan: browser playlists, uploads, notes and saved order survive.

## Storage and compatibility

`tracks` is the shared song library. `playlist_entries` stores playlist membership
and order, and `track_notes` refers to that membership. A song can appear once per
playlist with independent notes in each playlist. Existing folder copies retain
their original IDs and remain separate library records; the migration does not
merge copies or move source files. New browser uploads live under `data/uploads/`,
not the read-only music directory. Back up this directory with the database.

Folder scanning still discovers new MP3s and appends them to their folder's
playlist. Rescanning metadata does not reset manual order or restore removed
entries. Deleting/renaming a source MP3 outside Museek removes that library song
and all its playlist entries, as the audio is no longer available. Browser-created
playlists and uploaded songs are excluded from filesystem deletion cleanup.

## Technology choice

[TanStack Start](https://tanstack.com/start/latest) provides React/Solid routing,
SSR and server functions. [SvelteKit adapters](https://svelte.dev/docs/kit/adapters)
support Node and static deployments. Both are reasonable for a larger web app.
For this small owner tool, the existing Go HTTP server and `html/template` provide
all needed behavior with fewer dependencies and a single deployment artifact.
The form-first approach also keeps the interface usable in mobile Safari without
requiring a touch drag-and-drop library.

## Checks

```sh
cd server
go test -race ./...
go vet ./...
```

Regression tests cover migration/reopening, independent notes and membership,
rescanning after removals/reorders, public and owner authorization boundaries,
CSRF, upload validation and atomic batch failure, upload deduplication, streaming,
and the authenticated playlist API consumed by the existing iPhone app.

## Pilot deployment, November 10, 2026

Live URL: **https://elitedesk-1.tail6900fe.ts.net:10003/manage/** (tailnet only).
Owner access uses the operator's verified Tailscale login. The host runs
`museek:web-manager-20261110` with `compose.yaml` and `manage.compose.yaml` under
`/home/justin/museek`. The old image is retained as
`museek:pre-web-manager-20261110`; `museek:latest` also points to the new image.

A stopped-service snapshot of the entire data volume is stored at
`/home/justin/museek/backups/data.pre-web-20261110.tgz`, alongside the previous
Compose file and Serve configuration. The backup directory is owner-only and the
archive is mode 0600. The initial migration and scan retained the existing
17-song playlist. All previous Serve/Funnel routes were preserved.

Verification: tailnet owner GET returned 200, a same-origin authenticated form
probe reached action validation, missing/unknown/Funnel-marked management
identities returned 403, both public management probes returned 404, and the
public player health endpoint remained 200. The deployed manager rendered the
existing playlist in Chrome. Local browser checks covered creation, library
selection, reordering and notes; a 390px viewport fit without horizontal overflow.
Safari rendered the local interface; its native file-picker automation could not
complete the selection. MP3 uploads and streaming passed transport/store tests.
Physical iPhone Safari has not been exercised in this run.
