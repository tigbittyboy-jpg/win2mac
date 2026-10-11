# 32-bit Windows x86 setup

Bridge now recognizes x86 PE32 and x64 PE32+ EXEs. ARM Windows binaries are detected but cannot be launched; malformed/mismatched PE headers and DLLs renamed as EXEs are refused. Importing an EXE never executes it.

1. Update Bridge to the latest 0.2 preview or build current source.
2. In Compatibility, choose your installed provider’s actual Wine engine. For the manually installed Wine Devel app this may be `Contents/Resources/wine/bin/wine`; select the provider-documented executable for your installation, not an app-opening launcher.
3. Keep its host architecture and x64 declaration configured. Separately confirm the provider documents **Windows x86 (32-bit/WoW64) execution on this Mac**, then Save Runtime Settings. This is a user declaration, not an automatic test or override of Wine limitations.
4. Play a new library entry to prepare a separate environment automatically with Runtime Default graphics; manual creation is in Settings → Environments. Initialization still uses `WINEARCH=win64`; existing bottles and files are not migrated. New WoW64 runtimes can load supported 32-bit Windows programs in win64 prefixes. Do not switch to a win32 prefix on modern macOS.
5. Select the game EXE in Library, associate the new bottle, leave unrelated Unity/CARL arguments out, and launch with explicit approval. Capture Process Output if it fails.

Bridge’s manual macOS DXVK importer only installs x64 DirectX 10/11 DLLs. A 32-bit game cannot use that configuration in Bridge; x86 launch refuses it before executing software and asks for a separate default-graphics bottle. DirectX 9/OpenGL support, 32-bit Wine components, Rosetta requirements, Steam/client dependencies, and game compatibility depend on the runtime. No x86 DLLs are downloaded or installed by Bridge.

Old library.json files retain existing IDs/settings and load the new declaration as unconfirmed. Discovery and probes never turn it on. Hosted tests use mocked Wine execution and synthetic PE fixtures; they do not establish Binding of Isaac compatibility. Verify on Apple Silicon with the exact runtime and game edition before reporting real compatibility.
