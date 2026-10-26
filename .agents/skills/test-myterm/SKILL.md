---
name: test-myterm
description: Build and test this MyTerm repository on desktop, iPhone or iPad, including signed simulator setup, live Mac pairing and session workflow regression checks. Use for MyTerm validation or test-environment setup; release and relay deployment remain separate workflows.
---

# Test MyTerm

Run from the MyTerm repository root. Discover the current checkout, tools and devices; use this skill's commands as parameterized starting points, not a record of an earlier run.

1. Identify the changed behavior and requested platforms. Read [shared setup](references/shared.md), then the matching [desktop](references/desktop.md), [iPhone](references/iphone.md) or [iPad](references/ipad.md) reference. Read [development authentication](references/dev-auth.md) only when a live Simulator needs a new relay sign-in.
2. Run the smallest meaningful headless tests and build first. A fixture suite proves its simulated behavior. Live pairing, terminal input and cross-device synchronization need the real development Mac and relay.
3. Before controlling a Mac window, Simulator, physical device or other GUI, name the surfaces and obtain Gordon's explicit opt-in unless this session already authorizes those surfaces. Reuse the existing device-control skills named in the platform references. This skill grants no GUI, secret, deployment or production access itself.
4. Capture the current screen before a visual change and the corresponding after screen. Verify behavior using the real destination, connection state and process identity. For shared session features, use [workflow checks](references/workflows.md).
5. Report the exact build/test commands, current pass/fail/skip counts, device/runtime and evidence paths, with live checks distinguished from fixtures and untested cases. Record remaining failures as failures. State physical-device, cellular and APNs limits explicitly when only Simulators were used.

A timed-out tool is not proof that its child process stopped. Inspect the existing PID and log before polling or retrying. Keep independent builds in separate derived-data/scratch directories; serialize shared live Mac state, test-created workspaces and clipboard work.

Repository authorities: `docs/COMPANION.md` owns companion setup and test authentication; `docs/AGENT_WORKFLOWS.md` owns session behavior; `Companion/project.yml` owns Xcode targets; `script/test_companion.sh` owns fixture-runner arguments. Re-read the relevant source when those behaviors or commands change. Use current test discovery instead of copying old success counts or old Simulator IDs.
