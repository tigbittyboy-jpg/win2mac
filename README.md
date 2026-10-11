# Bridge

A native SwiftUI Windows compatibility launcher for Apple Silicon Macs. **Integrated preview**, licensed under MIT. Bridge delegates execution to a compatible, user-installed Wine engine. It does not implement Windows APIs, emulate a CPU, bundle a commercial engine, or promise universal game compatibility.

## Implemented

Home, a searchable grid/list library, Compatibility setup, and advanced Settings. Bridge inspects Windows PE architecture, selects a configured compatible Wine engine and prepares a dedicated environment with your approval. Favorites, custom names/icons, launch settings/history and existing bottles survive updates. Detailed logs and evidence-based errors help troubleshooting; owned environments can be repaired without deleting installed files.

Supports provider-confirmed Windows x64 and x86/WoW64 execution. ARM64/ARM64EC files are detected but require unsupported dedicated engines. Wine, Rosetta and graphics translation come from your installed provider. See [overhaul features and limitations](docs/OVERHAUL_STATUS.md).

## Download the preview app — no Xcode required

[Download Bridge-macOS-arm64.zip](https://github.com/tigbittyboy-jpg/win2mac/releases/download/v0.2.0-preview.4/Bridge-macOS-arm64.zip), extract it, and replace the old Bridge.app in Applications. The [preview release](https://github.com/tigbittyboy-jpg/win2mac/releases/tag/v0.2.0-preview.4) includes its checksum and release notes. Requires Apple Silicon and macOS 14+; a chosen Wine runtime can require a newer OS. Xcode is only required to build the source.

The 0.2 preview adds the redesigned library, guided engine setup, automatic approved environment preparation, saved launch logs and safe environment repair. Existing application entries and CARL's graphics settings are retained. Advanced DXVK import/restoration is under Settings → Environments; see [DXVK setup](docs/DXVK_SETUP.md). BridgeCore remains statically linked to avoid the earlier framework-signing startup failure. Hosted macOS 14, 15 and 26 build/test and extracted-app startup checks passed. Real Wine/game compatibility and the user's macOS 27 installation still require target-machine testing.

The preview is ad hoc signed and **not Apple-notarized**; macOS may block a downloaded preview. Bridge does not remove quarantine or disable Gatekeeper. Use a source build or wait for notarized distribution if macOS does not allow you to open it. See the release notes for signing details. No Wine engine is bundled; select a compatible installed runtime inside Bridge.

## Build from source on a Mac

Use an Apple Silicon Mac with macOS 14+ and **Xcode 16 or later with Swift 6**. Your chosen runtime can require a newer OS. No Swift packages or proprietary engines are downloaded by the app.

To build, run the tests, and open Bridge in one command from this checkout:

```sh
bash scripts/run_macos.sh
```

If you do not have the project on your Mac yet, download it first:

```sh
git clone https://github.com/tigbittyboy-jpg/win2mac.git
cd win2mac
bash scripts/run_macos.sh
```

No code or configuration review is needed to run it. The script checks the Mac/Xcode prerequisites and stops if the build or tests fail. Build products stay in `~/Library/Caches/Bridge/DerivedData`; the build log is `~/Library/Logs/Bridge/build.log`. Wine/EXE execution remains a separate, explicitly approved action inside Bridge.

For IDE development:

```sh
cd /path/to/win2mac
open Bridge.xcodeproj
```

Select the **Bridge** scheme and **My Mac**, then Run (⌘R). The project builds an ARM64 frontend and uses ad hoc signing for local development; it has no App Sandbox entitlement. Public distribution needs appropriate signing/notarization and further security review.

CLI verification on the Mac:

```sh
swift test --jobs 4
xcodebuild -project Bridge.xcodeproj -scheme Bridge -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Bridge.xcodeproj -scheme Bridge -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

`swift run Bridge` is also available on macOS for development, but Xcode provides the normal `.app` launch workflow. The committed Xcode project has Bridge, BridgeCore, and BridgeCoreTests targets and a shared scheme. To update file membership after adding Swift files, run `python3 scripts/generate_xcode_project.py`; it replaces the generated project and scheme, so keep custom project changes in the generator.

## First launch

1. Open **Compatibility**. Choose your installed Wine command-line engine or scan installed paths. Confirm only the Windows capabilities documented by its provider, then **Save Runtime Settings**.
2. Choose **Probe Version…** and approve the command. Bridge checks the engine's host architecture and Rosetta prerequisite. A Wine version response does not establish game compatibility.
3. Open **Home → Run Windows App**, or drop an EXE into the window. Bridge inspects it without executing it and adds it to Library.
4. Press **Play**. For a new app, Bridge chooses a compatible configured engine and offers to prepare a separate environment and launch it. Review and approve only software you trust.
5. Per-game arguments, graphics and environment selection live under its **Settings** button. Existing CARL settings stay associated with CARL. A configured app can remember approval for unchanged direct EXE/engine bytes and settings, enabling subsequent one-click launching.

Mark an ambiguous installer in Application Settings before running it. After setup, choose an installed launch target from the detected candidates or add its EXE manually. Technical engine and bottle controls are under **Settings → Engines / Environments**; the optional console is in the toolbar.

Never approve software you do not trust. Wine environments are **not security sandboxes**; Windows software can access macOS files and the network with your permissions. Bridge never removes quarantine, bypasses Gatekeeper or installs system software. Probes, new preparation, repairs and graphics imports require approval. No engines or dependency DLLs are downloaded.

## User data and troubleshooting

Existing `~/Library/Application Support/Bridge/library.json` IDs and associations are retained. Environments live in `Bottles`; complete streamed output is saved in private `Logs` files. The optional UI console remains bounded to 64 KiB, and returned results to 1 MiB per stream. Logs can contain sensitive unredacted output; exported diagnostics redact paths heuristically. Data stays outside the source tree.

- **Missing engine:** use Compatibility to check its executable, documented Windows support, host architecture and Rosetta requirement.
- **Initialization failure:** data is retained. Bridge waits for Wine's background registry writes; use approval-gated Repair for an owned environment or associate a completed prefix in Settings → Environments. Recovery retains a matching ownership record.
- **Application stopped unexpectedly:** open its Launch Log. Exit 3 alone does not identify missing dependencies; exit 0 does not prove the game works. Bridge does not repeatedly restart a failing app.
- **Library load failure:** the original JSON is preserved and editing disabled. Back it up before manual repair. Future schema versions are rejected. Simultaneous app instances are not supported.
- **Removal:** removing a library entry leaves installed files and environments intact. Environment deletion is separate, explicitly confirmed and requires a matching ownership marker.
- **Stop:** terminates the immediate Wine child, with a two-second kill fallback. Detached Windows processes can remain; follow the provider's shutdown instructions. Probes time out after 15 seconds and wineboot after 120 seconds; ordinary game launches have no fixed timeout.

Existing runtime-default, experimental WineD3D Vulkan and approved manual x64 DXVK import/restoration remain available. [DXVK setup](docs/DXVK_SETUP.md) explains the package layout, backups and graphics limits. Bridge does not provide arbitrary DirectX translation or certify rendering. See [graphics troubleshooting](docs/GRAPHICS_TROUBLESHOOTING.md).

## Development environment and limits

Linux supports **backend compilation and tests only**. On this cloud workspace, the verified Swift toolchain is outside the checkout. Run:

```sh
bash scripts/test_linux.sh
```

This script uses writable external build/cache paths. On other Linux hosts, set `BRIDGE_SWIFT_BIN` to a Swift 6 `swift` executable if it is not on PATH. The Ubuntu 24.04 Swift 6.0.3 toolchain was validated on this Debian 13 cloud machine; that does not imply general distro support.

`.github/workflows/macos.yml` automatically builds the ARM64 app and runs macOS XCTest when code is pushed to `main` or a pull request is opened. Tests use the runner's host architecture; an Intel runner does not validate execution on Apple Silicon. The workflow does not launch Wine or Windows software.

See [ARCHITECTURE.md](ARCHITECTURE.md) for Apple Silicon execution requirements, security boundaries, graphics/license constraints, and sources. See [docs/VALIDATION.md](docs/VALIDATION.md) for actual check results and the hardware test checklist. Windows ARM execution, kernel drivers/anti-cheat, proprietary engine adapters and automatic dependency installation remain unavailable. See [overhaul status](docs/OVERHAUL_STATUS.md) for exact boundaries.

### 32-bit Windows games

Bridge can import x86 PE32 EXEs. In **Compatibility**, select a provider-supported Wine engine, confirm **Windows x86 (32-bit/WoW64) execution on this Mac**, then **Save Runtime Settings**. The existing x64 capability/host checks still apply because bottles remain win64. Use a separate bottle with **Runtime Default** graphics for x86 games. Bridge’s DXVK importer remains x64-only; keep CARL’s DXVK bottle intact. Leave game arguments empty unless required by that game—CARL’s Unity flags are not general Wine settings.

This enables a runtime-dependent launch attempt, not guaranteed game compatibility. A version probe cannot establish WoW64 or DirectX 9 support. See [32-bit setup](docs/X86_SETUP.md).
