# Native session adapters and terminal fidelity

This is a native macOS, Linux and Windows experiment for [Compare native session adapters and terminal fidelity](https://github.com/GordonBeeming/myterm/issues/138), recorded on 7 November 2026 AEST. It supports [Choose the standalone server boundary and runtime](https://github.com/GordonBeeming/myterm/issues/130). The prototype ticket remains open for Gordon's fidelity judgment; the native runner comparison is complete.

## Agreed scope

Go and Rust are candidates for the server side, including the macOS server. The Mac, iPhone and iPad **client** apps stay native. Gordon's clarification permits these server languages; it does not select a final runtime, emulator or mixed-language deployment. The experiment changes no client app or production server code.

The throwaway sources and commands live in [script/native-comparison](../../script/native-comparison/README.md). The [retained local evidence](myterm-native-comparison/20261107-macos-arm64.json) records the initial local toolchains, fixture hash, session results and projected engine differences. The [retained native-runner evidence](myterm-native-comparison/20261107-native-runners.json) records the passing four-platform run and its earlier failed attempts. The prototype is published in [the draft comparison PR](https://github.com/GordonBeeming/myterm/pull/148) and retained outside main.

## Native adapter results

[The verified native run](https://github.com/GordonBeeming/myterm/actions/runs/42367281598), at source commit `06d72ad61e6004dc18468c7d238dff7587eef0a1`, passes all 26 adapter cases and the startup-query unit test on all four runners. Each uses Go 1.26.0 and Rust 1.89.0. The Mac baseline uses Xcode 27.1 and Swift 6.4.

| Runner | Observed OS / CPU | Go cases | Rust cases |
| --- | --- | --- | --- |
| `xcode-27` | macOS 27.0.1, ARM64 | 4/4: geometry, sh, Bash, Zsh | 4/4: same cases |
| `ubuntu-24.04` | Linux 7.0.0-1017-azure, x86-64 | 3/3: geometry, sh, Bash | 3/3: same cases |
| `ubuntu-24.04-arm` | Linux 7.0.0-1017-azure, ARM64 | 3/3: geometry, sh, Bash | 3/3: same cases |
| `windows-2025` | Windows Server 2025, 10.0.26100, x86-64 | 3/3: geometry, cmd.exe, PowerShell | 3/3: same cases; one required startup cursor reply per case |

Go uses `creack/pty` 1.1.24 on Unix and `UserExistsError/conpty` 0.1.4 on Windows. Rust uses `portable-pty` 0.9.0. All four session stderr logs are empty. The earlier local macOS 27.3 ARM64 run with Go 1.26.6, Rust 1.89.0 and Swift 6.4.2 also passed its eight cases.

The C child verifies terminal stdin/stdout, input/output and actual 101×31 geometry. Unix additionally verifies foreground process-group ownership. Shell experiments recover output after an actual loopback client disconnect/reconnect with the same child PID. The delayed marker must be absent before disconnect and present in output retained before accepting a later observer request. They retain that output, then check exactly 65,536 payload bytes between fresh output-only markers before successful exit. Invalid capability tokens and invalid geometry are rejected.

These results establish the tested adapters' raw-output behavior. The retained bytes are not a terminal checkpoint. Beyond the explicit Windows startup handshake, the probe does not combine the emulator and adapter into a general server-owned query responder, and it does not test writer leases, multiple viewers, encrypted transports, server restarts, process-tree cleanup, service identities or upgrades. Shell resize calls pass; child-observed geometry is checked by the C fixture rather than asserted separately inside each shell.

## Terminal engine results

The engine experiment uses the vendored SwiftTerm as the baseline, Go `charmbracelet/x/vt` 0.1.0 and Rust `vt100` 0.18.1. Each receives the same 17 byte/resize traces. Every runner uses the same LF-normalized fixture hash. For both candidate engines, the measured state and final reply projection matches the same engine on the Mac runner across all platforms; this does not establish cross-engine fidelity. It compares visible cell contents, basic colors/styles, cursor, active buffer and final reply bytes. A match in those fields leaves image contents, scrollback equivalence, hyperlinks, input encoding and other modes unproven.

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

Both server languages remain viable after the native adapter checks. Rust offers one PTY API across the target platforms and needs the explicit Windows startup responder described below. Go uses separate Unix and Windows libraries. Actual native execution now supports this comparison; the earlier Go Windows cross-build alone did not establish these behaviors.

The Windows `portable-pty` implementation enables inherited-cursor mode. Its caller must asynchronously answer the startup cursor query, as documented by [CreatePseudoConsole](https://learn.microsoft.com/en-us/windows/console/createpseudoconsole). The Rust adapter answers that one request at the known origin of a fresh empty terminal and records the count. This required adapter behavior is separate from the still-unimplemented application-query policy in the Rust engine experiment. The earlier native run blocked before child output without the reply.

Neither tested terminal engine has demonstrated a drop-in replacement for MyTerm's current terminal behavior. A language decision must account for terminal-state ownership, server-side query responses, mode negotiation, supported graphics, authoritative geometry and bounded reconnect state. Retaining native clients does not require a Swift server, but replacing the server engine can still change what those clients display after reconnect.

The runtime decision should compare the cost of extending these engines, evaluating a richer portable engine, or retaining SwiftTerm behind a tested portable boundary. This experiment does not choose among those paths or claim a SwiftTerm worker already runs on native Windows. The open runtime decision already owns that choice; no duplicate decision ticket is needed.

## Verification and remaining evidence

The local command is:

```sh
python3 script/native-comparison/run.py --output /tmp/myterm-native-comparison
```

Additional checks cover graceful termination of a still-running shell for both adapters, `go vet`, Go's race-enabled trace run, Rust Clippy with warnings denied, Go Windows x86-64 cross-build, and workflow validation with `actionlint`. Native adapter experiments are meaningful integration checks; trace equality is limited to its stated projection. No GUI was controlled and no release or infrastructure deployment occurred.

The first native attempt exposed a macOS Bash wrapper failure, inherited nonblocking socket mode on Windows and a PowerShell marker split by ConPTY soft wrapping. The next run passed Mac, Linux and Windows Go, but exposed Rust's inherited-cursor startup requirement. The final verified run passes all 26 cases after those probe corrections. The retained evidence links each attempt and its actual outcome.

Reproduce the captured comparison from the published source and downloaded artifacts:

```sh
gh run download 42367281598 --repo GordonBeeming/myterm --dir /tmp/myterm-native-ci
python3 script/native-comparison/report.py --results /tmp/myterm-native-ci/native-comparison-xcode-27 --ci-results /tmp/myterm-native-ci --ci-run-url https://github.com/GordonBeeming/myterm/actions/runs/42367281598 --output /tmp/myterm-native-comparison.html
```

The workflow retains raw JSON and logs for fourteen days. The committed summary preserves OS/CPU/toolchains, exact case results, fixture identity, checkpoint counts and measured engine differences. The HTML report embeds the captured data and shows cells, basic style differences and Rust's actual formatted-state reconstruction; CI mode uses the Mac runner artifact as its inspector baseline.

Before resolution, review query responses, graphics gaps and checkpoint semantics with Gordon and record his fidelity judgment on the prototype ticket. The server runtime and terminal-state strategy remain decisions for the open runtime ticket. No merge, release or deployment is authorized by this comparison.

## Primary references

- [Native-server implementation research](myterm-next-native-server.md) supplies the candidate rationale and current architectural seams.
- [Go VT API](https://pkg.go.dev/github.com/charmbracelet/x/vt@v0.1.0) documents the evaluated emulator's public surface.
- [Go ConPTY binding](https://github.com/UserExistsError/conpty/tree/v0.1.4) supplies the Windows candidate implementation.
- [portable-pty 0.9.0](https://docs.rs/portable-pty/0.9.0/portable_pty/) documents the Rust process abstraction.
- [vt100 0.18.1](https://docs.rs/vt100/0.18.1/vt100/) documents the evaluated Rust parser and formatted-state functions.
