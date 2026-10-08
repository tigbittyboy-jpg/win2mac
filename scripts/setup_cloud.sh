#!/usr/bin/env bash
# Linux backend toolchain only. Never installs or executes Wine/Windows software.
set -euo pipefail
bridge_tools=/workspace/toolchains
bridge_release=swift-6.0.3-RELEASE-ubuntu24.04
bridge_swift="$bridge_tools/$bridge_release/usr/bin/swift"
bridge_archive=/tmp/bridge-swift.tar.gz
bridge_signature=/tmp/bridge-swift.tar.gz.sig
bridge_keys=/tmp/bridge-swift-keys.asc
bridge_gpg=/tmp/bridge-gpg
bridge_sha=33e923609f6d89ee455af0a017ae4941ce16878c4940882cbf6a1656de294e8b
bridge_fingerprint=52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
bridge_base=https://download.swift.org/swift-6.0.3-release/ubuntu2404/swift-6.0.3-RELEASE
bridge_verified="$bridge_tools/.bridge-swift-6.0.3-verified"

[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
    printf '%s\n' 'This script prepares the x86_64 Linux backend workflow only.' >&2; exit 1;
}
for bridge_command in curl gpg sha256sum tar awk; do command -v "$bridge_command" >/dev/null; done
mkdir -p "$bridge_tools"
if [[ ! -x "$bridge_swift" || ! -f "$bridge_verified" ]]; then
    if [[ ! -f "$bridge_archive" ]]; then
        curl -fL --retry 2 --max-time 300 "$bridge_base/$bridge_release.tar.gz" -o "$bridge_archive"
    fi
    printf '%s  %s\n' "$bridge_sha" "$bridge_archive" | sha256sum --check --status
    curl -fL --retry 2 --max-time 60 "$bridge_base/$bridge_release.tar.gz.sig" -o "$bridge_signature"
    # Official Swift website repository; immutable revision, no keyserver trust guessing.
    curl -fL --retry 2 --max-time 60 \
        https://raw.githubusercontent.com/swiftlang/swift-org-website/c9b6d647ce3e30adbfe7e97f1c460d503adc6c0b/keys/all-keys.asc -o "$bridge_keys"
    mkdir -p "$bridge_gpg"; chmod 700 "$bridge_gpg"
    gpg --homedir "$bridge_gpg" --import "$bridge_keys"
    gpg --homedir "$bridge_gpg" --status-fd 1 --verify "$bridge_signature" "$bridge_archive" > /tmp/bridge-swift-signature-status
    awk -v expected="$bridge_fingerprint" '$2 == "VALIDSIG" && $3 == expected { valid=1 } END { exit !valid }' /tmp/bridge-swift-signature-status
    # The release key is now expired; the 2024 release signature was made in its validity period.
    # Both the pinned archive digest and the original publisher signature must match.
    # Reinstall from the verified archive if no verified-install marker exists.
    tar -xzf "$bridge_archive" -C "$bridge_tools"
    "$bridge_swift" --version
    printf '%s\n%s\n' "$bridge_sha" "$bridge_fingerprint" > "$bridge_verified"
fi
"$bridge_swift" --version
cd /workspace/win2mac
bash scripts/test_linux.sh
