# Local macOS wezterm-term feasibility prototype

The initial throwaway gate compares a real headless wezterm-term instance with the vendored native SwiftTerm baseline. The later bounded checkpoint experiment adds a partial Rust-to-SwiftTerm bridge. Neither implements a production server.

```sh
python3 script/wezterm-feasibility/run.py --output /tmp/myterm-wezterm-new-run
python3 script/wezterm-feasibility/report.py --results /tmp/myterm-wezterm-new-run --output /tmp/myterm-wezterm-report.html
```

Use a fresh output directory. Requirements: native macOS, Xcode/Swift, Python 3.12+, curl and the installed Rust 1.99.1 toolchain. The runner downloads public source archives over verified HTTPS and builds locally. It runs no GitHub workflows and opens no windows. Each build/process is bounded by a timeout; compilation needs network access to crates.io.

Wezterm is pinned to `458a100c1bf4134d36cb5c42dd90e4c8266d9e1a`. Its finl_unicode dependency uses the exact upstream lockfile revision `a1892f26245529f2ef3877a9ebd610c96cec07a6`. The runner replaces that Git dependency declaration with an extracted source path to the same revision, leaving emulator code unchanged. The probe's Cargo.lock pins the resolved crate graph. This was built in Debug with Kitty graphics and keyboard enabled and a 40-line server scrollback configuration. SwiftTerm uses its retained baseline configuration; the history trace stays within both histories' limits. Candidate pixel geometry comes from the SwiftTerm view's actual cell measurement.

The runner executes 17 retained traces, 35 SwiftTerm checkpoint positive controls and two focused Rust tests. One test verifies a detached server's cursor/status replies, including a fragmented query. The other documents that an injected query-writer failure is not propagated by wezterm-term's `advance_bytes` API. A production embedding would need independent writer-failure capture. Five invalid-input cases must exit unsuccessfully with diagnostics and no result JSON.

`comparison.json` checks cells, basic styles, cursor, active buffer, history count and reply bytes after every event. Different traces remain findings for human judgment; they do not make the command fail. Command success means the experiment completed. It never means full terminal fidelity or reconnect acceptance. Source/build failures, failed positive controls and malformed evidence fail the run.

The image counters use different models: SwiftTerm image stripes and wezterm image cells. Their values cannot establish image equivalence. A blank split-Sixel baseline is a known existing limitation, not a graphics positive control. Modes and hyperlinks are not compared for equivalence. No screenshot/pixel comparison, PTY integration, reconnect initialization, concurrent resize/live-output ordering or replay-side-effect suppression is implemented.

The retained unpatched run is in `docs/research/myterm-wezterm-feasibility/macos-local`. It has 11 projection matches and six differing traces, with all 35 SwiftTerm controls and both Rust tests passing. The five invalid-input cases are rejected. The process resource observation is a single Debug trace run, not a performance budget. Full bounded reconnect and the target platforms beyond macOS remain pending. The ticket stays open for Gordon's judgment.

Wezterm-term declares MIT; finl_unicode declares `(MIT OR Apache-2.0) AND Unicode-DFS-2016`. Transitive dependency distribution obligations still need review before shipping. No production app, release, deployment or source-control publication is part of this gate.

## Local compatibility experiment

After producing a complete baseline output directory with `run.py`, apply the retained experimental patches to new scratch copies:

```sh
python3 script/wezterm-feasibility/compatibility.py --baseline-results /tmp/myterm-wezterm-new-run --output /tmp/myterm-wezterm-compat-new-run
python3 script/wezterm-feasibility/report.py --results /tmp/myterm-wezterm-compat-new-run --before-results /tmp/myterm-wezterm-new-run --output /tmp/myterm-wezterm-compat-report.html
```

This uses native macOS APFS clone copies and the already downloaded sources. It builds locally, without GitHub workflows. Keep the baseline directory: it supplies source archives, the pinned dependency and the original evidence. The script checks its fixture and Swift driver hashes, applies patches with failure checking, and rejects reused output directories. It does not edit `Vendor/SwiftTerm` or the production app.

`wezterm-compatibility.patch` changes three upstream Rust files. It preserves alternate-buffer columns hidden by shrinking; clamps resized cursor positions; stops normal-buffer reflow from moving a genuine column-zero cursor to the previous line; places the cursor after image rows while preserving the native iTerm column policy; and adds Kitty identity/placement acknowledgements with quiet-mode handling and one acknowledgement for combined transmit/display. New placement writes propagate failures into the existing engine error path; the upstream public API still needs a complete embedding error contract.

