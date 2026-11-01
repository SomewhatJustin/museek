# Museek

Museek is a small, private music server and iPhone player. Put MP3s in a folder, invite a person, and they can listen without managing files.

The product boundary lives in [MVP.md](MVP.md), with current verification evidence in [ACCEPTANCE.md](ACCEPTANCE.md).

The family-pilot deployment is publicly available through Tailscale Funnel at `https://elitedesk-1.tail6900fe.ts.net/museek` over standard HTTPS port 443. Its checked-in Compose definition is `deploy/elitedesk.compose.yaml`. The original port `10002` remains available only inside the owner's Tailscale network.

To make MP3 copies of an AAC/FLAC folder while preserving the source files and metadata:

```sh
scripts/convert_music.sh SOURCE_DIRECTORY DESTINATION_DIRECTORY
```

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
