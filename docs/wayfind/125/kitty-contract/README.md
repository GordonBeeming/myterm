# Kitty virtual and relative placement correction

The accepted direction for [Resolve virtual and parent Kitty placement fidelity](https://github.com/GordonBeeming/myterm/issues/187) is to correct both engines to the Kitty protocol, then compare reconnects against the corrected native client. `graphics.patch` implements the bounded correction in disposable Rust and SwiftTerm sources. Production integration remains in [Validate production terminal checkpoints and native SwiftTerm reconnect](https://github.com/GordonBeeming/myterm/issues/189).

The fresh replay passes 82 traces and 620 checkpoint/continuation comparisons, including decoded native view pixels, placement state, both buffers, cursor positions and terminal replies. Forty-one independent protocol assertions pass, eighteen new malformed inputs are rejected, and the broader suite passes 49 cases, two expected limit rejections, 28 receiver controls, native streaming and a real native PTY. Both retained Rust probe tests pass. The independent review found no blockers for this bounded correction; its final report distinguishes static review from checks the reviewer personally ran.

## State and behavior

The Rust parser retains U/P/Q/H/V through complete commands and unfinished transfers. Virtual placements keep their identity without creating image cells. Relative placements use their parent's origin and preserve the cursor. Automatic placement identities skip existing identities and retain their next counter through reconnect. Paint requests belong to each placement, and a request digest participates in resource identity; equal image pixels and grid dimensions cannot overwrite different paint requests.

Both engines reject cycles, missing or foreign-buffer parents, invalid combinations and chains longer than 32 links. A rejected graph change keeps the old placement. Deleting a parent removes descendants and unreferenced dependent image data. Geometric deletion leaves virtual placements intact. Cache deletion preserves unrelated images and images with remaining references. Retransmission starts a new image and invalidates its old placement group; moving a parent identity between buffers removes old-buffer dependants.

Relative placements retain their complete bounded resource, including stripes outside the viewport. Their logical coordinates may be negative or outside the buffer. Projection places only the visible intersection, so clipped pixels can reappear when a parent moves after reconnect. A parent with no retained position hides its children while keeping their identities and resources. Placeholder output or a new parent placement can reveal them without replaying historical terminal output.

The native renderer prepares stripes and checks admission before replacing live placement state. Failed image creation returns an error and preserves the old placement. The correction also fixes truecolor placeholder byte order, explicit-dimension letterboxing, straight sRGB alpha interpretation and ordinary blank-cell defaults during import. The native view uses its real post-import image materialization and display refresh.

Unchanged output does not rebuild relative planes. Virtual origins are scanned together per layout update and paint uses cached visibility. The independent count control sends 100 unchanged output reads after placement and observes no additional projection in either engine. Eight overlapping additions retain twelve Rust image cells; the retained old executable retains 514. This prevents the observed exponential layer duplication. Virtual ancestors still require one text scan of the bounded buffer per input update; glyph edits can change origins without a graphics/scroll epoch. This is not a production latency or memory budget, and workload profiling remains required in the integration task.

The protocol authority is the [Kitty graphics specification](https://sw.kovidgoyal.net/kitty/graphics-protocol/). [Kitty's own placeholder tests](https://github.com/kovidgoyal/kitty/blob/master/kitty_tests/graphics.py) independently establish RGB packing: `38;2;0;0;42` selects image 42.

## Reproduce

Use macOS with the native Swift toolchain, Rust 1.99.1 and Python with Pillow. The final capture used Swift 6.4.2, Xcode 27.2, Python 3.14.3 and Pillow 12.1.1 on macOS 27.3 ARM64. The [pinned foundation instructions](https://github.com/GordonBeeming/myterm/blob/ab4f866153ff46c03e1e51de72eec8d85d233d51/script/wezterm-feasibility/README.md) describe the cached WezTerm source and dependencies. All output paths must be fresh.

```sh
python3 docs/wayfind/125/kitty-contract/prepare.py \
  --baseline-source /tmp/myterm-150-baseline-20261116/source \
  --output /tmp/myterm-kitty-contract
python3 docs/wayfind/125/kitty-contract/probe.py \
  --build /tmp/myterm-kitty-contract --raster --require-match \
  --output /tmp/myterm-kitty-matrix.json.gz
python3 docs/wayfind/125/kitty-contract/controls.py \
  --build /tmp/myterm-kitty-contract \
  --matrix /tmp/myterm-kitty-matrix.json.gz \
  --output /tmp/myterm-kitty-controls.json
python3 docs/wayfind/125/kitty-placement/regression.py \
  --build /tmp/myterm-kitty-contract
CARGO_TARGET_DIR=/tmp/myterm-kitty-contract/cargo-target \
  cargo +1.99.1 test --offline \
  --manifest-path /tmp/myterm-kitty-contract/native/probe/Cargo.toml
```

The optional `controls.py --baseline-server` argument points at an uncorrected cursor-reflow build and reproduces the 514-cell negative control. The normal control still enforces linear retention without that executable.

Preparation replays the retained placement and cursor-reflow corrections, verifies twenty foundation files against `base-hashes.json`, applies `graphics.patch` without fuzz and compiles. `graphics-build.json` records the patch, source and executable hashes and checks that sources do not change during compilation. The patch includes the broader harness changes that promote automatic placement and pending offsets from rejection cases to positive restoration controls.

## Native rendering and geometry

The experiment uses an actual unwindowed native NSView, an explicit coherent 1× font/image geometry, a black/white palette and an exact 640 × 480 bitmap. It opens and controls no MyTerm app window. These are headless native engine/rendering checks; they do not establish live-window, Retina, iPhone, iPad, Linux, Windows or multi-Mac acceptance.

`rendering-review.html` separates the measured native output, the reviewer's sizing hypothesis and the transport representation. An original 1 × 1 image with width two cells paints an 18 × 18 square, while its transport grid occupies 18 × 32. The original width request and automatic height survive the bridge. A separate natural image remains 100 × 1 pixels. Pixel bounds and both-dimension letterboxing have independent assertions.

The geometry diagnostic exposes a reproducible condition for the existing [native raster-width investigation](https://github.com/GordonBeeming/myterm/issues/197): unwindowed font snapping can use NSScreen's 2× fallback while image scale uses the absent window's 1× fallback. Controlled font-grid values produce 9-point versus 8.5-point cells at image scale one, and 18-pixel versus 17-pixel two-column rasters. `review_evidence.py` records that comparison. It is a measurement condition, not a live/Retina acceptance result or resolution of the separate task.

```sh
python3 docs/wayfind/125/kitty-contract/review_evidence.py \
  --build /tmp/myterm-kitty-contract --output /tmp/myterm-kitty-review
```

The script writes actual raster data and the self-contained comparison page, including its private artifact-directory copy. `PROTOTYPE_FONT_GRID_SCALE=2` enables the deliberate mixed-scale diagnostic; normal verification uses the explicit coherent 1× condition.

## Bounds and remaining acceptance

This is a bounded static, named-image experiment. Existing limits include a 1 MiB Rust checkpoint, 100,000 allocated cells, forty normal history lines, 1,000 rows/columns, 32 cache images, 256 KiB cache pixels, 32 graphic resources and 256 KiB decoded graphic resources. Encoded caches, pending chunks and rendered resources have separate checks.

The correction keeps the 1,024-placement cap and adds admission/receiver limits of 128 relative placements and 2 MiB of aggregate relative raster cost, including per-stripe overhead. The resource byte budget conservatively counts each distinct image/request pair, even when image pixels are identical. Logical coordinates can span sums of 32 signed 32-bit offsets; they do not allocate an offscreen canvas. These experimental bounds are not the released resource policy.

Anonymous image identity, animation and leased formats remain explicitly unsupported by this checkpoint experiment. This work does not waive existing supported product behavior. Production must paint from the retained request and original resource, rather than treating the logical Rust cell texture grid as a final pixel raster. Full integration, supported-format/application coverage, resource policy, platform validation and the existing alternate-buffer/raster gates remain required before production acceptance or release.

## Evidence

`evidence/final/` contains the fresh build manifest, matrix, protocol/rejection controls, broader regressions, Rust test output and post-test hash verification. The twenty source hashes, patch hash and both executable hashes still match the fresh build after verification. The commands above produced these results; retained historical counts are not substituted for current runs.

`evidence/rendering-review/` holds the actual native screenshots and encoded state used by the tabbed sizing/geometry comparison. `evidence/development/` preserves the earlier implementation review, alpha before/after probes and development captures. Those captures came from a mutable development tree: executable hashes identify what ran, but their source-tree hashes are not final build provenance. The earlier passing matrix shared the native byte-order bug; the current independent controls and corrected inputs address that weakness.

The original fifteen-case investigation remains in `baseline.json`, `confirmed-baseline.json` and `expanded-baseline.json` under `evidence/`. The first used `/tmp/myterm-188-accepted-build`; the others used `/tmp/myterm-188-complete-build`. The first two used probe SHA-256 `1c673d0001a574341e199f15fa9dc9825f6daf4a6b94e6e1473a9a60309009cb`. They record the original 34/76 matching comparisons and six rejected exports, not acceptance of the correction.

`INVESTIGATION.md`, `contract.html`, the first review reports, `virtual-record.json`, `verification.json` and `environment.json` preserve the original investigation. The supplementary JSON files were captured by ad hoc commands, and the environment was recorded after those trace runs. They have no dedicated runner and do not replace the final evidence.
