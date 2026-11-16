# Native session handoff experiment

## Accepted prototype direction

The bounded prototype was accepted in the live wayfinding discussion, with UI and parameter refinements deferred to the native build. [Resolution and decision detail](https://github.com/GordonBeeming/myterm/issues/166#issuecomment-6930282410) are canonical. [Implement native attachment, control handoff and bounded streaming](https://github.com/GordonBeeming/myterm/issues/195) carries production integration and the remaining native acceptance checks. The prototype GUI was never opened; this acceptance does not claim otherwise.

This disposable experiment supports [Validate session handoff and background streaming](https://github.com/GordonBeeming/myterm/issues/166). The scope, workloads and targets were accepted in the live wayfinding discussion. The prototype ticket is closed; native behavior assessment continues in its implementation follow-up.

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
python3 docs/wayfind/125/session-handoff/matrix.py --build /tmp/myterm-handoff-build --output /tmp/myterm-handoff-baselines --rates 10240 102400 1048576
python3 docs/wayfind/125/session-handoff/run.py --build /tmp/myterm-handoff-build --output /tmp/myterm-handoff-stress --cycles 0 --seconds 1800 --rate 1048576 --policy visible --slow-seconds 30 --during-load-cycles 100
python3 docs/wayfind/125/session-handoff/analyze.py /tmp/myterm-handoff-stress
python3 docs/wayfind/125/session-handoff/followups.py --build /tmp/myterm-handoff-build --output /tmp/myterm-handoff-followups
python3 docs/wayfind/125/session-handoff/analyze.py --isolation /tmp/myterm-handoff-followups
```

Use fresh output directories. `prepare.py --resume` rebuilds the experiment's own scratch sources. It clones the baseline build cache into its own directory. The optional `HandoffReview.app` is built without opening windows. GUI launch and control require separate explicit opt-in.

## Retained evidence and limits

The Debug run in `evidence/myterm-166-normal-controls-11/` passed 100 idle control cycles and a 45-second continuous-streaming workload at 100 KiB/s per terminal, including a viewer paused for 30 seconds. It recorded two resynchronizations, a maximum encoded queue occupancy of 1,031,576 bytes under the 1 MiB limit, and final native state equality. Requested output rates were achieved within five percent. Source/binary hashes and compressed raw results accompany the summaries.

Those timings cover command round trips and native import, with the sample counts stated. `switchSyncMs` includes a sequence of subscription changes and imports; it does not measure one visible workspace switch or cached rendering. The native GUI has been compiled but not opened or assessed. Five-minute results and corrected-build confirmation are recorded below. The corrected 256 KiB queue check failed to enqueue a checkpoint. The loaded stress results are recorded below. Native GUI assessment remains pending.

The optimized short run in `evidence/myterm-166-release-smoke-13/` passed two control cycles and 45 seconds at 1 MiB/s per terminal, including the 30-second viewer pause. Requested rates were achieved within five percent; it recorded 22 resynchronization attempts and final native state equality. All attempts occurred during the pause, between 6.01 and 11.01 seconds; none occurred after reading resumed. Recovery latency after resumption was not measured. Controller echo p95 was 8.40 ms across 136 samples. Echo timing uses native receive timestamps on an empirically checked common monotonic clock, with the revision lookup outside the timed interval. This short run does not establish the memory-growth or long-duration targets.

All six five-minute optimized baselines in `evidence/baselines-14/` completed their native correctness checks and achieved their requested output rates. Visible-pane streaming used roughly half the wire traffic of continuous background streaming. Both 1 MiB/s cases failed the 32 MiB native-client memory-growth target: about 94 MiB of growth for visible-pane clients, and 189–227 MiB for continuous-streaming clients. The lower-rate cases stayed within that target. Completed execution is distinct from acceptance of the measured resource targets.

The memory investigation found retained backing allocations in the prototype's diagnostic `Data` buffers. `removeFirst` kept the visible byte count bounded while the backing allocation grew. A heap summary attributed about 114 MB to four such allocations, against about 1.5 MB of terminal-line storage. A controlled object-pool variant did not remove the growth. A separate bounded-copy variant completed 90 seconds at 1 MiB/s with native parity and about 0.03 MiB maximum post-warm-up growth. `memory_variant.py` retains both diagnostic paths as single-variable changes to the compiled baseline source.

The corrected main build passed 100 control cycles, a native client process restart under the run's approved endpoint identity, and five minutes of continuous streaming at 1 MiB/s per terminal. Every measured process stayed within the 32 MiB post-warm-up growth target; client growth was at most about 0.03 MiB. The restart observation covers the disposable native process and its supplied test identity. Production credential persistence remains unverified. One paired 100 KiB/s observation used matching 5–35 second windows: controller echo p95 was 4.67 ms with a fast viewer and 5.35 ms with the viewer paused, a 14.6% increase. Each window contained 90 samples. This point estimate is within 20%; it is not a statistical guarantee. Reproduce it with `analyze.py --isolation`. A second matching-window pair measured 4.67 ms fast and 4.60 ms paused, a 1.3% decrease, with 89 and 88 samples. Both pairs are retained as observations, without a statistical guarantee. A 4 MiB queue check completed; the corrected 256 KiB candidate again failed to enqueue a checkpoint.

The corrected build completed the 30-minute visible-pane workload at 1 MiB/s per terminal, with all 100 loaded control cycles, requested rates within five percent and final native state equality. Maximum post-warm-up memory growth across the eight measured processes was 5.92 MiB. Takeover round-trip p95 was 3.93 ms across 200 attempts, subscription synchronization p95 was 75.83 ms and channel replacement synchronization p95 was 61.98 ms across 100 cycles. These are conservative protocol timings; cached visible rendering and input latency during control bursts are unmeasured. A later explicit disconnected-input guard reproduced an acknowledgement timeout before the fix and passed a separate native regression afterward. The exact client/server sources compiled for the long run are retained as compressed evidence, so that later small UI preparation change is distinguishable.

`gui_review.py` stages each native window before connection for screenshots, then connects both clients to the disposable servers. Manual keyboard bytes use separate records for the PTY echo workload, keeping braces, carriage returns and arrow sequences distinct from harness control commands. This surface does not provide a shell. Automatic view-driven terminal resizing is disabled; server deliveries determine terminal geometry. Native GUI execution, geometry after window resizing and human assessment remain native implementation acceptance work; GUI control will require explicit opt-in when reached.

The 256 KiB queue candidate failed to enqueue a checkpoint in both the early Debug controls and corrected optimized build. A diagnostic rerun recorded a 264,107-byte encoded checkpoint frame against a 262,144-byte empty queue, identifying the capacity failure directly. In `evidence/myterm-166-overload-12/`, the Debug 1 MiB/s workload returned an input echo from the original PTY process, but the echo did not reach the client before resynchronization discarded it. Both servers recorded twelve resynchronizations. That run failed its echo check. It also saturated below the requested rate, so it cannot establish behavior at a sustained 1 MiB/s.

Current-state resynchronization restores the terminal screen and forty history lines. It does not retain every raw output byte. The accepted bounded direction uses current-state restoration and supported retained history after overflow; it adds no full raw-transcript retention requirement. Sequence and rolling-digest checks cover incremental deliveries between checkpoints; a checkpoint starts a new interval. Production resource budgets and refresh thresholds have not been selected.

The queue limit counts encoded application frames. TLS and kernel buffers, native terminal state and per-process RSS are measured or reported separately. The retained checkpoint foundation's graphics and reflow limitations still apply. Loopback and headless native views do not establish multi-Mac networking, visible responsiveness, mobile behavior or production security acceptance.

Code reviews by Claude Sonnet are retained in `evidence/review-initial.json`, `evidence/review-followup.json` and subsequent reports. They are external reads of the Codex build; executed checks and unverified areas are stated. Diagnostic failures from earlier harness versions remain evidence of failed attempts. This research branch is never merged; production implementation and acceptance remain separate.

`recovery-evidence.html` presents the recovery timeline and proof boundaries. `refresh_visual.py` verifies its 136 embedded timeline samples against retained native evidence. Browser.app QA checked all tabs at an actual 1920×943 viewport, with no horizontal overflow or mojibake and minimum text contrast 4.55:1. Native prototype windows were not opened.

Over the last twenty minutes of the stress run, native client RSS increased by 0.13 and 0.58 MiB, with fitted slopes of about 0.008 and 0.027 MiB/minute. These observations met the stated target for this run; they do not establish a permanent application-memory bound. See `evidence/stress-memory-trend.json`.

The exact long-run source archive is linked to the recorded per-file hashes in `evidence/validated-source-provenance.json`. Later changes add explicit closed-channel rejection and diagnostic queue-size details; their focused native checks and expected capacity failure are retained separately. The visual is a data explanation, not evidence that the native GUI was exercised.
