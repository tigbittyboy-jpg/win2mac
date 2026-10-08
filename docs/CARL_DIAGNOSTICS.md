# CARL rendering and performance diagnosis

The user-reported launch log confirms macOS DXVK v1.10.3-20230507 creates a Direct3D 11 feature-level 11.0 device on Apple M1 Pro through MoltenVK 1.4.0. The user reports missing menu text and approximately 5 FPS. This establishes launch/device initialization, not correct or playable rendering.

`Adapter is not a DXVK adapter` is consistent with using Wine's built-in DXGI; the fork falls back to a Vulkan adapter and the log then names M1 Pro. Early WineD3D/OpenGL enumeration does not establish that DXVK's rendered frames use OpenGL. `No state cache file found` alone does not establish sustained shader-compilation stalls. Advertised GPU features of zero are limitations, but require actual shader/device errors before attributing a specific visual defect. The pasted process log lacks Unity font/material/shader errors and measured sustained performance.

## One controlled diagnostic launch — no app rebuild

1. Keep the recorded DXVK import. In Bridge's CARL arguments, use the following **one argument per line**, then Save Arguments. This requests Direct3D 11, a 1280×720 window, and Unity's player log on standard output:

   ```text
   -force-d3d11
   -screen-fullscreen
   0
   -screen-width
   1280
   -screen-height
   720
   -logFile
   -
   ```

   Preserve any separately required game arguments. Remove previous conflicting renderer flags. Flags depend on the game build; verify the resulting renderer/resolution in Unity output.

2. Optionally download [the diagnostic overlay config](https://raw.githubusercontent.com/tigbittyboy-jpg/win2mac/main/docs/templates/carl-diagnostics.dxvk.conf), save it as **dxvk.conf** in the folder containing **CARL.exe**, and preserve any existing dxvk.conf first. Use a plain-text file, not RTF or a file ending in .txt. Do not modify DLLs or the graphics backup directory. Bridge uses the executable directory as the working directory; the DXVK fork looks there for dxvk.conf unless a provider's DXVK_CONFIG_FILE setting overrides it.
3. Launch and separately approve as usual. Look for `Found config file: dxvk.conf`, then the overlay. It displays FPS, estimated GPU load, and compiler activity. Its text is rendered independently of Unity's menu text. Missing overlay alone can mean the config was not loaded; check the config message before interpreting it.
4. Observe the same menu for about a minute, close normally, and relaunch once. Record FPS after startup and whether compiler activity persists. GPU-load estimates are approximate and cannot prove a CPU bottleneck alone.
5. Share the relevant Unity errors mentioning Shader, TextMeshPro, font, material, missing assets, unsupported features, or exceptions; the Unity renderer/resolution lines; and the sustained overlay readings. The repeated MoltenVK extension list need not be copied. Include the Wine version from Probe Version. If Unity does not route its log to the console, check Player.log under the bottle's drive_c/users/<Wine user>/AppData/LocalLow/<creator>/<game>, using the newly updated log for this launch.

Undo by removing the temporary dxvk.conf and restoring any prior config, and removing the diagnostic logging/resolution arguments as desired. Keep -force-d3d11 for the DXVK Direct3D 11 test. Do not delete the prefix, DXVK snapshots, or shader caches as a first step, and do not install Windows fonts without evidence of a missing font dependency.

The overlay option and config-file lookup were checked against the [macOS fork's source](https://github.com/Gcenx/DXVK-macOS/tree/1.10.x/src/dxvk/hud). No CARL execution or FPS/rendering validation was performed in the cloud. These diagnostics are intended to select a targeted fix, not claim that the issue has already been corrected.
