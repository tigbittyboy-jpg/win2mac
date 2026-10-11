# Bridge overhaul audit

Audited the Swift 6 backend, SwiftUI/AppKit model and views, JSON persistence, process execution, Wine discovery, prefix ownership, DXVK transactions, XCTest fixtures, generated static-core Xcode project, and build/release scripts before refactoring.

Confirmed defects and gaps:

- EXE validation reads only 26 PE bytes: truncated optional headers and sections can pass. CPU and container detection only recognizes x86/x64; CLR and ARM variants are not described.
- Prefix creation immediately checks registry files after wineboot returns. Wine can leave background initialization running; the user supplied evidence that the supposedly failed prefix later had both required files. Partial data is correctly preserved but there is no recovery action.
- Launching requires manually creating/assigning a bottle, even when the runtime is already configured. Runtime declarations are useful evidence boundaries but there is no automatic architecture router.
- Stdout/stderr are drained safely, but the UI truncates its console and process result capture is bounded. There is no persistent complete streamed run log.
- Exit 3 is reported without classification. It is not proof of missing Visual C++; actual user traces show an abort without a definitive cause. A version probe or exit 0 cannot certify a working game.
- UI exposes Wine paths, architecture flags and raw output in ordinary workflows. Library lacks search, favorites, display modes, rename, history, and installer target selection.
- Existing JSON saves are atomic and reject corrupt/future stores. Additive optional metadata must retain legacy IDs, associations and graphics settings.
- Discovery already prefers the real Wine.app command-line executable over the MacOS app launcher. CrossOver/GPT internal binaries cannot safely be treated as generic Wine adapters.
- Existing DXVK import/restore journals, lease checks and ownership-gated deletion are valuable and must survive. The import is x64-only; changing a checkbox does not provide a 32-bit graphics engine.
- Frontend is ARM64/static core with hardened ad hoc signing. macOS SDK tests and extracted-ZIP launch checks exist; Linux cannot validate Windows execution, real UI interaction or graphics.

The implementation retains external engine approval and licensing boundaries. Repair is limited to explicitly approved initialization of an owned environment, with a bounded readiness wait; dependencies and unknown application crashes require evidence rather than automatic DLL replacement.
