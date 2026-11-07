# Native session adapters and terminal fidelity

This is a local macOS ARM64 experiment for [Compare native session adapters and terminal fidelity](https://github.com/GordonBeeming/myterm/issues/138), recorded on 7 November 2026 AEST. It supports [Choose the standalone server boundary and runtime](https://github.com/GordonBeeming/myterm/issues/130). The prototype ticket remains open: Linux and native Windows execution, plus Gordon's fidelity judgment, are still required.

## Agreed scope

Go and Rust are candidates for the server side, including the macOS server. The Mac, iPhone and iPad **client** apps stay native. Gordon's clarification permits these server languages; it does not select a final runtime, emulator or mixed-language deployment. The experiment changes no client app or production server code.

The throwaway sources and commands live in [script/native-comparison](../../script/native-comparison/README.md). The [retained local evidence](myterm-native-comparison/20261107-macos-arm64.json) records toolchains, fixture hash, session results and projected engine differences. Raw JSON is also produced by every run. The workflow is prepared but has not been published or executed for this comparison.

## Native adapter results

On macOS 27.3 ARM64 with Go 1.26.6, Rust 1.89.0 and Swift 6.4.2, both candidates pass four native experiments: the C geometry child, `/bin/sh`, Bash and Zsh. The Go adapter uses `creack/pty` 1.1.24; Rust uses `portable-pty` 0.9.0. Go's Windows adapter uses `UserExistsError/conpty` 0.1.4, with execution still pending.

The C child verifies terminal stdin/stdout, foreground process-group ownership, input/output and actual 101×31 geometry. Shell experiments recover output after an actual loopback client disconnect/reconnect with the same child PID. The delayed marker must be absent before disconnect and present in output retained before accepting a later observer request. They retain that output, then check exactly 65,536 payload bytes between fresh output-only markers before successful exit. Invalid capability tokens and invalid geometry are rejected.

These results establish the tested adapters' raw-output behavior. The retained bytes are not a terminal checkpoint. The probe does not combine the emulator and adapter into a server-owned query responder, and it does not test writer leases, multiple viewers, encrypted transports, server restarts, process-tree cleanup, service identities or upgrades. Shell resize calls pass; child-observed geometry is checked by the C fixture rather than asserted separately inside each shell.

## Terminal engine results

The engine experiment uses the vendored SwiftTerm as the baseline, Go `charmbracelet/x/vt` 0.1.0 and Rust `vt100` 0.18.1. Each receives the same 17 byte/resize traces. It compares visible cell contents, basic colors/styles, cursor, active buffer and final reply bytes. A match in those fields leaves image contents, scrollback equivalence, hyperlinks, input encoding and other modes unproven.

| Case | Go engine | Rust engine |
| --- | --- | --- |
| ASCII, cursor movement, split UTF-8/CSI/OSC while parsing continuously | Matches measured baseline fields | Matches measured baseline fields |
| Representative CJK, combining accents, emoji, ZWJ and flag trace | Matches measured baseline fields | Cell/cursor differences |
| Styled text and colors | Matches measured baseline fields | Matches measured baseline fields |
| Alternate screen return during uninterrupted parsing | Matches measured baseline fields | Matches measured baseline fields |
| Alternate screen shrink/grow | Cell/cursor differences | Cell differences |
| Scrollback-producing output followed by resize | Visible-state differences | Matches visible-state fields; history equivalence remains unproven |
| Cursor/status queries | Cursor replies match; status reply differs | No replies emitted by this probe |
| Kitty keyboard negotiation | No query replies emitted | No query replies emitted |
| Kitty RGBA image transmission/placement | No acknowledgment; text/cursor differences | No acknowledgment; text/cursor differences |
| Full Sixel image positive control | Text/cursor differences; image preservation not demonstrated | Text/cursor differences; image preservation not demonstrated |
| iTerm PNG image positive control | Text/cursor differences; image preservation not demonstrated | Text/cursor differences; image preservation not demonstrated |

For the query trace, SwiftTerm emits `ESC [ 3 ; 7 R`, `ESC [ 0 n`, then the cursor reply again. Go emits `ESC [ ? 0 n` for the status reply. Rust's parser is used without an added responder, so the missing replies identify adapter work rather than a limit of Rust as a language. SwiftTerm also emits Kitty keyboard flags and an image acknowledgment that neither candidate probe emits.

### Checkpoints and reconnection

SwiftTerm passes all 35 full binary-checkpoint equality checks, including continuation after partial input, alternate-buffer state and retained images. A fresh native terminal imports each checkpoint and receives the same subsequent bytes and resizes. This measures the existing implementation's checkpoint behavior, not compatibility with either candidate.

For Rust, `state_formatted` restores the measured ordinary visible state, but continuation fails for the split UTF-8, CSI and OSC traces. Alternate-screen reconstruction also fails. The formatted state cannot be treated as a full parser checkpoint. Those checks compare projected cells/styles/cursor/buffer, so even a successful reconstruction does not establish all-mode or image continuity.

Rust reply parity is marked unimplemented for traces without expected replies; it is never treated as a successful responder check.

The Go experiment retains `Render` output for inspection and does not implement or verify a full parser checkpoint export. Reconnect fidelity for that engine therefore remains unproven. Replaying an unbounded byte history would be a different strategy with separate storage, reply suppression and ordering requirements.

### Graphics baseline caveat

The positive controls retain one SwiftTerm image stripe for iTerm PNG, one for the completed Kitty placement and seven for the full Sixel sample. The harness fails if those images are absent. It does not count matching text cells as graphics parity.

The split Sixel trace produces no image in the current baseline, even though its checkpoint round-trip equality holds. The retained `sixel-full-split` fixture uses exactly the positive-control sample bytes, split before the terminator; it also produces no image, while the unsplit sample retained seven stripes. That baseline behavior needs investigation; this prototype does not fix it or use empty image state to approve a replacement engine.

## Adapter effort and decision implications

Both server languages remain viable after the local adapter checks. Rust offers one PTY abstraction across the target platforms; Go uses separate Unix and Windows libraries. Native Windows runs are still needed to compare their actual ConPTY lifecycle and shell behavior. Passing a Go Windows cross-build does not establish any of those behaviors.

Neither tested terminal engine has demonstrated a drop-in replacement for MyTerm's current terminal behavior. A language decision must account for terminal-state ownership, server-side query responses, mode negotiation, supported graphics, authoritative geometry and bounded reconnect state. Retaining native clients does not require a Swift server, but replacing the server engine can still change what those clients display after reconnect.

The runtime decision should compare the cost of extending these engines, evaluating a richer portable engine, or retaining SwiftTerm behind a tested portable boundary. This experiment does not choose among those paths or claim a SwiftTerm worker already runs on native Windows. The open runtime decision already owns that choice; no duplicate decision ticket is needed.

## Verification and remaining evidence

The local command is:

```sh
python3 script/native-comparison/run.py --output /tmp/myterm-native-comparison
```

Additional checks cover graceful termination of a still-running shell for both adapters, `go vet`, Go's race-enabled trace run, Rust Clippy with warnings denied, Go Windows x86-64 cross-build, and workflow validation with `actionlint`. Native adapter experiments are meaningful integration checks; trace equality is limited to its stated projection. Independent Claude Sonnet review found no unresolved actionable findings after the probe assertions were corrected. No GUI was controlled and no release or infrastructure deployment occurred.

Before resolution, publish the prepared probe workflow and retain actual macOS ARM64 on the repository's pinned Xcode runner, Linux x86-64/ARM64 and Windows x86-64 results. Investigate platform failures rather than substituting cross-builds. Review query responses, graphics gaps and checkpoint semantics with Gordon, then record his judgment on the prototype ticket. The map's authorization covers earlier migration material, not this new publication, so the current session leaves source-control writes pending explicit authorization.

## Primary references

- [Native-server implementation research](myterm-next-native-server.md) supplies the candidate rationale and current architectural seams.
- [Go VT API](https://pkg.go.dev/github.com/charmbracelet/x/vt@v0.1.0) documents the evaluated emulator's public surface.
- [Go ConPTY binding](https://github.com/UserExistsError/conpty/tree/v0.1.4) supplies the Windows candidate implementation.
- [portable-pty 0.9.0](https://docs.rs/portable-pty/0.9.0/portable_pty/) documents the Rust process abstraction.
- [vt100 0.18.1](https://docs.rs/vt100/0.18.1/vt100/) documents the evaluated Rust parser and formatted-state functions.
