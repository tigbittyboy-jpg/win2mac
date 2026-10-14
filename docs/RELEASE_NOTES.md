# Win2Mac 0.3 source rebuild (not yet a verified release)

Runtime executable identity, isolated per-app graphics, offline verified environment backups with retained-save restoration, dependency/Steam installation journals, Steam manifest import and launch routing, structured diagnostics, interrupted-run recovery and explicit compatibility observations are implemented in source. The native product is Win2Mac.app; legacy Bridge data stays in place. Linux passed 85 backend XCTest cases. macOS compilation, nine actual-model cases, app startup, installers, Steam authentication and real game compatibility remain unverified for this revision. See [REBUILD_STATUS.md](REBUILD_STATUS.md) for requirements and limitations. Ad hoc packaging remains unnotarized.

The notes below describe older published Bridge versions, not verification of this rebuild.

Preview.5 fixes an EXE import-table validation regression: import-directory sizes that omit the final null descriptor are accepted with one additional bounded, mapped read. This addresses a possible cause of CARL’s new pre-launch inspection failure; the actual user EXE remains to be retested. Isaac exit 3 is still unresolved; this release does not claim to fix its crash.

Bridge 0.2 introduces Home, a searchable grid/list Library, Compatibility setup and advanced Settings. Import or drop a Windows EXE, then press Play: Bridge inspects its architecture, selects a configured compatible Wine engine and prepares a separate environment after approval.

Favorites, custom names/icons, launch settings, launch history and local diagnostic logs persist. Existing CARL bottles and DXVK settings are preserved. Owned environments can be repaired without deleting application files. Exit codes are explained using captured evidence; process startup is never labeled verified game compatibility. Configured apps can explicitly remember approval bound to unchanged EXE/engine bytes and launch settings.

After updating, replace Bridge.app in Applications and open it. Your existing library loads automatically. Use Compatibility to select and configure your user-installed Wine command-line engine; Home then offers Run Windows App. Technical environment/graphics controls are in Settings → Environments. Per-game arguments and settings are under the selected app's Settings button. Logs are available from its details page.

Supports declared x64 and x86/WoW64 capabilities. ARM64/ARM64EC files are inspected but require unavailable dedicated adapters. CrossOver and GPT are not treated as interchangeable generic Wine engines. No compatibility engine, graphics library, .NET or Microsoft runtime is downloaded or bundled. Installer detection is conservative; mark ambiguous installers in Application Settings, and choose the installed launch target after setup.

The native ARM64 frontend requires macOS 14+. Release checks build/test with Apple's SDK and verify a visible window from an extracted signed ZIP on macOS 14, 15 and 26. They do not run Wine, Isaac, CARL or other Windows applications. Actual game rendering/performance remains hardware-dependent. See docs/OVERHAUL_STATUS.md for delivered features, boundaries and outstanding manual checks.

The preview is hardened and ad hoc signed, not Developer ID signed or notarized. Keep macOS security protections enabled. Wine environments organize files; they are not security sandboxes. First execution, preparation, probes and repairs require informed approval. Removing a library entry does not uninstall the application or remove its environment.
