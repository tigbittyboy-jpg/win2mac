Bridge Phase 1 preview for Apple Silicon Macs running macOS 14 or later.

Download **Bridge-macOS-arm64.zip** under Assets, extract it, and move Bridge.app to Applications. You do not need Xcode to use this app. The archive contains Bridge only; select your compatible, user-installed Wine runtime inside the app to run Windows x64 software. A runtime may require newer macOS or Rosetta.

This preview is **ad hoc signed, not Developer ID signed or Apple-notarized**. macOS may block a downloaded preview. Bridge does not remove quarantine or disable Gatekeeper. If macOS offers no approved way to open it, use the source build with Xcode or wait for a notarized release. Managed/public notarized distribution is not available yet.

The release workflow runs macOS XCTest, builds the native ARM64 app, verifies its ad hoc bundle signatures, checks executable/framework architecture, and runs a headless app startup check before packaging. Those checks are not real Windows/game compatibility tests or an interactive UI test. No Windows executable or Wine runtime is downloaded or launched by the release workflow.

SHA256SUMS.txt records archive integrity. It is not a publisher signature or notarization certificate. The build source and workflow are public in this repository.

The app provides a persistent library, runtime selection, configurable Wine prefixes, per-operation execution approval, process output, and diagnostics. Wine prefixes are not security sandboxes: approved Windows software runs with your user permissions. 32-bit Windows programs, kernel drivers/anti-cheat, and automatic graphics-backend installation are outside this preview.
