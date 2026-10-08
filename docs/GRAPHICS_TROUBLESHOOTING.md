# Graphics initialization failures

Creating a bottle and getting Wine exit code 0 does not establish that a game's renderer initialized. A game can display an error and then exit successfully as a process. Bridge cannot certify graphics compatibility from a version probe, exit status, or MoltenVK enumerating your GPU.

## Unsupported Direct3D feature levels

The Wine message `None of the requested D3D feature levels is supported on this GPU with the current shader backend` means the current WineD3D path cannot provide the application's requested features. An accompanying `GL_RENDERER "Apple M1 Pro"` indicates OpenGL adapter detection. MoltenVK output elsewhere in the same log establishes that Vulkan is present, not that this Direct3D attempt used a compatible Vulkan renderer. Installing Windows graphics drivers or a DirectX redistributable does not supply a macOS translation backend.

If your installed Wine supports WineD3D's Vulkan renderer and already has working Vulkan/Metal components, Bridge can request that alternative without adding DLLs:

1. Select the application in **Library** and ensure it is associated with the existing bottle. Remove earlier experimental launch arguments such as `-force-vulkan` and save arguments so this attempt changes only the Wine renderer.
2. In **Graphics**, select **WineD3D Vulkan (experimental)**. The change saves automatically and affects every application using that bottle. It can also be selected beside the bottle in **Bottles**. The prefix, applications, and game files are not recreated or edited.
3. Launch and approve. The approval includes `WINE_D3D_CONFIG=renderer=vulkan`. This requests Wine's Direct3D-to-Vulkan renderer; it does not require the game's Unity build to support native Vulkan. Wine implements the option in [wined3d_main.c](https://github.com/wine-mirror/wine/blob/master/dlls/wined3d/wined3d_main.c).
4. Check for Wine's `Using the Vulkan renderer` message and subsequent adapter/feature/device errors. The environment request alone does not prove it took effect. Share relevant error lines and the probed Wine version if initialization still fails.
5. To undo, select **Runtime default**. Bridge then omits its WineD3D override on subsequent launches; provider settings and inherited environment still apply.

This is an experimental configuration option, not a confirmed game fix. Wine/MoltenVK builds differ, Vulkan features can be unavailable, and the game may need a different supported provider backend or remain incompatible. If WineD3D Vulkan still reports missing Direct3D feature levels, a separately approved manual [macOS DXVK import](DXVK_SETUP.md) can test a different Direct3D 10/11 implementation. D3DMetal is not managed. Do not copy arbitrary DLLs into a prefix or install GPU drivers to silence generic game dialogs.

The specific user-reported Unity demo failed through WineD3D's feature-level checks even after a Unity `-force-vulkan` attempt. A subsequent user log confirmed WineD3D Vulkan adapter initialization but continued feature-level failure. No execution of that demo or validation of the alternative renderer was performed on the cloud or CI machines. Hosted checks verify configuration persistence, exact mocked launch environments, approval boundaries, and native app startup only.
