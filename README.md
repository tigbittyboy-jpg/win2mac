# Bridge

A native SwiftUI Windows compatibility launcher for Apple Silicon Macs. **Phase 1 prototype**, licensed under MIT. Bridge delegates execution to a compatible, user-installed Wine engine. It does not implement Windows APIs, emulate a CPU, bundle a commercial engine, or promise universal game compatibility.

## Implemented

- Sidebar with Library, Runtimes, Bottles, and Diagnostics.
- Select/import a Windows x64 EXE without executing or copying it.
- Passive Wine path discovery, manual runtime selection, Mach-O architecture inspection, approved version probes.
- Configurable prefixes; approved bottle initialization; association with existing initialized prefixes; ownership-checked deletion.
- Persistent application, argument, runtime, and bottle records in versioned JSON.
- Approved launches through Foundation.Process, separate stdout/stderr, exit status, launch errors, cancellation, and bounded capture.
- Protocols and injected services; XCTest mocked execution and trusted system-process integration tests.
- Graphics capability descriptions and conservative runtime-default configuration; diagnostic path redaction.

## Download the preview app — no Xcode required

[Download Bridge-macOS-arm64.zip](https://github.com/tigbittyboy-jpg/win2mac/releases/download/v0.1.0-preview.9/Bridge-macOS-arm64.zip), extract it, and replace the old Bridge.app in Applications. The [preview release](https://github.com/tigbittyboy-jpg/win2mac/releases/tag/v0.1.0-preview.9) includes its checksum and release notes. Requires Apple Silicon and macOS 14+; a chosen Wine runtime can require a newer OS. Xcode is only required to build the source.

Preview.9 fixes preview.5's framework-signing startup crash. BridgeCore is statically linked, with hardened runtime and library validation enabled. Hosted macOS 14, 15, and 26 checks passed all 23 tests and opened freshly extracted app copies, requiring a visible window and library loading. The user's macOS 27 build and quarantined browser-download behavior remain to be confirmed; no real Wine/Windows compatibility test was run.

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

1. Install a Wine-compatible runtime from a provider you trust, following its current macOS/Apple Silicon documentation and license. Bridge neither installs nor downloads one. Do not assume an upstream Wine build can run Windows x64 games on ARM64.
2. In **Runtimes**, select the provider-documented Wine executable or supported wrapper. Discovery inspects common Homebrew/Wine paths only. If a wrapper's payload cannot be inferred, select its documented runtime architecture. Confirm provider-documented Windows x64 support, then **Save Runtime Settings**.
3. Optionally choose **Probe Version…**, review the executable, and approve. A Wine version response is not a game compatibility test. An x86_64-only engine on Apple Silicon needs Rosetta 2; follow [Apple's installation instructions](https://support.apple.com/en-us/102527) if necessary. Bridge does not install it.
4. In **Bottles**, choose the runtime, name, and absolute prefix path outside this source checkout. Choose **Create Bottle…** for a new directory, or **Use Existing Prefix…** for an initialized provider-compatible prefix. Creation invokes the selected executable with `wineboot -u`; wrappers must support that argument convention.
5. In **Library**, choose **Select EXE**, select an x64 Windows PE `.exe`, and associate the entry with a bottle. Enter launch arguments one per line and **Save Arguments** if needed. An installer is launched like any other EXE; after installation, add its installed EXE (typically inside the prefix's `drive_c`) separately.
6. Choose **Launch**, review the runtime, prefix, EXE, and arguments, and explicitly approve. Inspect **Process Output** for failures. A zero exit status only describes the immediate Wine process; it does not certify that a detached application or graphics backend worked.

Never approve software you do not trust. Wine prefixes are **not security sandboxes**; Windows software can access your macOS files and network with your permissions. Bridge does not remove quarantine, bypass Gatekeeper, or request administrator privileges. Each probe, initialization, and launch needs its own approval. Managed runtime downloads are deliberately absent; a future downloader must verify signatures and trusted checksums before any approved execution.

## User data and troubleshooting

The default library is `~/Library/Application Support/Bridge/library.json`; default bottle paths live in its sibling `Bottles` directory. EXEs are referenced in place, so moving them breaks their entries. No binaries, logs, or user data are stored in the source repository. The console is in memory, roughly bounded to 64 KiB; returned process results capture at most 1 MiB per stream.

- Missing/unsupported runtime: check architecture, x64 declaration, execute permission, provider startup environment, macOS version, and Rosetta. Runtime selection never grants execution permission or bypasses macOS security.
- Prefix initialization error: inspect output. Bridge retains a partial directory with `.bridge-bottle.json` rather than deleting data while Wine children may still run. Stop those processes through the provider's documented workflow before manually inspecting/removing the partial prefix. A completed but unsaved prefix can be associated as external; Phase 1 does not automatically recover its managed ownership.
- Prefix deletion: only Bridge-owned prefixes with a matching marker can be deleted. External prefixes can only be removed from the library. Removing a bottle clears application associations. Deletion is irreversible; back up game saves first. Bridge can track its own active launches, not every independently started Wine process.
- Stop: sends termination to the immediate child, then escalates to killing that child if it does not stop within two seconds. Wine servers/detached games may remain; use your runtime provider's documented shutdown procedure. Probes time out after 15 seconds and initialization after 120 seconds. Game launches have no fixed timeout.
- Library decode error: the file is preserved and editing is disabled. Back up the original before repairing JSON. Unknown schema versions are rejected. Persistence is atomic for one app instance; simultaneous Bridge instances are not supported in Phase 1.
- Diagnostics: paths are redacted where practical, but output can contain secrets or private documents. Review the report before copying/sharing. The inherited process environment is never included.

The frontend intentionally supports only the engine's existing graphics configuration. No WineD3D/DXVK/MoltenVK/D3DMetal libraries or DLL overrides are installed. Real 3D compatibility requires a legally obtained, correctly configured engine with the appropriate backend.

## Development environment and limits

Linux supports **backend compilation and tests only**. On this cloud workspace, the verified Swift toolchain is outside the checkout. Run:

```sh
bash scripts/test_linux.sh
```

This script uses writable external build/cache paths. On other Linux hosts, set `BRIDGE_SWIFT_BIN` to a Swift 6 `swift` executable if it is not on PATH. The Ubuntu 24.04 Swift 6.0.3 toolchain was validated on this Debian 13 cloud machine; that does not imply general distro support.

`.github/workflows/macos.yml` automatically builds the ARM64 app and runs macOS XCTest when code is pushed to `main` or a pull request is opened. Tests use the runner's host architecture; an Intel runner does not validate execution on Apple Silicon. The workflow does not launch Wine or Windows software.

See [ARCHITECTURE.md](ARCHITECTURE.md) for Apple Silicon execution requirements, security boundaries, graphics/license constraints, and sources. See [docs/VALIDATION.md](docs/VALIDATION.md) for actual check results and the hardware test checklist. 32-bit/ARM Windows programs, anti-cheat kernel drivers, arbitrary graphics backend installation, runtime downloads, automatic compatibility profiles, and automatic installer-library discovery are outside Phase 1.
