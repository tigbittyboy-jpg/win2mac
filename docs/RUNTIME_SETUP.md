# Runtime setup on Apple Silicon

Bridge is a launcher. It does not include Wine, install a compatibility engine, or run Windows by itself. You must install a Wine runtime separately before creating a bottle. No runtime installed means the runtime list will be empty.

## Free Wine builds

The Wine macOS packaging maintainer publishes [macOS Wine builds and installation instructions](https://github.com/Gcenx/macOS_Wine_builds), including [downloadable releases](https://github.com/Gcenx/macOS_Wine_builds/releases). Follow the provider's current dependencies and OS instructions. For a manual stable installation, extract the provider's `wine-stable` archive and move **Wine Stable.app** to **Applications**, as the provider documents. These Intel macOS builds use Rosetta on Apple Silicon; follow [Apple's Rosetta instructions](https://support.apple.com/en-us/102527) if it is absent.

As checked on 2026-10-08, the Homebrew `wine-stable` cask lists version `11.0_1`, requires Rosetta, and is **disabled** with reason `fails_gatekeeper_check` (effective 2026-09-01). Do not rely on the provider README's older `brew install --cask wine-stable` command as a working installation route. See the [actual Homebrew cask](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/w/wine-stable.rb). Manual downloads are also subject to macOS security checks: use Apple's approved opening flow only if offered and you trust the provider. Bridge does not remove quarantine, override malware detection, or disable Gatekeeper. If macOS refuses the runtime, use a provider-supported distribution that macOS permits; the launcher cannot resolve that restriction.

The maintainer documents 32/64-bit Windows execution, but Bridge Phase 1 accepts only x64 EXEs. These builds have not been tested here on the reported macOS 27 system or against any actual Windows application. Game, graphics, anti-cheat, and installer compatibility remain engine-specific.

## Add the installed runtime to Bridge

1. Open **Bottles** and choose **Scan Installed Runtimes**. Bridge also scans known paths at startup; this reads executable headers and never runs a runtime.
2. If the installed runtime is not found, choose **Choose Wine Executable…**. For the provider's standard stable app, select `/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine`. The file chooser allows browsing inside app bundles. Do not select a Windows EXE or the outer `.app` bundle as the runtime executable.
3. Check the provider's engine architecture. The referenced Intel builds use **x86_64**. Only enable the Windows x64 support checkbox if the provider documents that execution path, then choose **Save Runtime Settings**. Bridge preserves saved declarations during later scans. A path being detected does not establish x64 compatibility.
4. Optionally choose **Probe Version…** and approve the displayed command. This executes `--version` only and does not certify game compatibility.
5. Enter a bottle name and a new prefix directory. **Create Bottle…** becomes available after runtime configuration is saved; it presents an execution approval before running `wineboot`. No runtime is executed just by selecting it or opening Bottles.

Existing Wine prefixes can be associated with their compatible runtime. CrossOver and other engines may require provider-specific environment setup or adapters; selecting an arbitrary private binary from an app bundle is not a supported integration claim.

## Probe file-access warnings

A `sandbox_extension_issue_file_to_process ... Operation not permitted` warning around Wine Devel in Downloads is separate from a game's DirectX failure. Follow the provider's installation path: move the app to Applications, open it normally using any macOS-approved flow offered, and reselect its Wine command-line executable in Bridge. An app launcher script may ignore `--version`; do not confuse the outer app launcher with the documented Wine CLI. Bridge accepts an actual Wine version line, not merely the word Wine in a warning pathname. A real version line plus a warning may still identify the runtime; probe success remains separate from game compatibility. Do not remove quarantine, disable Gatekeeper, or grant unrelated broad filesystem access to silence the warning.
