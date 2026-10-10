Bridge now imports and launches 32-bit Windows x86 PE32 EXEs through compatible, user-installed WoW64 runtimes, alongside existing x64 support. ARM Windows executables, mismatched PE headers, and DLLs renamed as EXEs are refused.

After updating:

1. In Runtimes, select the provider's Wine command-line engine and enable the separate provider-documented **Windows x86 (32-bit/WoW64) execution on this Mac** declaration, then Save Runtime Settings. Existing runtimes load with this capability unconfirmed. Discovery and version probes never enable it automatically.
2. Create a separate bottle using **Runtime Default** graphics for the 32-bit game. Prefixes stay win64; do not change CARL's DXVK bottle. Bridge's manual DXVK importer remains x64-only and does not provide 32-bit DirectX 9 translation.
3. Select the 32-bit game EXE, associate its bottle, and launch with explicit approval. Leave CARL-specific Unity arguments out.

The preview includes synthetic architecture/migration fixtures, mocked x86 process-launch tests, and saved runtime-declaration UI-model coverage. Release publication requires native macOS build/test, signing/architecture verification, and extracted-ZIP visible-window/library startup checks on macOS 14, 15, and 26. No Wine runtime or Windows application is executed by these checks. Binding of Isaac and real x86 compatibility remain hardware-dependent and unverified.

This ARM64 frontend requires macOS 14+. It bundles no Wine or graphics runtime. The application is ad hoc signed with hardened runtime, not Developer ID signed or notarized; do not disable macOS security controls to run it. Keep your installed runtime and existing Bridge data. See docs/X86_SETUP.md for runtime and graphics limitations.
