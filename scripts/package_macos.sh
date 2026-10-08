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
lipo -verify_arch arm64 "$bridge_app/Contents/MacOS/Bridge"
lipo -verify_arch arm64 "$bridge_app/Contents/Frameworks/BridgeCore.framework/BridgeCore"
otool -L "$bridge_app/Contents/MacOS/Bridge"

# Confirm framework loading and native process startup without an interactive GUI.
# This executes only the app built from this checkout, never a Wine runtime/EXE.
"$bridge_app/Contents/MacOS/Bridge" --bridge-self-check
ditto -c -k --sequesterRsrc --keepParent "$bridge_app" "$bridge_output/Bridge-macOS-arm64.zip"
(cd "$bridge_output" && shasum -a 256 Bridge-macOS-arm64.zip > SHA256SUMS.txt)
printf '%s\n' "Packaged $bridge_output/Bridge-macOS-arm64.zip"
