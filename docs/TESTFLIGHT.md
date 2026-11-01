# TestFlight CI

Every push to **main** runs `.github/workflows/testflight.yml` on **macbook-m1-ci**: simulator tests, a signed Release archive, and an App Store Connect upload. Uploads are serialized and are not cancelled by subsequent pushes.

For a manual run, choose **Actions → TestFlight → Run workflow → main**. Other refs are skipped. Leave `upload` unchecked for an unsigned simulator SDK build of the app and unit tests (`build-for-testing`). This compiles tests without running them or contacting App Store Connect, and requires Xcode's simulator SDK rather than an installed simulator runtime.

Check `upload` to invoke `scripts/ci_testflight.sh`: tests on **iPhone 17 Pro**, Release archive, manual distribution export with `app/ios/ExportOptions-CI.plist`, then upload through `altool --upload-package --wait`. The workflow waits for Apple processing rather than treating an accepted upload as a finished build. CI uses Xcode 27.2's upload tool and a local distribution identity, without an interactive Apple login or cloud signing. Local runs of `scripts/upload_testflight.sh` retain Xcode's account-based export/upload using `app/ios/ExportOptions-TestFlight.plist`.

Build version defaults to `1.0.0` and build number to the UTC timestamp including seconds. `BUILD_NAME`, `BUILD_NUMBER`, and `SIMULATOR_DESTINATION` can override the script defaults. The script rejects any Apple team other than `JSKJUMBXQ3` before building or contacting Apple. Museek's target is iPhone-only; it does not declare iPad multitasking support.

## Runner and environment prerequisites

- Dedicated Apple Silicon Mac runner **macbook-m1-ci**, registered with labels `self-hosted`, `macOS`, `ARM64`, `museek`. It runs as user `ci` through a LaunchAgent and must remain logged in and awake.
- `/Applications/Xcode-27.2.0.app`, accepted license/first-launch components, and Homebrew `xcodegen` in `/opt/homebrew/bin`. `DEVELOPER_DIR` is explicit; system `xcode-select` is not changed.
- For uploads: iOS **26.2** simulator runtime (build `23C54`) and an available **iPhone 17 Pro** simulator. Xcode 27.2 supplies the build SDK; the tests run on the installed iOS 26.2 runtime.
- Dedicated default signing keychain at `~/Library/Keychains/museek-ci.keychain-db`, included in the user keychain search list. Its random password is stored only on the runner at `~/.config/museek-ci/keychain-password` with mode `600`, outside the repository and runner workspace. Each release unlocks it; cleanup locks it again.
- GitHub environment **testflight** is configured to allow deployment only from **main**. Add environment secrets (repository secrets also resolve):
  - `ASC_KEY_ID`: App Store Connect API key ID.
  - `ASC_ISSUER_ID`: issuer UUID.
  - `ASC_PRIVATE_KEY`: complete raw multiline `.p8` private key, not base64 and not a filename.
- The API key needs appropriate App Store Connect access to upload this app and permission for any automatic provisioning operations needed.
- Apple Developer team **JSKJUMBXQ3**, bundle ID **app.museek.museekApp**, App Store Connect app **6804269481** (Museek Mixtape Player). Install a valid signing certificate **with private key** in the dedicated keychain and ensure valid provisioning is available (or authorized automatic provisioning). Apple agreements must be current. An API key alone does not establish that signing works.

The release workflow and export options explicitly select Justin Fowler's personal team `JSKJUMBXQ3`. Use only that team's API credentials and signing assets for this runner; do not use the FUTO account.

The runner has dedicated development and Apple Distribution identities issued through the personal team's Museek CI API key, expiring November 1, 2027. Their private keys live in the dedicated signing keychain, with codesign access configured for unattended use. Apple's WWDR G3 intermediate certificate is installed in that keychain. The app-specific **Museek CI App Store** provisioning profile is installed under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and used for CI exports. Renew signing assets and the profile before expiry; do not revoke certificates used by other Macs.

**Signing and upload have not been verified.** Missing signing identities, profiles, App Store Connect authorization, or simulator runtime will block upload. Verify mode intentionally does not validate these prerequisites.

## Security and cleanup

This public repository's release workflow accepts only pushes to main and manual runs from main; it has no pull-request trigger. Keep write access and other workflows on the persistent runner limited to trusted maintainers. Checkout credentials are not persisted and token permissions are limited to `contents: read`.

Secrets are provided only to the upload step. The private key is written under `RUNNER_TEMP` in a run/attempt-specific directory (directory mode 700, file mode 600), removed by a shell exit trap and an `always()` cleanup step. Hard power loss or forced runner termination can prevent both cleanups; clean stale temporary directories before reusing the machine. Do not enable shell tracing or log key contents. Archives/build outputs remain on the runner; no key or build artifacts are uploaded by this workflow.

Local static checks: `python3 -m unittest discover -s scripts/tests -v` and `bash -n scripts/{verify_ios,ci_testflight,upload_testflight}.sh`. With `actionlint` installed, run `actionlint -ignore 'label .* is unknown' .github/workflows/testflight.yml` (custom self-hosted label).
