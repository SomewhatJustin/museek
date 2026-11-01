# Manual TestFlight CI

`.github/workflows/testflight.yml` runs only through **Actions → TestFlight → Run workflow**, selecting **main**. Other refs are skipped. Leave `upload` unchecked for the default unsigned simulator SDK build of the app and unit tests (`build-for-testing`). This compiles but does not execute tests, boot a simulator, sign, archive, or contact App Store Connect. It requires Xcode's simulator SDK, not an installed simulator runtime.

Check `upload` only when ready to publish. That invokes the existing `scripts/upload_testflight.sh`: tests on **iPhone 17 Pro**, Release archive, then export/upload with `app/ios/ExportOptions-TestFlight.plist`. A successful submission is not proof Apple has finished processing or made the build available to testers. Build version defaults to 1.0.0 and build number to the UTC minute; avoid duplicate builds within a minute and update the version when needed.

## Runner and environment prerequisites

- Dedicated trusted Apple Silicon Mac runner with labels `self-hosted`, `macOS`, `ARM64`, `museek`. The workflow does not install/register a runner.
- `/Applications/Xcode-27.2.0.app`, accepted license/first-launch components, and Homebrew `xcodegen` in `/opt/homebrew/bin`. `DEVELOPER_DIR` is explicit; system `xcode-select` is not changed.
- For uploads: an installed compatible iOS simulator runtime and an available **iPhone 17 Pro** simulator, as required by the existing upload script.
- Create GitHub environment **testflight**, restrict deployment branches to **main**, and enable required reviewers where available. Add environment secrets (repository secrets also resolve):
  - `ASC_KEY_ID`: App Store Connect API key ID.
  - `ASC_ISSUER_ID`: issuer UUID.
  - `ASC_PRIVATE_KEY`: complete raw multiline `.p8` private key, not base64 and not a filename.
- The API key needs appropriate App Store Connect access to upload this app and permission for any automatic provisioning operations needed.
- Apple Developer team **JSKJUMBXQ3**, bundle ID **app.museek.museekApp**, and a matching App Store Connect app must exist. Install a valid signing certificate **with private key** in the runner user's unlocked keychain and ensure valid provisioning is available (or authorized automatic provisioning). An API key alone does not establish that signing works.

**Signing and upload have not been verified.** Missing signing identities, profiles, App Store Connect authorization, or simulator runtime will block upload. Verify mode intentionally does not validate these prerequisites.

## Security and cleanup

This public repository has no pull-request or push trigger in this workflow. Keep the runner restricted to trusted workflows/repositories: other workflows on a shared persistent runner can compromise it. Review changes on main before approving deployment. Checkout credentials are not persisted and token permissions are limited to `contents: read`.

Secrets are provided only to the upload step. The private key is written under `RUNNER_TEMP` in a run/attempt-specific directory (directory mode 700, file mode 600), removed by a shell exit trap and an `always()` cleanup step. Hard power loss or forced runner termination can prevent both cleanups; clean stale temporary directories before reusing the machine. Do not enable shell tracing or log key contents. Archives/build outputs remain on the runner; no key or build artifacts are uploaded by this workflow.

Local static checks: `python3 -m unittest discover -s scripts/tests -v` and `bash -n scripts/{verify_ios,ci_testflight,upload_testflight}.sh`. With `actionlint` installed, run `actionlint -ignore 'label .* is unknown' .github/workflows/testflight.yml` (custom self-hosted label).
