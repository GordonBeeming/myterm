# Cursor-line resize parity

The retained correction for [Align column-zero shrink reflow with native SwiftTerm](https://github.com/GordonBeeming/myterm/issues/188) makes the Rust checkpoint candidate preserve the physical rows of the logical line containing the cursor. SwiftTerm leaves that line for the application to redraw. Shrinking truncates its normal-buffer rows; alternate-buffer hidden cells survive. Reflow still applies to surrounding output.

For `ABCDEFGHIJKLMNOPQRST` followed by carriage return, shrinking from twenty columns to ten now retains `ABCDEFGHIJ` on the same row. It discards the suffix, matching uninterrupted native SwiftTerm. A subsequent write replaces the first character, and widening does not restore the discarded suffix.

The experiment builds the immutable checkpoint foundation at `ab4f866153ff46c03e1e51de72eec8d85d233d51`, applies the retained Kitty placement correction, then applies `reflow.patch`. Changes affect disposable sources only. Production integration and acceptance remain in [Validate production terminal checkpoints and native SwiftTerm reconnect](https://github.com/GordonBeeming/myterm/issues/189).

## State that resize preserves

The cursor's logical line keeps its continuation flags through truncation. When it later loses the cursor, concatenation accounts for the old viewport width between its physical rows. A change in dimensions clamps the logical live and saved cursor columns and clears pending wrap. A notification with unchanged dimensions preserves terminal state. Saved normal-buffer cursor rows follow their distance from the live cursor, as in SwiftTerm's `resizeBuffers`. Restoring a cursor clamps the saved logical column and clears pending wrap.

The first retained history row carries an independent incoming continuation flag, including after scroll, history erasure, viewport erasure and reset. Inactive live cursors are stored separately from saved cursors. Exiting alternate modes that clear their buffer also clears its retained text and cursor state. Width changes with existing history keep the trailing blank viewport rows. Import permits a width-two lead cell in the final stored column because native shrink can leave that state; repetitions, overlaps and other out-of-range geometry remain rejected.

## Reproduce

Run headlessly on macOS with the native Swift toolchain, Rust `1.99.1`, Python with Pillow and the cached pinned WezTerm source/dependencies. No app window or Simulator is controlled. The foundation's retained `script/wezterm-feasibility/README.md` at the pinned revision describes baseline preparation. Output directories must be fresh.

```sh
python3 docs/wayfind/125/column-zero/prepare.py \
  --baseline-source /tmp/myterm-150-baseline-20261116/source \
  --output /tmp/myterm-column-zero
python3 docs/wayfind/125/column-zero/check.py \
  --build /tmp/myterm-column-zero \
  --output /tmp/myterm-column-zero-results.json.gz
python3 docs/wayfind/125/column-zero/controls.py \
  --build /tmp/myterm-column-zero \
  --output /tmp/myterm-column-zero-controls.json
python3 docs/wayfind/125/kitty-placement/regression.py \
  --build /tmp/myterm-column-zero
```

`check.py --case normal-single-zero` runs just the original sequence and its additional resize cycles. Every checkpoint imports into a fresh native SwiftTerm instance and compares all subsequent snapshots with an uninterrupted native reference, including both buffers, hidden cells, continuation flags, cursor state, saved cursor and terminal replies. Cell geometry is fixed at 9 by 16 pixels for these text-only traces. This is a headless native engine comparison, with no GUI, iPhone, iPad, Linux or Windows acceptance claim.

## Evidence

The initial minimal trace in `evidence/red.json.gz` fails six of twenty comparisons. `baseline-matrix.json.gz` and `candidate-matrix.json.gz` retain the first expanded baseline and correction runs; both fail. Later failed candidates remain compressed in the evidence directory so a successful result cannot erase their failures.

The final clean build passes 57 cases and 1,380 checkpoint/continuation comparisons. All ten new malformed inputs are rejected. The foundation suite passes 47 cases with two expected limit rejections and 28 receiver controls; native streaming and a real PTY pass. The placement suite passes 38 comparisons. `evidence/summary.json` records the counts, and `evidence/run.json` confirms that the built sources match the reviewed scratch sources by SHA-256.

Claude's final review in `evidence/review-final.json` finds no blocking defect. Earlier review findings and their failing tests remain in the evidence directory. The final review's fresh-build verification condition is satisfied by the source hashes and passing suite. The matrix covers cursor column zero, other columns, pending wrap, blank-column cursors, normal and alternate buffers, wrapped cursor groups, a wide character crossing the shrink boundary, moving the cursor away, history capacity boundaries, shrink/grow cycles, erase/reset and subsequent output. The receiver controls exercise the permitted wide-cell boundary and ten malformed inputs. The broader foundation suite checks terminal streaming and a real native PTY in addition to checkpoints.

The separate Kitty virtual/parent placement, empty alternate-buffer image and intermittent raster-width tasks remain open. This text resize correction does not establish those image guarantees or production resource limits.
