# Kitty placement contract investigation

[Resolve virtual and parent Kitty placement fidelity](https://github.com/GordonBeeming/myterm/issues/187) remains open. The first native probes expose a choice about the reference behavior: SwiftTerm itself accepts cycles and leaves a child placement record after its parent is deleted. The [Kitty protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/#relative-placements) requires cycle rejection and ties a child's lifetime to its parent.

The proposed contract is to correct both engines to the protocol and use the corrected native client as the reconnect reference. Gordon's decision is pending. No graphics implementation or production source has changed.

## Measured behavior

The fifteen traces exercise ordinary placements, virtual placements, pending and completed combined transfers, relative placements, negative parent offsets, missing parents, cycles, virtual/relative rejection, automatic placement identity, crops, offsets and overlaps. They compare fresh checkpoint imports and subsequent events with an uninterrupted native SwiftTerm instance.

Only `ordinary-control` and `overlap` fully match. Of 76 restoration/continuation comparisons, 34 match and 42 differ. Six exports reject state: two each for automatic identity, crops and offsets. No imports reject. A successful probe command means measurement completed; these results are failing fidelity evidence.

The native reference records a self-cycle and a two-node cycle, acknowledging both with OK. In the relative-placement trace, deleting parent placement 1 leaves placement 2 recorded with its reference to the absent parent. Virtual placement leaves the native cursor at (0,0), while the Rust candidate moves it. The candidate also moves the cursor for relative placements that omit C=1; native SwiftTerm correctly preserves it. Cursor movement contributes to the `normal` differences independently of placement-record fidelity.

Native SwiftTerm correctly replies ENOPARENT for a missing parent and EINVAL for a virtual placement with a parent. The candidate replies OK to both invalid requests. The pinned Rust `KittyImagePlacement` parser has no fields for U, P, Q, H or V; pending transfer serialization cannot preserve those discarded keys either. The bridge writes every restored placement with no parent and `isVirtual: false`.

The probe checks both native buffers, cache and placement state, decoded stripe pixels and continuation replies through the existing semantic comparator. It also retains direct candidate cursor/reply comparisons. It does not capture composited view rendering, demonstrate Unicode-placeholder rendering, exhaust deletion modes, establish depth limits or prove a complete supported graphics contract. Those remain necessary acceptance work after the behavior decision.

## Reproduce

Use native macOS, Python with Pillow and the retained checkpoint experiment's prepared build. To prepare a fresh build from its pinned foundation and both retained corrections:

```sh
python3 docs/wayfind/125/column-zero/prepare.py \
  --baseline-source /tmp/myterm-150-baseline-20261116/source \
  --output /tmp/myterm-kitty-contract-build
python3 docs/wayfind/125/kitty-contract/probe.py \
  --build /tmp/myterm-kitty-contract-build \
  --output /tmp/myterm-kitty-contract-results.json
```

Preparation requires the cached pinned WezTerm source and dependencies, Rust 1.99.1 and the native Swift toolchain described in the cursor-reflow experiment. Output paths must be fresh. This probe opens no windows and controls no app or simulator.

`evidence/expanded-baseline.json` is the latest capture, run against `/tmp/myterm-188-complete-build`, the final retained cursor-reflow build. It includes fixtures, native placement records, candidate cursor/reply results, every restoration comparison, binary hashes, relevant source hashes and the comparator hash. It uses the current probe with direct candidate details and capture-completeness checks.

The earlier `baseline.json` used `/tmp/myterm-188-accepted-build`; `confirmed-baseline.json` used `/tmp/myterm-188-complete-build`. Both used the earlier observational probe with SHA-256 `1c673d0001a574341e199f15fa9dc9825f6daf4a6b94e6e1473a9a60309009cb`; they lack the direct candidate details and completeness checks. Their totals match the expanded capture. The recorded binary hashes identify the executables measured; rebuilding does not promise byte-identical binaries.

The six source hashes in the cursor-reflow experiment's `evidence/run.json` match the final-build sources used here; `evidence/verification.json` records each check. The native Kitty implementation also matches the vendored source. That file records the Browser.app visual checks and the checked counterexamples. No fresh compilation or production integration is claimed for these captures. The initial captures did not record Python or Pillow versions; `evidence/environment.json` records the environment used for this investigation.

`contract.html` shows the native counterexamples, the proposed behavior and the measured restoration failures in separate tabs. The artifact is copied to the personal artifact directory for viewing. Its proposal is not an accepted resolution.

`evidence/virtual-record.json` is an ad hoc focused rerun of `virtual-explicit` using the probe helpers and final build. It records the native virtual placement and the imported ordinary placement. `reviewClaimPlacements` preserves the initial review note, not a measured client state; Claude withdrew that note after checking the event index. `verification.json` and `environment.json` were also captured by ad hoc commands. The environment file was recorded after the trace captures and does not establish a separately measured environment for each one. The committed probe reproduces the main matrix; these supplementary files have no dedicated retained runner.

Claude's review and closure are retained in `evidence/review-initial.json` and `evidence/review-closure.json`. The closure permits committing this investigation record and leaves the product decision pending. The reviewer did not rerun the probes or perform visual QA; those checks were performed in this session.
