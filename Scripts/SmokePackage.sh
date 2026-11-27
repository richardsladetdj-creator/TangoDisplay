#!/usr/bin/env bash
# Zips the bundle the way a release ships it, then verifies and launches the extracted copy.
set -euo pipefail

bundle="${1:?Missing source bundle}"
zip="${2:?Missing output ZIP path}"
scripts_dir="$(cd "$(dirname "$0")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

ditto -c -k --sequesterRsrc --keepParent "$bundle" "$zip"
ditto -x -k "$zip" "$scratch"
unpacked="$scratch/TangoDisplay.app"
bash "$scripts_dir/VerifyBundle.sh" "$unpacked"
"$unpacked/Contents/MacOS/TangoDisplay" --bundle-smoke-test
