#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
cd "$repo_root/app"
xcodegen generate
# Compile app and tests for the SDK, without booting an installed simulator.
xcodebuild -project Museek.xcodeproj -scheme Museek \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$RUNNER_TEMP/museek-verify" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build-for-testing
