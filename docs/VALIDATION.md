# Phase 1 validation record

Implementation environment: x86_64 Linux, Debian 13; no Xcode, macOS SDK, Apple Silicon hardware, Wine runtime, or Windows software was available. No actual Windows EXE was executed and no Windows/game compatibility claim is made.

## Executed checks

- Swift 6.0.3 compilation of every BridgeCore source file with Swift 6 strict concurrency: **passed**.
- XCTest: **22 tests executed, 0 failures, 0 skips** using `bash scripts/test_linux.sh`. This includes injected Wine-process behavior and real trusted system-process checks. The separate Swift Testing runner's “0 tests” footer is not the XCTest result.
- Mocked execution covers permission refusal, explicit argument boundaries (including spaces/metacharacters), prefix environment, exit status, stream forwarding, launch failures, and release of bottle leases after failure.
- Runtime inspection covers Intel, ARM64, universal Mach-O CPU headers, symlinks, script wrappers, missing executables, Rosetta prerequisites, x64 declaration, version probes, and probe failure. Mach-O fixtures are header samples, not runnable engines.
- Prefix tests cover approved initialization, existing-prefix structure, enumeration, partial initialization failure, managed deletion, forged ownership rejection, external-prefix refusal, active leases, and source-repository exclusion.
- Persistence tests cover missing-file default, actual JSON round-trip across separate service instances, corrupt-store preservation on read/write, dangling associations, and overlapping prefixes.
- Graphics-default-only configuration and diagnostics path redaction: **passed**.
- Foundation.Process integration runs trusted `/bin/sh` and `/bin/sleep` with fixed test strings, no user interpolation. It verifies both pipes, exit 7, 162,000 bytes per stream without deadlock, UTF-8 split across reads, launch failure, timeout, and cancellation. No shell is used by Wine/game launch services.
- SwiftUI source syntax parsing with Swift 6: **passed**. This is not SDK type checking or a macOS build.
- Committed Xcode project's OpenStep syntax parsed with `openstep-parser` 2.0.3; all object references, Swift source target memberships, and shared scheme target IDs checked: **passed**. The parser was installed outside the repository for validation and is not an app dependency.
- Shell script syntax and the cloud setup/test workflow: verified on the current cloud instance. The toolchain's pinned SHA-256 matches and its original Swift publisher signature verifies against the official website's release key. That key is now expired; the signature was produced in December 2024 during its validity period. No verification was disabled.

## Not executed — required before claiming the macOS prototype is validated

1. On an Apple Silicon Mac with Xcode 16+ and macOS 14+, run the README's Xcode build/test commands and launch the Bridge scheme. Confirm SwiftUI type checking, framework embedding, app activation, and ad hoc signing. Linux cannot validate these.
   `bash scripts/run_macos.sh` performs the local build/tests and opens the app. Its shell syntax and Linux refusal were checked here; its macOS success path remains unexecuted. The macOS CI workflow is included as source but has not been run or published to GitHub; it builds ARM64 and runs tests on the runner's host architecture, without Windows compatibility tests.
2. Test sidebar, EXE/runtime panels, argument editing, per-operation approval/cancel behavior, console streaming, nonzero-exit alerts, and restart persistence. Check file permissions and a deliberately corrupt library without losing the original.
3. Use a legally obtained provider-supported x64 Wine runtime. Record vendor, full version, binary/wrapper architecture, minimum OS, Rosetta state, and existing graphics configuration. Verify its documented wrapper argument behavior and whether additional environment setup is required. An arbitrary engine's private internal binary may need an adapter.
4. Approve a version probe, initialize a new prefix, and confirm `drive_c`/`system.reg`. Associate a valid existing prefix. Confirm external prefixes cannot be deleted and active Bridge operations block deletion. Close detached Wine processes before deleting a managed prefix.
5. Launch a trusted, known-compatible x64 Windows diagnostic EXE and installer, approve each, capture separate streams and exit status, then import the installed EXE. Record actual application behavior separately from the Wine process exit status.
6. Test an Intel-only runtime with and without Rosetta, a provider-supported native/wrapper runtime, unsupported 32-bit/ARM PE files, moved EXEs, missing runtime paths, non-ASCII/spaced paths, missing prefixes, and app relaunch.
7. Check macOS quarantine/Gatekeeper behavior without disabling protections. Confirm diagnostics redaction manually. Inspect inherited runtime environment needs without logging secret values.
8. Only claim graphics compatibility after exercising the specific runtime/backend/game combination on real hardware. Record rendering correctness and unsupported APIs. No graphics backend is installed or certified by Phase 1.

## Known Phase 1 limits

The app allows one Bridge operation at a time; no cross-instance locking or external Wine process monitoring. Stop/timeout act on the immediate Wine child, with a two-second kill fallback; detached games/wineserver can survive, and their output is no longer captured once the primary exits. Bridge cannot establish that a prefix is idle with respect to processes started elsewhere. Ownership markers prevent accidental deletion, not attacks by software already running as the user. User-installed binaries are not hash-pinned and can change after approval.

Prefix configuration is descriptive, with runtime-default graphics only. Creation uses `wine wineboot -u` and `WINEARCH=win64`; only runtimes/wrappers supporting that convention can create bottles. External prefixes must already be compatible with the selected engine. There is no prefix migration, installer app discovery, runtime downloading, compatibility-profile database, updater, code-signature UI, security sandbox, or automatic recovery of partial/unsaved managed prefixes. Library entries use paths rather than persistent file bookmarks; moving binaries requires reimport. Public signed/notarized distribution remains future work.

The researched Wine/DXVK/MoltenVK upstream docs are linked in `ARCHITECTURE.md`. Apple and CodeWeavers pages were inaccessible through this cloud egress policy, so provider/Apple details and current license terms need target-machine review. Cloud draft persistence and successful tests are not publication or successful restoration in a fresh task.
