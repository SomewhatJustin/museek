#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
app_dir="$repo_root/app"
export_options="$app_dir/ios/ExportOptions-TestFlight.plist"
build_name="${BUILD_NAME:-1.0.0}"
build_number="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
simulator_destination="${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
apple_team_id="${APPLE_TEAM_ID:-JSKJUMBXQ3}"
archive_path="$app_dir/build/ios/archive/Museek-$build_number.xcarchive"

for command_name in xcodegen xcodebuild plutil
do
  if ! command -v "$command_name" >/dev/null 2>&1
  then
    echo "$command_name is required." >&2
    exit 1
  fi
done

plutil -lint "$export_options" >/dev/null

cd "$app_dir"
xcodegen generate
xcodebuild -project Museek.xcodeproj -scheme Museek -destination "$simulator_destination" test

authentication_args=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" || -n "${ASC_KEY_PATH:-}" ]]
then
  if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" || -z "${ASC_KEY_PATH:-}" ]]
  then
    echo "ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH must be set together." >&2
    exit 1
  fi
  if [[ ! -f "$ASC_KEY_PATH" ]]
  then
    echo "App Store Connect key not found at $ASC_KEY_PATH." >&2
    exit 1
  fi
  authentication_args+=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

xcodebuild \
  -project "$app_dir/Museek.xcodeproj" \
  -scheme Museek \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  "${authentication_args[@]}" \
  DEVELOPMENT_TEAM="$apple_team_id" \
  MARKETING_VERSION="$build_name" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_STYLE=Automatic \
  archive

upload_output="$(mktemp -d "${TMPDIR:-/tmp}/museek-testflight.XXXXXX")"
xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$upload_output" \
  -exportOptionsPlist "$export_options" \
  "${authentication_args[@]}"

echo "Museek $build_name ($build_number) was submitted to App Store Connect using team $apple_team_id."
