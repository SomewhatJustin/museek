# Museek for iPhone

Museek is a fully native SwiftUI client for the private Museek music server. It uses AVFoundation for playback, MediaPlayer for lock-screen controls, Keychain for the device session, and the application-support directory for downloaded originals.

Open `Museek.xcodeproj` in Xcode, or build from the command line:

```sh
xcodegen generate
xcodebuild -project Museek.xcodeproj -scheme Museek -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The checked-in Xcode project is generated from `project.yml`. Run `xcodegen generate` after changing the project definition. The server address must use HTTPS except for loopback development addresses.

## Simulator regression tests

Run the whole native scheme on an installed simulator (leave simulator ad-hoc
signing enabled: an unsigned app cannot exercise the real Keychain session):

```sh
DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer \
xcodebuild -project Museek.xcodeproj -scheme Museek \
  -destination 'platform=iOS Simulator,id=2C05187E-A047-4252-9590-5C3BE6B8AD56' \
  -derivedDataPath "$HOME/museek-join-review-signed" \
  -resultBundlePath "$HOME/museek-join-review-final.xcresult" test
```

`TailnetUITests.testSuccessfulJoinPersistsSessionAndRestoresLibraryAfterRelaunch`
waits on discovery without joining, taps Join, loads an authenticated collection,
checks the listener/server, terminates the app, and relaunches against a fixture
that refuses discovery/join and serves a different authenticated collection.
This exercises the real `TailnetDiscovery`, `APIClient` decoding/authorization,
`AppModel`, Keychain save/load, and library UI—not a pre-seeded session or view.

The UI tests select a deterministic URLProtocol transport using DEBUG-only
`MUSEEK_UI_TEST_SCENARIO` (`success`, `restore`, `unauthorized`, `notFound`).
Unexpected requests fail closed, with no live network fallback. The tests use a
separate Keychain service; `MUSEEK_UI_TEST_RESET_SESSION=1` clears only that service
on the first launch, and is deliberately removed for the restore launch. All
fixture hooks are compiled out of Release builds.
