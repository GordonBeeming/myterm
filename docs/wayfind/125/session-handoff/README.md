# Native session handoff experiment

This disposable experiment supports [Validate session handoff and background streaming](https://github.com/GordonBeeming/myterm/issues/166). Gordon accepted the scope, workloads and targets in the live wayfinding discussion. The ticket remains open until he assesses native behavior and the measured tradeoffs.

## Agreed scope

Use real native Mac terminal processes owned by a Rust server and two native SwiftTerm clients. Exercise takeover races, workspace switching, slow viewers, reconnects and channel replacement. Compare visible-pane output subscriptions with continuous background subscriptions. Production integration, iPhone/iPad behavior, cross-machine networking and Linux/Windows validation remain outstanding.

The retained checkpoint foundation is commit `ab4f866153ff46c03e1e51de72eec8d85d233d51`, under `script/wezterm-feasibility/`. Preserve its scratch compatibility requirements and known fidelity limits. Initial checkpoints use 120 columns, 40 rows, 40 history lines and a 1 MiB encoded cap.

## Workloads

- Two native clients, two Rust server instances, four terminals across two workspaces.
- Output rates of 10 KiB/s, 100 KiB/s and 1 MiB/s per active terminal.
- Compare visible-pane and continuous background streaming.
- Pause one viewer for 30 seconds while the controller continues typing.
- Exercise 100 workspace switches, competing takeovers, disconnect/reconnect cycles and channel replacements, including rejected replacement attempts.
- Run five-minute baselines and a 30-minute stress workload.

## Acceptance targets

| Measure | Target |
| --- | --- |
| Correctness | Zero lost, duplicated or reordered accepted input/output; zero input from rejected takeovers; unchanged process identity |
| Takeover | Server acceptance within 100 ms at p95 |
| Workspace switch | Cached display within 100 ms at p95; synchronized and ready for input within 500 ms at p95 |
| Reconnect or channel replacement | Synchronization within one second at p95 after the connection becomes usable |
| Slow-viewer isolation | Controller latency degrades by no more than 20% against the equivalent fast-viewer baseline |
| Buffering | Compare 256 KiB, 1 MiB and 4 MiB per-viewer queues; overflow triggers explicit resynchronization |
| Memory | Retained memory grows by no more than 32 MiB per process after warm-up during stress |
| CPU and bandwidth | Record absolute usage and policy differences before selecting production budgets |

Latency targets apply at 10 and 100 KiB/s. At 1 MiB/s, require correctness, bounded buffering and recovery, and retain latency overruns as findings. Report the scope of every observation: a headless native view does not prove visible rendering latency, and loopback does not prove multi-Mac networking.

## Run the experiment

Requirements are native macOS, the Rust 1.99.1 and Swift toolchains, Python, the immutable foundation commit and the pinned upstream source directory from that foundation's `run.py`. All servers bind ephemeral loopback ports. Credentials and TLS private keys are generated for each run and kept out of retained evidence.

```sh
python3 docs/wayfind/125/session-handoff/prepare.py --baseline-source /tmp/myterm-checkpoint-baseline/source --output /tmp/myterm-handoff-build --release
python3 docs/wayfind/125/session-handoff/run.py --build /tmp/myterm-handoff-build --output /tmp/myterm-handoff-controls --cycles 100 --seconds 45 --rate 102400 --slow-seconds 30
python3 docs/wayfind/125/session-handoff/matrix.py --build /tmp/myterm-handoff-build --output /tmp/myterm-handoff-baselines
python3 docs/wayfind/125/session-handoff/run.py --build /tmp/myterm-handoff-build --output /tmp/myterm-handoff-stress --cycles 0 --seconds 1800 --rate 102400 --slow-seconds 30 --during-load-cycles 100
python3 docs/wayfind/125/session-handoff/analyze.py /tmp/myterm-handoff-stress
```

Use fresh output directories. `prepare.py --resume` rebuilds the experiment's own scratch sources. It clones the baseline build cache into its own directory. The optional `HandoffReview.app` is built without opening windows. GUI launch and control require Gordon's separate opt-in.

## Retained evidence and limits

The Debug run in `evidence/myterm-166-normal-controls-11/` passed 100 idle control cycles and a 45-second continuous-streaming workload at 100 KiB/s per terminal, including a viewer paused for 30 seconds. It recorded two resynchronizations, a maximum encoded queue occupancy of 1,031,576 bytes under the 1 MiB limit, and final native state equality. Requested output rates were achieved within five percent. Source/binary hashes and compressed raw results accompany the summaries.

Those timings cover command round trips and native import, with the sample counts stated. `switchSyncMs` includes a sequence of subscription changes and imports; it does not measure one visible workspace switch or cached rendering. The native GUI has been compiled but not opened or assessed. Optimized five-minute baselines, the queue sweep, loaded control checks and 30-minute stress acceptance remain pending.

The optimized short run in `evidence/myterm-166-release-smoke-13/` passed two control cycles and 45 seconds at 1 MiB/s per terminal, including the 30-second viewer pause. Requested rates were achieved within five percent; it recorded 22 resynchronizations and final native state equality. Controller echo p95 was 8.40 ms across 136 samples. Echo timing uses native receive timestamps on an empirically checked common monotonic clock, with the revision lookup outside the timed interval. This short run does not establish the memory-growth or long-duration targets.

The 256 KiB queue candidate failed to enqueue a checkpoint during the early Debug controls. In `evidence/myterm-166-overload-12/`, the Debug 1 MiB/s workload returned an input echo from the original PTY process, but the echo did not reach the client before resynchronization discarded it. Both servers recorded twelve resynchronizations. That run failed its echo check. It also saturated below the requested rate, so it cannot establish behavior at a sustained 1 MiB/s.

Current-state resynchronization restores the terminal screen and forty history lines. It does not retain every raw output byte. The interpretation of the agreed zero-loss criterion after overflow is awaiting Gordon's decision. Sequence and rolling-digest checks cover incremental deliveries between checkpoints; a checkpoint starts a new interval. Production resource budgets and refresh thresholds have not been selected.

The queue limit counts encoded application frames. TLS and kernel buffers, native terminal state and per-process RSS are measured or reported separately. The retained checkpoint foundation's graphics and reflow limitations still apply. Loopback and headless native views do not establish multi-Mac networking, visible responsiveness, mobile behavior or production security acceptance.

Claude's two independent reads are retained in `evidence/review-initial.json` and `evidence/review-followup.json`. They cover the prototype and measurement code, with executed checks and unverified areas stated. Diagnostic failures from earlier harness versions remain evidence of failed attempts. This research branch is never merged; production implementation and acceptance remain separate.
