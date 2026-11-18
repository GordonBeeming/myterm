# Native checkpoint raster-width investigation

[Investigate intermittent native checkpoint raster width](https://github.com/GordonBeeming/myterm/issues/197) investigates the retained 17-versus-18-pixel stripe mismatch. A controlled geometry difference reproduces those exact widths, and real windows demonstrate how cached font measurements can differ from current display scale. Reference and restored clients match exactly when their measured geometry agrees.

This is an isolated diagnostic against the accepted Kitty checkpoint foundation. It changes no production source. [Validate production terminal checkpoints and native SwiftTerm reconnect](https://github.com/GordonBeeming/myterm/issues/189) retains production geometry/controller integration and release acceptance.

## Findings

The measured default font is `.AppleSystemUIFontMonospaced-Regular`, size 13. Its raw W advance is 8.0361328125 points. SwiftTerm snaps that width with `ceil(raw * scale) / scale`: a 1× grid produces 9-point cells and a 2× grid produces 8.5-point cells. The two-column request in the historical `kitty-retained-image` fixture therefore creates an 18-pixel or 17-pixel native stripe bitmap. Image scale separately contributes to the checkpoint's physical wire-cell dimensions; those dimensions are validated by the importer.

Before window attachment, the font-grid helper falls back to `NSScreen.main`, while image scale falls back to one. The deliberate mixed-grid control reproduces 17 pixels against the coherent 1× control's 18 pixels. Exact decoded raster comparison detects the difference. The earlier failed run did not record geometry, so its precise initialization sequence cannot be reconstructed. The controlled reproduction establishes a measurement condition sufficient to produce its symptom.

Real-window measurements expose a related integration hazard. In this environment the unwindowed view initialized with 9-point cells. Attaching it to a 2× window changed image scale to two while preserving that cached cell width. Assigning the same font again recomputed an 8.5-point cell and produced a 17-pixel stripe. Initializing `NSApplication` before versus after view creation did not change that result in the recorded runs.

Twelve window-movement runs cover every ordered pair of the three available displays, with and without explicit font refresh. The retained measurements verify the actual screen reached, rather than inferring success from the requested coordinates. Image scale follows the real window. Cached cell width stays unchanged without refresh; explicit refresh produces the width predicted by that window's scale.

Existing image stripes remain prepared at their previous geometry after movement. These movement observations do not establish checkpoint parity across a geometry transition. Production integration must define and test how retained images, authoritative server geometry and client cells converge before comparing or publishing checkpoints. Merely forwarding the new backing scale cannot establish that result.

## Verification

The fresh diagnostic build uses the accepted foundation recorded in `kitty-contract/evidence/final/build.json`. Preparation checks every retained foundation source and both executable hashes, applies only the diagnostic patch without fuzz, and records the new source, patch and executable hashes. The initial development run used an older retained foundation; it is excluded from final acceptance evidence.

The final run has 34 trials and 204 passing checkpoint/continuation comparisons. Each comparison checks normalized terminal state, geometry, terminal replies, exact decoded logical-view pixels and exact decoded backing-resolution pixels. Three checkpoint cuts cover initial placement, continued placement and terminal/window resize. Restored windows start at the matching reference viewport, including the post-resize cut.

The trials comprise one coherent 1× headless control, ten independent unforced headless trials run serially, ten run with four concurrent workers, and thirteen real-window trials. The window trials cover all three displays, both application/view initialization orders, and explicit font refresh enabled and disabled. Actual window scales include 1× and 2×. The main-screen fallback reported 1× in all 34 retained trial records, so those unforced headless trials did not exercise a 2× main-screen fallback. A later controlled-import process reported a 2× main screen; that value varies between processes across run sets. Its font grid was forced to 1×, so it does not establish an unforced 2× fallback result. The intermittent headless symptom was never reproduced without forcing the font grid. The real Retina window produced 17 pixels with an ordinary font refresh, without a grid override.

A separate assessment passes 117 assertions about exact negative-control widths, visible windows, actual screen indices, predicted cell widths, pixel equality and screen transitions. The deliberately mismatched capture control remains unequal. Two additional checkpoint controls exercise the importer directly: a 9-point/1× reference and an 8.5-point/1× importer share rounded wire-cell width nine but restore 18-versus-17-pixel stripes, which exact comparison detects; a checkpoint with 17×32 physical wire cells is explicitly rejected by the 9-point/1× importer. These controls pass and are retained in `evidence/cross-geometry.json`. The rejection control checks the pinned diagnostic build's error text. `check.py` records any unforced diagnostic mismatch in `observedFailures`; its required coherent-headless and explicitly refreshed window gates must pass. `assess.py` independently requires every recorded real-window trial to match exactly. These comparisons reuse the reference screen, font-refresh setting and viewport for each importer; they establish parity when geometry agrees. Run the comparison and assessment commands for that gate. After adding the direct import controls, a separate headless integration run passed both controls and 30 comparisons; `evidence/control-integration-summary.json` records it. The GUI assessment was not rerun for that script-only addition.

The first harness run compared differently sized viewports after the final resize cut, causing thirteen window-trial failures. A second attempt exposed Python's ties-to-even rounding at 8.5, which differs from Swift's positive ties-away-from-zero rounding and supplied an invalid wire-cell width. Both harness errors were corrected before the fresh verified run. `evidence/initial-harness-failures.json` records them; the temporary import rejection is not evidence of an interprocess geometry change.

The environment was macOS 27.3 ARM64, Swift 6.4.2 and Xcode 27.2, with one 2× display and two 1× displays. The diagnostic opens native AppKit windows and uses native CoreGraphics NSView capture. It records the default renderer as non-Metal. CoreGraphics and Metal share the image-stripe preparation path, but this evidence does not establish Metal onscreen pixel parity. Full MyTerm controller/transport integration, configured-font coverage, other Macs, iPhone/iPad and native Linux/Windows acceptance remain open.

## Reproduce

Prepare the accepted Kitty foundation using the commands in [its README](../kitty-contract/README.md), or use the retained verified build. The following diagnostic paths must be fresh. Preparation is headless; the `--gui` check opens, moves, resizes and closes disposable windows and requires Gordon's explicit GUI opt-in.

```sh
python3 docs/wayfind/125/raster-width/prepare.py \
  --foundation /private/tmp/myterm-187-verified-replay \
  --output /private/tmp/myterm-197-verified
python3 docs/wayfind/125/raster-width/check.py \
  --build /private/tmp/myterm-197-verified \
  --output /private/tmp/myterm-197-verified-run --gui --repeats 10
python3 docs/wayfind/125/raster-width/geometry_controls.py \
  --build /private/tmp/myterm-197-verified \
  --output /private/tmp/myterm-197-verified-run/cross-geometry.json
python3 docs/wayfind/125/raster-width/assess.py \
  /private/tmp/myterm-197-verified-run/captures.json.gz \
  --output /private/tmp/myterm-197-verified-run/assessment.json
python3 docs/wayfind/125/raster-width/report.py
```

Preparation creates `RasterDiagnostic.app`; the runner launches it through `open -n -g -W` with explicit input/output files. Windows close when each bounded process completes. No MyTerm workspace, service, account, clipboard or saved preference is used. A launch timeout raises an error; inspect the owned process before retrying.

`evidence/captures.json.gz` retains the complete captures and GUI commands, including original checkpoint state and both raster resolutions. `summary.json` and `assessment.json` hold results. `build.json` records provenance. `comparison.html` embeds the measured before/after captures and the geometry mechanism; `report.py` regenerates it from the retained evidence. The report's crops are actual native raster pixels enlarged for inspection.
