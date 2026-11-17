# Alternate-buffer resize and reconnect

This bounded correction addresses [Fix empty alternate-buffer resize and reconnect parity](https://github.com/GordonBeeming/myterm/issues/196). It changes disposable SwiftTerm and Rust experiment sources through `resize.patch`. Production sources are unchanged; integration remains in [Validate production terminal checkpoints and native SwiftTerm reconnect](https://github.com/GordonBeeming/myterm/issues/189).

## Measured behavior

An alternate buffer has capacity for exactly the viewport rows and no history, whether it was populated before resizing or first activated afterward. The unused native buffer previously retained excess capacity after shrinking. At the bottom row, image rasterization could then grow alternate history that a fresh checkpoint import did not have.

The correction also matches the existing native image behavior for `C=1`: image rasterization can scroll, then the cursor is restored. In a six-row buffer, a one-row image created at row five occupies row four afterward. A three-row image occupies rows two through four. These coordinates are zero-based. With the tested two-column placement at column two, `C=0` leaves the cursor at column four, row five; `C=1` restores column two, row five. Deleting the placement removes its cells and record while retaining cached image pixels.

Repeated `1049` entry saves the active buffer's cursor even when the alternate buffer is already active. Alternate saved rows follow top trimming during shrink. Unlike normal saved rows, they can remain below the current viewport when blank rows below the live cursor are removed. The bridge preserves those rows within the experiment's 1,000-row bound; restoring the cursor clamps it to the viewport. Current cursor coordinates remain viewport-bounded. Normal saved-row validation is unchanged.

## Reproduce

Use macOS, the native Swift toolchain, Rust `1.99.1`, cached pinned WezTerm dependencies and Python with Pillow. The retained checkpoint foundation describes how to prepare the unmodified dependency source. Every output directory must be fresh.

```sh
python3 docs/wayfind/125/alternate-resize/prepare.py \
  --baseline-source /tmp/myterm-150-baseline-20261116/source \
  --output /tmp/myterm-alternate-resize
python3 docs/wayfind/125/alternate-resize/check.py \
  --build /tmp/myterm-alternate-resize \
  --output /tmp/myterm-alternate-matrix.json.gz
python3 docs/wayfind/125/alternate-resize/check.py \
  --build /tmp/myterm-alternate-resize \
  --fixture-file docs/wayfind/125/alternate-resize/evidence/original-fixtures.json \
  --output /tmp/myterm-alternate-original.json.gz
python3 docs/wayfind/125/alternate-resize/controls.py \
  --build /tmp/myterm-alternate-resize \
  --output /tmp/myterm-alternate-controls.json
python3 docs/wayfind/125/kitty-placement/regression.py \
  --build /tmp/myterm-alternate-resize
CARGO_TARGET_DIR=/tmp/myterm-alternate-resize/cargo-target \
  cargo +1.99.1 test --offline \
  --manifest-path /tmp/myterm-alternate-resize/native/probe/Cargo.toml
```

Preparation replays the accepted placement, column-reflow and Kitty corrections, then applies this patch without fuzz. `alternate-build.json` records source hashes before and after the patch, final executable hashes and the patch hash. `foundation-graphics-build.json` describes the intermediate build before this correction; its executable hashes are superseded by the final manifest.

The runner compares every checkpoint and its subsequent deliveries against uninterrupted native SwiftTerm, including both buffers, images, placement records, saved/live cursors and terminal replies. It independently checks native and imported alternate capacity, bottom-image behavior and deletion. Empty native buffers and allocated blank imported rows are compared as equivalent logical blank content; capacity and history checks still apply to both.

## Evidence and limits

The final matrix covers 39 traces, 473 checkpoint cuts and 3,311 import/continuation comparisons, with 473 native capacity checks and 64 independent image/deletion checks. It includes unused and populated resizes, inactive buffers, both `1047` and `1049`, repeated entry, one- and three-row images, `C=0` and `C=1`, explicit cursor save/restore, column-only resize, growth above the initial height and reset.

Replaying the unchanged original fixtures passes all 38 checkpoint cuts and 89 continuation comparisons. `evidence/matrix.json.gz`, `before.json.gz` and `original-fixed.json.gz` record the same runner hash; `verification.json` checks it against the retained `check.py`.

The unchanged build fails at 233 of the matrix's 473 cuts, with 143 failed native capacity checks. On the focused original-bug trace, combining the corrected Swift client with the old Rust server still fails four cuts; combining the old Swift client with the corrected Rust server also fails four cuts. Both changes are required. The original reproduction remains in `kitty-placement/check.py --exercise-empty-alternate-resize`; its five failures are preserved in `evidence/original-red.json`.

The seven malformed-coordinate controls reject negative or excessive alternate saved rows, invalid normal saved rows and invalid current cursor positions. Two boundary controls retain saved row 999 and clamp it to row two on restore into a three-row viewport.

Two additional controls shrink a populated alternate buffer by three rows with the live cursor at the bottom. Saved rows four and five become one and two; restoring them agrees with uninterrupted native execution. The broader checkpoint suite passes 49 cases, two expected limit rejections and 28 receiver controls, including native streaming and a real native PTY. Both probe unit tests pass; the native comparison matrix provides the coverage for the resize changes.

These are headless native macOS engine checks. They do not establish production integration, live-window rendering, Retina, mobile, multi-Mac or native Linux/Windows acceptance. The separate raster-width investigation remains open. No release or deployment is part of this correction.
