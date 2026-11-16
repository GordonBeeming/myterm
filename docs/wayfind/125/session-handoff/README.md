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

## Validation status

Implementation and measurements are pending. Native GUI control requires Gordon's separate opt-in. The experiment must preserve failed runs and distinguish measured native behavior from fixtures. No production settings have been selected.
