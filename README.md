# Museek

Museek is a small, private music server and iPhone player. Put MP3s in a folder, invite a person, and they can listen without managing files.

The product boundary lives in [MVP.md](MVP.md), with current verification evidence in [ACCEPTANCE.md](ACCEPTANCE.md).

The family-pilot deployment is publicly available through Tailscale Funnel at `https://elitedesk-1.tail6900fe.ts.net/museek` over standard HTTPS port 443. Its checked-in Compose definition is `deploy/elitedesk.compose.yaml`. The original port `10002` remains available only inside the owner's Tailscale network.

To make MP3 copies of an AAC/FLAC folder while preserving the source files and metadata:

```sh
scripts/convert_music.sh SOURCE_DIRECTORY DESTINATION_DIRECTORY
```

## Optional Tailscale discovery and joining

The native SwiftUI app detects the known private server and offers **Join Museek**
only after an authorized response. Joining requires an explicit tap; manual
invitations remain available. The private join listener is **disabled by default**
and must never share the public Funnel upstream. See [docs/TAILNET.md](docs/TAILNET.md)
for identity mappings, the opt-in Compose overlay, trust boundaries and deployment
verification.

## Run the server

Requirements: Docker, a server reachable from the internet, a DNS name pointed at it, and inbound ports 80/443.

1. Make one folder per collection and put MP3s inside it:

   ```text
   /srv/museek/music/
     Bedtime Favorites/
       cover.jpg
       01 - Lullaby.mp3
     Road Trip/
       01 - First Song.mp3
   ```

2. Copy `deploy/.env.example` to `deploy/.env` and set the domain and absolute music path.
3. From `deploy`, start the service:

   ```sh
   docker compose up -d --build
   ```

4. Confirm the service is healthy:

   ```sh
   curl https://music.example.com/healthz
   ```

The music directory is mounted read-only. Museek scans it at startup and once per minute.

## Invite a listener

The invite command creates the recipient if needed, shares the named collection, and prints a shareable HTTPS invitation link plus a manual fallback code. The invitation can pair multiple devices for 24 hours:

```sh
docker compose exec museek /museek invite \
  --recipient "Listener" \
  --collection "Bedtime Favorites"
```

Send the `Invitation link` line. Tapping it opens Museek and pairs the device automatically. The pairing code is stored in the URL fragment, so browsers do not send it to the server or include it in server access logs. Treat the link like a temporary password: anyone who has it can pair a device until the link expires 24 hours after creation.

Additional owner commands:

```sh
docker compose exec museek /museek scan
docker compose exec museek /museek share --recipient "Listener" --collection "Road Trip"
docker compose exec museek /museek unshare --recipient "Listener" --collection "Road Trip"
docker compose exec museek /museek devices --recipient "Listener"
docker compose exec museek /museek revoke-device DEVICE_ID
```

The server address and pairing code remain available for manual entry if the link cannot open the installed app.

## Run the iPhone app

Pushes to `main` run the TestFlight test/archive/upload workflow on `macbook-m1-ci`. For setup and manual verification, see [TestFlight CI setup](docs/TESTFLIGHT.md).

Install Xcode and XcodeGen, then:

```sh
cd app
xcodegen generate
open Museek.xcodeproj
```

For a family pilot, distribute the build through TestFlight. TestFlight builds expire after 90 days; a normal App Store release is required for durable distribution.

After the app record exists in App Store Connect and Xcode is signed into an authorized Apple Developer account, build and upload a uniquely numbered release from this Mac with:

```sh
scripts/upload_testflight.sh
```

The script requires Justin Fowler's personal Apple team `JSKJUMBXQ3`. For unattended uploads, set `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH` to an App Store Connect API key for that personal team before running it.

The iOS app declares background audio mode so playback and system media controls continue while the screen is locked.

## Development checks

```sh
cd server
go test -race ./...

cd ../app
xcodegen generate
xcodebuild -project Museek.xcodeproj -scheme Museek -destination 'platform=iOS Simulator,name=Museek iPhone 17 Pro' test
xcodebuild -project Museek.xcodeproj -scheme Museek -destination 'generic/platform=iOS Simulator' build
```

The server API is documented in [api/openapi.yaml](api/openapi.yaml).

## Add playlist song notes

Notes belong to a **song entry in one collection**, with at most one optional note
per entry. Two copies of a song in different collection folders have independent
notes. Rescanning keeps notes for existing entries; deleting or renaming a song
removes its old entry and note. There are no global song notes.

Start the owner editor against the same music and data directories as the server:

```sh
museek notes --music /srv/museek/music --data /srv/museek/data
```

Open **http://127.0.0.1:8081**, choose a playlist, write a song's note, and
click **Save note**. Save an empty field to remove a note. Notes support plain
text and line breaks, up to 10,000 characters. Newly scanned playlists appear in
the editor after reload. Restart the editor to scan immediately if needed.

For the Linux family-pilot Docker deployment, use the optional owner editor:

```sh
cd deploy
docker compose -f elitedesk.compose.yaml -f notes.compose.yaml run --rm notes
```

From your Mac, forward its local port over SSH:

```sh
ssh -L 8081:127.0.0.1:8081 elitedesk-1
```

Then open http://127.0.0.1:8081 on your Mac. The editor binds only to the server's
loopback interface and is separate from the public/Funnel listener. Stop it with
Ctrl-C when finished.

In the iPhone collection view, pull to refresh to fetch edits. A note icon opens
an anchored popover without starting or changing music. Now Playing includes the
current queue entry's note. Downloaded collections retain the notes from their
download; remove and download again to update an offline copy.
