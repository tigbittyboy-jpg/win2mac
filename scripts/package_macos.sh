#!/usr/bin/env bash
# Package Bridge's own app only. No Wine runtime or Windows binaries are included.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' 'Packaging requires macOS and full Xcode.' >&2; exit 1; }
bridge_output="${BRIDGE_PACKAGE_DIR:?Set BRIDGE_PACKAGE_DIR to an output directory outside the checkout.}"
mkdir -p "$bridge_output"
bridge_output="$(cd "$bridge_output" && pwd -P)"
bridge_checkout="$(pwd -P)"
case "$bridge_output/" in "$bridge_checkout/"*) printf '%s\n' 'Packaging outputs must be outside the checkout.' >&2; exit 1 ;; esac
bridge_derived="$bridge_output/DerivedData"

xcodebuild -project Bridge.xcodeproj -scheme Bridge -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$bridge_derived" \
    ARCHS=arm64 CODE_SIGN_IDENTITY=- build
bridge_app="$bridge_derived/Build/Products/Release/Bridge.app"
[[ -d "$bridge_app" ]] || { printf '%s\n' 'Bridge.app was not produced.' >&2; exit 1; }

# Ad hoc signing preserves bundle integrity; it is not Developer ID notarization.
codesign --verify --deep --strict --verbose=2 "$bridge_app"
lipo "$bridge_app/Contents/MacOS/Bridge" -verify_arch arm64
bridge_links="$bridge_output/linked-libraries.txt"
otool -L "$bridge_app/Contents/MacOS/Bridge" > "$bridge_links"
cat "$bridge_links"
if grep -q 'BridgeCore' "$bridge_links"; then
    printf '%s\n' 'BridgeCore must be statically linked; a runtime dependency would reintroduce the preview signing crash.' >&2
    exit 1
fi
[[ ! -d "$bridge_app/Contents/Frameworks/BridgeCore.framework" ]] || {
    printf '%s\n' 'Unexpected embedded BridgeCore framework.' >&2; exit 1;
}
otool -l "$bridge_app/Contents/MacOS/Bridge" > "$bridge_output/load-commands.txt"
if grep -Eq '/Users/runner/|/DerivedData/' "$bridge_output/load-commands.txt"; then
    printf '%s\n' 'App load commands must not depend on a builder directory.' >&2; exit 1
fi

# Confirm native process startup, then exercise the actual window after ZIP extraction.
# This executes only the app built from this checkout, never a Wine runtime/EXE.
"$bridge_app/Contents/MacOS/Bridge" --bridge-self-check
ditto -c -k --sequesterRsrc --keepParent "$bridge_app" "$bridge_output/Bridge-macOS-arm64.zip"
bridge_extracted="$(mktemp -d "$bridge_output/extracted.XXXXXX")"
ditto -x -k "$bridge_output/Bridge-macOS-arm64.zip" "$bridge_extracted"
codesign --verify --deep --strict --verbose=2 "$bridge_extracted/Bridge.app"
python3 scripts/verify_macos_launch.py "$bridge_extracted/Bridge.app" "$bridge_extracted/startup.json"
(cd "$bridge_output" && shasum -a 256 Bridge-macOS-arm64.zip > SHA256SUMS.txt)
printf '%s\n' "Packaged $bridge_output/Bridge-macOS-arm64.zip"
