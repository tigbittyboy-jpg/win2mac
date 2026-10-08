Bridge Phase 1 preview for Apple Silicon Macs running macOS 14 or later.

Bottle setup now includes runtime scanning, executable selection, architecture/x64 configuration, and a clear empty state with installation links. Known installed Wine paths are inspected automatically at startup without execution. The Create Bottle action stays disabled until a runtime is selected and its compatibility settings are saved. Bridge still requires a separately installed Wine runtime; see [runtime setup](https://github.com/tigbittyboy-jpg/win2mac/blob/main/docs/RUNTIME_SETUP.md).

Download **Bridge-macOS-arm64.zip** under Assets, extract it, and move Bridge.app to Applications. You do not need Xcode to use this app. The archive contains Bridge only; select your compatible, user-installed Wine runtime inside the app to run Windows x64 software. A runtime may require newer macOS or Rosetta.

This preview is **ad hoc signed, not Developer ID signed or Apple-notarized**. macOS may block a downloaded preview. Bridge does not remove quarantine or disable Gatekeeper. If macOS offers no approved way to open it, use the source build with Xcode or wait for a notarized release. Managed/public notarized distribution is not available yet.

This update fixes preview.5's startup crash: macOS rejected the embedded BridgeCore framework because of a signing Team ID mismatch. BridgeCore is now linked directly into the app. Hardened runtime and library validation remain enabled.

Managed-prefix ownership checks also handle Foundation's directory URL hints consistently, while rejecting markers for another prefix or bottle.

The release workflow requires macOS XCTest, ARM64 Release compilation, signature/architecture checks, and opening a freshly extracted ZIP copy through LaunchServices. A smoke test requires a visible SwiftUI window and successful library loading before publication. Verification runs on macOS 14 and 26; packaging also runs on macOS 15. The reported macOS 27 system is not available on these hosted runners. These checks do not exercise file panels, real Windows/game compatibility, or a quarantined browser download. No Windows executable or Wine runtime is downloaded or launched by the release workflow.

SHA256SUMS.txt records archive integrity. It is not a publisher signature or notarization certificate. The build source and workflow are public in this repository.

The app provides a persistent library, runtime selection, configurable Wine prefixes, per-operation execution approval, process output, and diagnostics. Wine prefixes are not security sandboxes: approved Windows software runs with your user permissions. 32-bit Windows programs, kernel drivers/anti-cheat, and automatic graphics-backend installation are outside this preview.
