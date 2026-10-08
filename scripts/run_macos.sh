#!/usr/bin/env bash
# Build, test, and open the native app. Does not install or execute Wine/EXEs.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf '%s\n' 'Bridge needs an Apple Silicon Mac. This machine cannot run the macOS app.' >&2
    exit 1
fi
if ! command -v xcodebuild >/dev/null || ! xcodebuild -version >/dev/null 2>&1; then
    printf '%s\n' 'Install full Xcode 16 or later, open it once to finish setup, then run this command again.' >&2
    exit 1
fi
bridge_xcode_major="$(xcodebuild -version | awk '/^Xcode / { split($2, version, "."); print version[1] }')"
if [[ ! "$bridge_xcode_major" =~ ^[0-9]+$ || "$bridge_xcode_major" -lt 16 ]]; then
    printf '%s\n' 'Bridge requires Xcode 16 or later with Swift 6.' >&2
    exit 1
fi
bridge_derived="$HOME/Library/Caches/Bridge/DerivedData"
bridge_logs="$HOME/Library/Logs/Bridge"
mkdir -p "$bridge_logs"
printf '%s\n' 'Building Bridge and running its tests…'
xcodebuild -project Bridge.xcodeproj -scheme Bridge -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$bridge_derived" \
    CODE_SIGN_IDENTITY=- test 2>&1 | tee "$bridge_logs/build.log"
bridge_app="$bridge_derived/Build/Products/Debug/Bridge.app"
[[ -d "$bridge_app" ]] || { printf '%s\n' 'The build did not produce Bridge.app.' >&2; exit 1; }
printf '%s\n' 'Tests passed. Opening Bridge…'
open "$bridge_app"
