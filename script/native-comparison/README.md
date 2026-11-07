# Native session adapter comparison prototype

This throwaway experiment compares Go and Rust **server** candidates, including the macOS server. The Mac, iPhone and iPad client apps remain native and unchanged. It does not implement the production server, relay, synchronization protocol or writer leases.

Run from the repository root:

```sh
python3 script/native-comparison/run.py --output /tmp/myterm-native-comparison
```

On Linux or native Windows, omit the Mac-only SwiftTerm baseline:

```sh
python3 script/native-comparison/run.py --output comparison-results --skip-swift
```

The runner requires Python 3.10+, a C compiler, Go 1.26+ and Rust/Cargo. macOS baseline execution also needs Xcode and Swift 6. Windows uses Clang with the Windows SDK, `cmd.exe` and `pwsh.exe`. CI installs Rust 1.89.0 explicitly. Go dependencies and Rust dependencies are pinned by their manifests and lockfiles. SwiftTerm comes from this checkout; no portable Swift server is tested. Build outputs stay in the selected output directory. That directory must be disposable: rerunning overwrites its result files.

## Native adapters

Go uses `creack/pty` on Unix and `UserExistsError/conpty` on Windows. Rust uses `portable-pty`. Both start the same C child from `script/native-validation/pty_probe.c` and exercise actual child-observed terminal geometry, input/output and successful exit. Invalid credentials and geometry are rejected before proceeding.

The shell experiments run `/bin/sh`, Bash and Zsh where installed, or `cmd.exe` and PowerShell on Windows. A loopback observer connects for each command and disconnects after its response. The adapter keeps owning and draining the PTY while no observer is connected. Delayed shell output is recovered over a new connection with the same child PID. The delayed marker must be absent from the write response and present in bytes retained before accepting the first reconnect request, with no retry permitted. Each shell also emits exactly 65,536 payload bytes between fresh output-only markers before exiting.

On native Windows, `portable-pty` requests an inherited cursor. The Rust adapter answers its one startup cursor query asynchronously at the known fresh viewport origin and records the response count. This is separate from the unimplemented application-query policy.

The launcher removes inherited `ENV`, `BASH_ENV` and `ZDOTDIR` settings; Bash and Zsh use their no-startup-file flags. Deliberately daemonized descendants remain outside the cleanup claim. Mid-request disconnects are rejected per connection without terminating the owned child. Both adapters bound PTY writes independently of the socket; Go also lets its watchdog initiate child termination.

The endpoint binds an OS-assigned IPv4 loopback port and requires a random per-run capability. It retains at most 1 MiB of raw output. This is an isolated probe protocol, not the application's authentication or transport. Normal completion waits for the child and tears down the adapter. Each operation, child-exit wait and whole probe is bounded. Failure cleanup terminates the owned child where the adapter can do so; descendants, service restart and upgrade survival still need separate experiments.

These checks establish raw output retention across actual observer reconnects. They do not establish terminal checkpoints, server-side query handling while detached, encrypted transport, writer leases, multi-client behavior, slow-reader policy or service lifecycle.

## Engine comparison

All engines consume the same byte and resize traces. The harness compares cells, basic style/color attributes, cursor, active buffer and final query-response bytes. SwiftTerm creates native terminal views in memory for its image delegates without opening a window. The baseline uses the vendored binary checkpoint, imports it into a fresh terminal and compares full exported checkpoints after the same suffix. A matching checkpoint is a baseline continuity check, not cross-engine compatibility.

Go uses `charmbracelet/x/vt`. Its visible-screen `Render` output is retained for inspection; this probe does not exercise a full parser/checkpoint export for Go. Rust uses `vt100`; a fresh parser receives `state_formatted`, then the same suffix. That is formatted-state reconstruction, and must not be presented as a full parser checkpoint. Its equality checks cover the projected visible state and basic styles only.

A cell match cannot prove images, history, hyperlinks, mode state or keyboard event encoding. Image fixtures have positive controls: the SwiftTerm baseline must retain image stripes. The split Sixel trace is kept separately because the current baseline emits no image for it; empty image state is not a fidelity pass. Kitty keyboard checks cover negotiation queries, not native key-event encoding. Go per-event reply capture is asynchronous; compare the final drained reply bytes for each trace.

## Results and CI

`run.json` records native OS/CPU, toolchain versions, LF-normalized fixture hash, UTC timestamps and adapter status. `sessions.json` records each native experiment. `*-traces.json` retains the engine state; `comparison.json` is produced only when SwiftTerm runs. Adapter failures fail the run. Fidelity differences remain findings for Gordon to judge, so a green CI job does not mean engine parity.

The dedicated `native-comparison.yml` workflow prepares macOS ARM64 on `xcode-27` with Xcode 27.1 selected, Linux x86-64/ARM64 and native Windows x86-64 runs. The [verified native run](https://github.com/GordonBeeming/myterm/actions/runs/42367281598) passes all four jobs; the prototype is retained as reference material in the comparison PR. Non-Mac jobs run the same traces and retain their states but do not independently assert SwiftTerm parity. The workflow uploads JSON and logs for fourteen days; durable summaries belong in the research note and ticket. Cross-compilation is a build check only.

Render a local comparison page from a completed Mac run:

```sh
python3 script/native-comparison/report.py --results /tmp/myterm-native-comparison --output /tmp/myterm-native-comparison.html
```

The page embeds the measured data and offers captured cells, basic style differences and Rust's actual reconstructed state. It reports the Rust responder as unimplemented and Go full-checkpoint reconstruction as unmeasured.

After downloading all four native artifacts, include their actual results in the page:

```sh
python3 script/native-comparison/report.py --results /tmp/myterm-native-ci/native-comparison-xcode-27 --ci-results /tmp/myterm-native-ci --ci-run-url https://github.com/GordonBeeming/myterm/actions/runs/42367281598 --output /tmp/myterm-native-comparison.html
```

The platform summary requires all four artifacts and matching normalized fixture hashes. It distinguishes native adapter results from the same engine's trace projection across platforms and from fidelity against SwiftTerm.

Run the evidence-boundary regressions independently:

```sh
python3 script/native-comparison/test_probe.py
```

The seven checks cover full-size Rust JSON responses, response bounds and truncation, UTF-8 evidence reads, isolated POSIX startup, and acceptance or rejection at the first reconnect boundary. CI runs them on every native runner.
