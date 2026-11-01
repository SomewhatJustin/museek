#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
: "${ASC_KEY_ID:?Set the ASC_KEY_ID secret}"
: "${ASC_ISSUER_ID:?Set the ASC_ISSUER_ID secret}"
: "${ASC_PRIVATE_KEY:?Set the ASC_PRIVATE_KEY secret (raw p8 contents)}"
key_dir="$RUNNER_TEMP/museek-asc-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
cleanup() { rm -rf -- "$key_dir"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
mkdir -m 700 "$key_dir"
export ASC_KEY_PATH="$key_dir/AuthKey.p8"
printf '%s\n' "$ASC_PRIVATE_KEY" > "$ASC_KEY_PATH"
chmod 600 "$ASC_KEY_PATH"
unset ASC_PRIVATE_KEY
bash "$repo_root/scripts/upload_testflight.sh"
