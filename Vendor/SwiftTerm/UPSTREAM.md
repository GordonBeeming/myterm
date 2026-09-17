# SwiftTerm source provenance

This directory contains SwiftTerm from [v1.15.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.15.0), commit `dd2fb8ac5b861e7bf617c872895e338f38165648`. Its original [MIT license](LICENSE) is retained.

This is a library-focused source subset for MyTerm. The upstream `termcast` executable and its `swift-argument-parser` dependency are omitted because MyTerm links only the `SwiftTerm` library. SwiftTerm's library sources, fuzz target, documentation relevant to the retained library, and upstream test suite remain present.

The myterm additions provide a bounded, versioned terminal checkpoint and native view controls for remote presentation:

- `Terminal.exportCheckpoint()` and `Terminal.importCheckpoint(_:)` preserve emulator state for late attachment.
- `TerminalView.invalidateAfterCheckpointImport()` prepares native images and refreshes rendering after import.
- `sendsTerminalResponses`, `acceptsUserInput`, and `automaticallyResizesTerminal` separate the authoritative host from spectator views. They default to the original behavior.
- `resizeToFit()` reapplies the view's current geometry after it gains control.
- On iOS, `usesIndependentViewport` lets a viewer follow output within its own visible height. `captureViewport()`, `restoreViewport(_:)`, and `followOutput()` preserve local reading intent across checkpoint imports. `onViewportChanged` and `onFollowOutputChanged` report local scrolling changes.
- The iOS `coalescesInteractiveOutput` option keeps remote echo on the normal display timer while typing, so separate output chunks can be drawn together. It defaults to `false`.

Checkpoint preparation validates fallible state before replacing the destination. It preserves the receiving terminal's delegates and registered callbacks. Wire limits, parser-state tests, image tests, and same-suffix equivalence tests live in `Tests/MyTermPlatformTests/TerminalCheckpointTests.swift` in the parent repository.

When updating upstream, audit every added emulator field and bump the checkpoint version when required. Build both the macOS and iOS branches and repeat checkpoint continuation tests before changing this dependency.