`swift-dcs-finalization.patch` applies only to the scratch SwiftTerm copy. It finalizes a DCS handler even when the terminating chunk contains no new payload. The original baseline remains retained and visible in the report. This corrects a baseline limitation; it does not make the Rust candidate discard images to mimic that limitation.

The retained compatibility run is in `docs/research/myterm-wezterm-feasibility/macos-compatibility`. Patched Rust matches 15 of the original baseline's 17 measured trace projections. The two remaining differences are Sixel split immediately before its terminator. Against the scratch SwiftTerm parser correction, all 17 projections match. Both engines retain a positive image count and equivalent measured state for the complete split/unsplit Sixel within their own representation. The nine additional traces in `compatibility-fixtures.json` cover minimized resize/image cases, Kitty transmit and placement replies, combined transmission, quiet replies, cursor suppression and multirow placement. All nine match. Both focused Rust tests and all 35 SwiftTerm checkpoint controls pass.

Unlike the exploratory baseline runner, `compatibility.py` exits unsuccessfully if any corrected trace or added control differs, or if either engine loses its split-Sixel positive control. These checks do not establish cross-engine image pixels, complete hidden state or bounded reconnect. General Kitty errors, image offsets/scroll regions, wider resize sequences and production resource budgets remain outside this small experiment. Carrying these source patches would incur maintenance or require upstream adoption; they have not been selected for production.

Independent review exposed an extra newline in Sixel mode 8452. The retained Rust patch preserves that mode's existing rightward placement. The gate now also checks 21 normal-buffer wrap/resize/output suffixes against the unmodified engine, the Sixel mode case, and a hidden-column scenario through 1,000 columns. Hidden cells and stored row widths are captured explicitly, and the 999 written characters must survive each subsequent resize without duplication. Historical width persists after shrinking. This is a content-retention observation, not a production retention bound; image-byte budgets remain open; the partial checkpoint experiment is described below.

The query sink uses a deterministic FIFO drain. Wezterm-term queues writes to a background thread, so reading the sink immediately after parsing can lose a late reply. The probe queues an ASCII marker through the real public paste API into its capture-only writer, waits up to two seconds for it, then strips precisely the marker and any bracketed-paste delimiters before recording replies. It sends no marker to a PTY and feeds none back through the terminal parser. The injected-writer test waits for an observed write attempt. Earlier undrained captures are retained as superseded evidence, not accepted reply measurements.

A placement may already exist when acknowledgement delivery fails. The embedding must report that delivery failure without promising rollback; the engine's asynchronous writer and logging paths do not yet provide a complete production error contract. The experiment does not hide that requirement by discarding the failure.

