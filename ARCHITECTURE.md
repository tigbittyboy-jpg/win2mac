# Bridge — Phase 1 architecture

Bridge is an ARM64 native macOS launcher for user-installed Wine-compatible runtimes. It delegates Windows API behavior, CPU translation, and graphics translation to those runtimes. macOS 14 is the frontend minimum; a chosen runtime can require a newer OS. Phase 1 imports and launches x64 PE executables, including installers, and stores library entries. It does not automatically discover applications installed by an installer.

## Boundaries and data flow

`BridgeApp` (SwiftUI, main actor) → injected `BridgeCore` services → `ProcessExecuting` → Foundation `Process`.

The Xcode project builds BridgeCore as a static Swift library and links it into the app and tests. The protocol/module separation remains intact, with no BridgeCore framework to load at runtime. This avoids the hardened-runtime Team ID mismatch seen with the ad hoc signed dynamic framework in preview.5. Hardened runtime and library validation remain enabled; no security-disabling entitlement is added. Public previews still require appropriate Gatekeeper approval and are not notarized.

- **LaunchService** validates approval, x64 PE format, runtime, associated prefix, and supported graphics selection. It sets `WINEPREFIX`, passes the EXE as a distinct argument, chooses the EXE directory as working directory, streams output, and returns exit status. One launch at a time in Phase 1. Cancellation terminates the immediate child; Wine servers and detached game processes can outlive it.
- **BottleManager** creates a new directory, writes an ownership record, runs `wineboot -u` via the selected runtime (`wine wineboot -u`), and checks `drive_c` and `system.reg`. It enumerates configured bottles and changes descriptive configuration. Removal requires a matching ownership record, a canonical path outside the source tree, and no active launch. Existing prefixes may be associated but cannot be deleted by Bridge. Moving a prefix is unsupported.
- **RuntimeManager** passively discovers known paths and allows arbitrary explicit file selection. It validates executable file access and inspects Mach-O CPU types. A version probe is an executable launch and requires approval. Probe success proves the command responds as Wine, not Windows/game compatibility. Script wrappers need a user-declared architecture because their payload cannot be reliably inferred. No downloaded runtimes or automatic Rosetta installation.
- **ApplicationLibrary** is an actor with atomic, versioned JSON persistence for application entries, runtime records, and bottle associations. Decode/IO errors surface; corrupt files are never silently replaced. Records use stable UUIDs. Deleted runtimes/bottles cannot leave dangling application associations. User data is outside the checkout.
- **GraphicsManager** describes runtime-default, WineD3D, DXVK/MoltenVK, and D3DMetal with capability and distribution caveats. Only runtime-default is configurable in Phase 1; Bridge does not install DLLs or claim to detect capabilities from `wine --version`.
- **DiagnosticsService** reports host OS/architecture, passive Rosetta detection, runtime metadata, launch outcome, and redacted recent output. Home/source/runtime/prefix/EXE paths are replaced where known; other absolute paths are also redacted heuristically. Output can still contain secrets or document contents: review before sharing. Bridge never includes the process environment in diagnostics.

Protocols provide replaceable process, runtime, bottle, library, launch, and diagnostic services. UI dependencies are injected through `BridgeModel`. Output and persistence are bounded/serialized. Process pipes are drained concurrently to avoid stdout/stderr deadlock; capture limits apply separately to each stream. Process cancellation and probe timeouts are explicit. Prefix configuration is descriptive in this phase: no automatic registry edits or graphics switching.

## Windows x64 on Apple Silicon

A Windows PE executable is not a macOS Mach-O executable. Rosetta translates supported Intel **macOS** processes; it does not by itself load Windows programs or implement Windows APIs. An Intel macOS Wine engine may run under Rosetta and execute x64 Windows code through the engine's loader and compatibility implementation. A native ARM64 Wine executable alone does not establish x64 guest execution; it needs an appropriate supported translation path. Bridge requires the user to affirm that their provider documents Windows x64 support. This is a compatibility declaration, not cryptographic or functional proof.

