# Bridge project conventions

Phase 1 only: native macOS 14+ SwiftUI frontend, Swift 6 backend, user-installed Wine engines. Do not bundle Wine, D3DMetal, CrossOver, runtime downloads, or game content. Do not implement Windows APIs or CPU emulation.

- Use the existing checkout. Cloud tasks are already isolated; do not create worktrees unless asked.
- Keep backend code in `Sources/BridgeCore`, UI in `Sources/BridgeApp`, and XCTest cases in `Tests/BridgeCoreTests`.
- Use protocols and constructor injection. Backend types must compile on Linux; guard macOS-specific APIs. Swift 6 strict concurrency is required.
- Use `Process` with explicit absolute executable URLs and argument arrays, never a shell command for runtime/game execution.
- Discovery must not execute candidates. Require informed approval before probes, prefix initialization, or EXE execution. Do not remove quarantine, disable Gatekeeper, use sudo, or install Rosetta automatically.
- Keep prefixes, settings, logs, caches, and game files outside this checkout. Default user data: `~/Library/Application Support/Bridge`.
- Prefixes are organizational isolation, not security sandboxes. Never promise game compatibility from a successful version probe.
- Deletion requires a matching Bridge ownership record. Never recursively delete an arbitrary selected prefix.
- Cover behavior and error paths with injected process execution. Keep hardware-dependent tests separate from mocked tests.

## Commands

macOS: Xcode 16+ (Swift 6), Apple Silicon, macOS 14+:

```sh
bash scripts/run_macos.sh # builds, tests, then opens Bridge
swift test --jobs 4
xcodebuild -project Bridge.xcodeproj -scheme Bridge -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Bridge.xcodeproj -scheme Bridge -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
open Bridge.xcodeproj
```

Preview packages: `BRIDGE_PACKAGE_DIR=/absolute/path/outside/checkout bash scripts/package_macos.sh`. BridgeCore must remain statically linked; do not reintroduce an embedded ad hoc signed framework or disable library validation to resolve preview signing errors. Tag `v*` workflows test, ad hoc sign, verify architecture, and require a visible window/library load from an extracted ZIP through LaunchServices before publishing. Hosted verification covers macOS 14 and 26; package creation runs on 15. Never describe ad hoc signing as Developer ID trust or notarization. Shipping notarized builds requires a separate signing workflow and securely provided credentials.

Linux (backend validation only): `swift test --jobs 4`. SwiftUI is deliberately excluded from the Linux package graph. Linux success does not verify the macOS app, Rosetta, Metal, or Windows compatibility.

See `ARCHITECTURE.md`, `README.md`, and `docs/VALIDATION.md` before changing runtime or graphics integration.
