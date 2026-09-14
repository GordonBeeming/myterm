# SwiftTerm source provenance

This directory contains SwiftTerm from [v1.15.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.15.0), commit `dd2fb8ac5b861e7bf617c872895e338f38165648`. Its original [MIT license](LICENSE) is retained.

The myterm additions provide a bounded, versioned terminal checkpoint and native view controls for remote presentation:

- `Terminal.exportCheckpoint()` and `Terminal.importCheckpoint(_:)` preserve emulator state for late attachment.
- `TerminalView.invalidateAfterCheckpointImport()` prepares native images and refreshes rendering after import.
- `sendsTerminalResponses`, `acceptsUserInput`, and `automaticallyResizesTerminal` separate the authoritative host from spectator views. They default to the original behavior.
- `resizeToFit()` reapplies the view's current geometry after it gains control.

Checkpoint preparation validates fallible state before replacing the destination. It preserves the receiving terminal's delegates and registered callbacks. Wire limits, parser-state tests, image tests, and same-suffix equivalence tests live in `Tests/MyTermPlatformTests/TerminalCheckpointTests.swift` in the parent repository.

When updating upstream, audit every added emulator field and bump the checkpoint version when required. Build both the macOS and iOS branches and repeat checkpoint continuation tests before changing this dependency.