For an x86_64-only runtime on ARM64, Bridge checks for the Rosetta runtime file as a conservative prerequisite. If absent, it reports Apple's installation instructions; it does not bypass security controls or install anything. Universal binaries require an engine that supports x64 guests in its selected slice. Wrappers require an explicit architecture selection. No `/usr/bin/arch` or shell trampoline is added by Bridge; specialized engines must provide a supported executable wrapper that establishes their own runtime environment. Phase 1 passes the normal inherited host environment plus a controlled `WINEPREFIX`; it does not inject a generic library path or promise that every commercial engine is runnable through its internal binary.

32-bit Windows apps are explicitly rejected in Phase 1. Some engines offer WoW64/wine32-on-64 paths, but modern macOS does not run 32-bit Intel Mach-O processes, and support is engine-specific. ARM Windows executables, kernel drivers, kernel anti-cheat, protected media, unsupported CPU instructions, and unsupported DirectX features are not supported by this prototype. Anti-cheat and DRM may reject Wine even when rendering works. Do not use Bridge to evade these systems.

## Graphics and licensing

WineD3D commonly translates Direct3D through OpenGL; Apple's OpenGL support is deprecated and constrained. DXVK translates Direct3D 8/9/10/11 to Vulkan; macOS requires a compatible Vulkan-to-Metal implementation such as MoltenVK and an engine/build whose requirements it can satisfy. MoltenVK is a Vulkan subset with portability limitations; upstream DXVK is not a plug-and-play guarantee on macOS. D3D12 typically needs an additional supported translation backend. D3DMetal in Apple's Game Porting Toolkit and commercial engine components have their own agreements and distribution conditions. Bridge supplies none of these components and does not treat them as freely redistributable. Future adapters must declare supported APIs, host/runtime versions, provenance, and licensing separately.

## Trust and isolation

All imported EXEs and runtime binaries are untrusted. File selection/import never executes them. Each launch, probe, and prefix initialization presents the actual executable/prefix and requires explicit approval. Approval is per operation and does not attest safety. External binaries may change after inspection/approval: Phase 1 does not hash-pin user-installed files. Bridge does not download or update binaries. Any future managed download must verify a publisher signature and a trusted expected cryptographic checksum before offering execution approval; a hash downloaded alongside an untrusted binary alone is insufficient.

A Wine prefix is **not a security sandbox**. Wine processes inherit the user's filesystem and network access and may expose macOS paths through `Z:` or symlinks. The app deliberately has no App Sandbox entitlement because generic user-installed Wine runtimes cannot be assumed to work within it. Do not run unknown software; use a separately isolated machine/VM when appropriate. macOS Gatekeeper, quarantine, signing, and permissions remain in force. No administrator privileges are needed for normal Bridge operations.

## Source notes

Reviewed upstream Wine, DXVK, and MoltenVK READMEs during implementation (2026-10-08). Apple and CodeWeavers pages were blocked by this cloud environment's egress policy; these authoritative references must be reviewed on the target Mac for current OS support, Rosetta availability, runtime instructions, and licenses:

- [Apple: Rosetta installation](https://support.apple.com/en-us/102527)
- [Apple: Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)
- [Wine source and platform notes](https://github.com/wine-mirror/wine/blob/master/README.md)
- [Wine macOS documentation](https://gitlab.winehq.org/wine/wine/-/wikis/MacOS)
- [CodeWeavers CrossOver](https://www.codeweavers.com/crossover)
- [DXVK requirements](https://github.com/doitsujin/dxvk/blob/master/README.md)
- [MoltenVK capabilities and licensing](https://github.com/KhronosGroup/MoltenVK/blob/main/README.md)

No runtime/EXE combination is certified by Phase 1. See `docs/VALIDATION.md` for the actual validation record and remaining hardware checks.