Kitty's [graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) specifies placement acknowledgement and cursor movement by the placement's column and row counts. The experiment keeps the measured native iTerm behavior; the [iTerm image documentation](https://iterm2.com/documentation-images.html) describes its size requests but does not settle this cursor-policy comparison.

## Bounded checkpoint experiment

The custom exporter and native importer are a throwaway macOS feasibility prototype. They operate on new scratch copies, retaining the compatibility changes above. Production `Vendor/SwiftTerm` and the application are unchanged.

```sh
python3 script/wezterm-feasibility/run.py --output /tmp/myterm-reconnect-baseline
python3 script/wezterm-feasibility/checkpoint.py --source /tmp/myterm-reconnect-baseline/source --output /tmp/myterm-checkpoint
python3 script/wezterm-feasibility/checkpoint_report.py --results /tmp/myterm-checkpoint --before-results docs/research/myterm-wezterm-feasibility/macos-checkpoint --output /tmp/myterm-checkpoint.html
```

Use fresh output directories and native macOS. The native toolchains need ordinary compiler-cache/SDK access. `--resume-build` resumes an interrupted scratch build before results exist; source changes should use a new build directory. Cargo starts from the retained lockfile and resolves the additional dependency edges offline. The PTY probe uses the already locked libc version. No Windows/Linux build or hosted workflow runs here.

The strict gate now has 47 passing restoration cases, no fidelity differences or unexpected unsupported cases, and two intentional limit rejections. It also exercises 28 malformed-state controls, five positive controls, the 26-state native pipe workload and a real native PTY. The complete review-fix capture lives in `docs/research/myterm-wezterm-feasibility/macos-review-closure-20261116`. The preceding 36-case capture remains in `macos-checkpoint-fidelity`, and the earlier seven-failure run remains in `macos-checkpoint`. Counts, observations, input hashes and reviewer scope are retained with each run.

The command exits unsuccessfully if a required restoration case differs, an unexpected unsupported state appears, a failure/positive control breaks, an earlier engine projection changes, or the real PTY workflow fails. It retains diagnostic evidence for fidelity differences. All 17 earlier engine projections, both native Rust tests and seven existing Python harness regression tests remain checked.

### State and capacity

The version 2 format carries both buffers, bounded normal history, grapheme cells and widths, styles, hyperlinks, current and saved cursors, saved wrap modes, last-print location, per-buffer margins, tabs, cursor style, keyboard stacks and retained image resources. It retains only unfinished UTF-8/CSI/OSC/Sixel input and bounded semantic records of an unfinished direct Kitty transfer. Full session output is never replayed to initialize a new client.

Adjacent identical single-width cells use bounded runs. The dense 120×40 workload with 40 history lines now fits under the unchanged 1 MiB encoded cap. The oversized unfinished-token and over-budget allocated-cell cases remain deliberate failures. Other experimental limits include 16 KiB unfinished input, 1,000 columns/rows, 100,000 padded cells, 40 normal history lines, bounded image resources/decoded bytes and a native stripe-raster budget. These do not bound the engine's entire memory or define production budgets.

`checkpoint_compatibility.py` explicitly extends scratch Rust state for saved modes, last-print location, per-buffer margins and image requests. It preserves the existing native hyperlink boundary behavior, aligns scroll-blank attributes and Sixel HLS quantization, and keeps a base entry in keyboard stacks. Its scratch Swift correction makes full-width horizontal margins follow a widening viewport while preserving narrower explicit margins. These source changes require maintenance or upstream adoption; they are not concealed as an unmodified library capability.

The native importer builds its defaults/grapheme map from a separate new terminal and disconnects delegate callbacks during import. A control verifies that old text, a multi-codepoint grapheme, palette, cursor style and keyboard state changed before import and were replaced afterward. This experimental importer deliberately uses fixed default options and 40 history lines, rather than inheriting arbitrary configured view state.

### Image evidence

Resources come from actual retained Rust image cells/cache state. Original encoded image bytes and size requests are preserved where available; decoded RGBA resources retain their dimensions. The client uses the real native renderer and actual fractional cell geometry to construct native stripes. PNG source dimensions and decoded/raster budgets are checked before rendering.

The gate compares decoded RGBA hashes, stripe dimensions/positions and Kitty placement/cache state. Positive controls require images to remain present. Cases cover Sixel, valid nonuniform PNG, the retained legacy PNG fixture, unfinished and completed Kitty RGBA transfers, cached images with no initial placement, reuse after reconnect and deletion. The legacy PNG has an invalid IDAT CRC accepted by the native platform decoder; retaining its original encoded bytes preserves that measured behavior without claiming Rust validated its pixels.

### Real PTY continuity

`checkpoint-pty.rs` opens a real native PTY and spawns a disposable `/bin/sh` owned by the same Rust process as the emulator. A fresh SwiftTerm process acknowledges checkpoint import before the owner resizes the PTY and continues the shell. The shell reports its actual PID and `stty size`, and consumes real cursor replies. Exactly one authoritative Rust response is required per query. The client observes replies but never sends them to the PTY. The probe checks shell survival across import, actual 32×8 resizing, continued state/reply equivalence and a clean exit.

The native pipe workload independently checks strict next-sequence delivery across output and resize. Neither test claims a network transport, guaranteed simultaneous scheduling during import, a production control lease or multi-Mac acceptance.

### Verification boundaries

Receiver failures require exit status 1 and their intended diagnostic; a crash does not count as rejection. Valid twins accompany the mutated state/delivery/stream controls. Comparison-harness controls verify that styled blanks and pen changes remain visible. Input lines/requests are bounded before decoding; the live PTY exposed and corrected a full-chunk-read deadlock that finite fixtures had not caught.

Comparisons inspect selected native state, including pen, saved cursor/modes, tab width, working directory, cursor style, keyboard state, viewport row, image pixels and Kitty cache/placement identities. They normalize default color variants and unused blank allocation; meaningful hidden cells and styles are retained. Optimization/access counters and every possible terminal extension are not equated across engines.

Unrepresented terminal extensions, animations, arbitrary graphics overlaps/crops, parent/relative Kitty placements, automatic identity allocation and production eviction behavior still require explicit validation. Named bounds fail visibly; unsupported-state detection is not exhaustive. Security transport, generation changes, slow-reader recovery, client view refresh and broader application workloads belong to subsequent integration work. Local Debug timing/resource observations are not release budgets.

Independent review and its actual checks are recorded with the evidence. A green local gate demonstrates the selected bounded native workflows; it is not production/release acceptance or Linux, Windows, iPhone, iPad or multi-Mac validation. No commit, push, release or deployment is performed by these commands.

## Independent review follow-up

The expanded gate adds full-history row shrink, saved-column shrink, a query split at import, unfinished Kitty transmit-and-display, image metadata reset after 70 images in a 100-row viewport, and replacement of the same Kitty placement in both buffer directions. Two more receiver controls reject non-Sixel DCS tokens and geometry that disagrees with the native view.

The scratch Rust corrections trim resized history while preserving stable row identities, clamp saved columns and preserve a cursor positioned on an otherwise blank line. Full reset clears the image-request overflow state. The upstream pending transmit-and-display serializer emits `a=Q`; the scratch patch corrects it to `a=T`. Placement records now retain their owning buffer, and the importer excludes stale image cells from the previous owner. The scratch Swift resize correction also clamps a saved row that could otherwise become negative after shrinking full history.

The latest run passes 47 restoration cases, 28 intended-diagnostic receiver controls, five positive controls, both intentional limit rejections, the 26-state stream and the live PTY continuation. Both Rust tests and the seven Python harness tests pass. All 17 earlier engine projections remain unchanged. Its largest checkpoint is 137,400 bytes and its maximum observed import is 23.59 ms in one local Debug run.

The PTY harness routes only the Rust owner's replies to the shell. It does not implement or verify a production transport policy that prevents a client from writing its own replies. The split-query fixture checks continuation bytes and the absence of completed-query replay. Geometry acceptance is checked against the measured default native view; other fonts and display scales remain unvalidated. These limits carry into production integration acceptance.

The final follow-up also covers leaving the alternate screen, Kitty reset, scrolling every image away without RIS, and unfinished transmit-and-display with explicit placement, size, z-index and cursor policy. Declared unsupported automatic placement IDs and pending offsets/crops now reject at export; non-Sixel DCS has an exporter rejection control as well. All three boundary controls pass. Encoded and Kitty image resources must have their retained size request, so a discarded request cannot silently fall back to a different placement policy.

Native alternate-screen exit clears its placements and unused cache entries. RIS clears Kitty state. The placement-owner map prunes stale keys on insertion. These remain explicit scratch compatibility requirements.

Claude Sonnet verified all 19 prototype/baseline hashes and exercised its own native fixtures against the final binaries. It reported no material findings within this bounded experiment. It did not rebuild or rerun the full gate; its exact checks and limits are retained in `review-final.json`.

Known divergences remain outside the passing fixtures: the importer loses placement records after their cells scroll out of retained history; virtual and parent/relative Kitty placements can diverge without exhaustive rejection; and filling 20 columns, returning to column zero and shrinking to 10 columns can produce different cells across engines. These are open fidelity requirements for production integration. Passing the 47 selected cases does not resolve them.

## Accepted direction and open work

Gordon accepted the bounded macOS feasibility result and selected WezTerm plus the custom checkpoint bridge as the implementation direction. The prototype stays separate from production code. Remaining requirements are tracked explicitly:

- [Preserve scrolled-off Kitty placement records across reconnect](https://github.com/GordonBeeming/myterm/issues/186)
- [Resolve virtual and parent Kitty placement fidelity](https://github.com/GordonBeeming/myterm/issues/187)
- [Align column-zero shrink reflow with native SwiftTerm](https://github.com/GordonBeeming/myterm/issues/188)
- [Validate production terminal checkpoints and native SwiftTerm reconnect](https://github.com/GordonBeeming/myterm/issues/189)
- [Validate Linux and Windows terminal state and reconnect fidelity](https://github.com/GordonBeeming/myterm/issues/190)
