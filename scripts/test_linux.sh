#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

bridge_swift_bin="${BRIDGE_SWIFT_BIN:-/workspace/toolchains/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swift}"
if [[ ! -x "$bridge_swift_bin" ]]; then bridge_swift_bin="$(command -v swift)"; fi
bridge_cache_root="${BRIDGE_BUILD_ROOT:-/tmp/bridge-development}"
mkdir -p "$bridge_cache_root"/{modules,cache,config,security}
export SWIFTPM_MODULECACHE_OVERRIDE="$bridge_cache_root/modules"
export CLANG_MODULE_CACHE_PATH="$bridge_cache_root/modules"
"$bridge_swift_bin" test --jobs 4 --scratch-path "$bridge_cache_root/build" \
    --cache-path "$bridge_cache_root/cache" --config-path "$bridge_cache_root/config" \
    --security-path "$bridge_cache_root/security"
