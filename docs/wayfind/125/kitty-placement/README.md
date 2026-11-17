# Kitty placement records through reconnect

The bounded native correction for [Preserve scrolled-off Kitty placement records across reconnect](https://github.com/GordonBeeming/myterm/issues/186) transfers the live placement table independently of retained image cells. A fresh client keeps the placement after every stripe scrolls beyond its forty history lines. Deletion and reuse continue from that state.

`placement.patch` applies to the prepared checkpoint foundation at `ab4f866153ff46c03e1e51de72eec8d85d233d51`. All changes stay in disposable Rust and SwiftTerm sources. Production integration remains in [Validate production terminal checkpoints and native SwiftTerm reconnect](https://github.com/GordonBeeming/myterm/issues/189).

## Representation and limits

The Rust Kitty placement table owns identity and buffer membership even after cells disappear. Its `PlacementInfo` has a stable first row and dimensions, but lacks native record coordinates and stripe creation coordinates. The correction retains that metadata alongside the existing table. Scroll updates follow native SwiftTerm's first surviving cell; a record keeps its last position after its final cell disappears. Each stripe retains its separate creation coordinates. The diagram in `placement-records.html` shows the measured partial-stripe example and the alternative proposed during review.

The experiment admits up to 1,024 live placement records. It refuses a new placement before changing placement state once full; replacing an existing identity still works. Deleting one record frees a slot. This is an experiment limit, and its error path currently uses the Rust engine's logging rather than a new protocol acknowledgement. Production resource policy and user-visible limit handling still need acceptance.

The upstream cache prunes unreferenced images after a 320 MiB threshold; referenced images can prevent that from being a hard cap. Its placement table has no corresponding upstream count limit. The existing experiment already caps checkpoint caches at 32 images and 256 KiB decoded bytes, pending transmission at 128 chunks and 16 KiB, and encoded checkpoints at 1 MiB. The correction keeps those limits and adds producer/receiver checks for placement metadata. It uses no historical output replay to recover unseen placements. The full retained-cell scan on scroll has no new performance guarantee.

Native rasterization can scroll a normal buffer even when Kitty restores the cursor with `C=1`. The correction mirrors that behavior and refreshes the new placement after insertion. It also carries the normal cursor into the alternate buffer, matching native SwiftTerm.

## Reproduce

Use macOS with the repository's native Swift toolchain, Rust `1.99.1`, cached pinned WezTerm dependencies and Python with Pillow. The foundation's `run.py` prepares an unmodified pinned WezTerm source tree; pass that tree as `--baseline-source`. The retained foundation's README gives its download/build setup. Each output directory must be fresh. Preparation clones the dependency build cache into its own target directory.

```sh
python3 docs/wayfind/125/kitty-placement/prepare.py \
  --baseline-source /tmp/myterm-150-baseline-20261116/source \
  --output /tmp/myterm-placement-baseline --without-correction
python3 docs/wayfind/125/kitty-placement/prepare.py \
  --baseline-source /tmp/myterm-150-baseline-20261116/source \
  --output /tmp/myterm-placement-fixed
python3 docs/wayfind/125/kitty-placement/check.py \
  --build /tmp/myterm-placement-fixed \
  --old-client /tmp/myterm-placement-baseline/client \
  --evidence /tmp/myterm-placement-results
python3 docs/wayfind/125/kitty-placement/regression.py \
  --build /tmp/myterm-placement-fixed
```

The focused runner compares every checkpoint and subsequent delivery with an uninterrupted native SwiftTerm client, including image pixels, cache entries, placement metadata, both buffers and terminal replies. The old importer must drop the original scrolled record while keeping matching cached pixels. The bounded tests also check taller images placed at the bottom of a full normal buffer, single-record deletion after a full table, and replacement at capacity. Image-cell counts verify that rejected admission leaves cells unchanged and replacement removes the old stripes. Automatic placement IDs and oversized offsets produce checkpoint rejection and recover after deletion.

## Evidence and remaining failures

- `evidence/results.json`: 38 fresh-import/continuation comparisons pass, thirteen malformed receiver inputs are rejected, and placement admission/deletion/replacement checks pass.
- `evidence/regression-results.json`: 47 broader cases pass, two expected limit rejections, 28 receiver controls, native streaming and a real native PTY pass. These are headless native checks, with no GUI or mobile acceptance claim.
- `evidence/known-alternate-results.json`: five of 38 comparisons still fail when creating an image at the bottom of an alternate buffer whose unused native capacity survived a shrink. [Fix empty alternate-buffer resize and reconnect parity](https://github.com/GordonBeeming/myterm/issues/196) retains that failure and blocks production checkpoint acceptance. Run the focused command with `--exercise-empty-alternate-resize` to reproduce it. The passing suite explicitly homes the cursor before alternate image creation.
- `evidence/initial-expanded-failures.json` retains the earlier 21-pass/11-failure run. `evidence/initial-limit-timeout.json` retains the first resource-control timeout caused by overlapping 1,025 placements. The corrected control scrolls each placement away before creating the next.
- `evidence/initial-broad-failure.json` records one earlier 17-versus-18-pixel native image-width mismatch. The exact broader suite passed on repeat. Its cause remains unresolved; [Investigate intermittent native checkpoint raster width](https://github.com/GordonBeeming/myterm/issues/197) blocks production acceptance until it is explained. The successful repeat does not establish deterministic raster sizing.

The existing virtual/parent placement and shrink-reflow tasks remain open. Native Linux/Windows, real application integration and production memory/performance acceptance remain outside this bounded correction.

Claude reviewed the implementation and final coverage independently. The final report in `evidence/review-final.json` finds no blocking defects and closes the earlier coverage findings. Low-priority untested bounds and the stripe-owner guard remain recorded there; tall alternate placement remains part of the separate alternate-buffer task.
