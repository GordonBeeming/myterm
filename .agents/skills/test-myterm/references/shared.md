# Shared setup and test selection

## Inventory and scope

Read applicable repository instructions and the active command rules before state-changing commands. Check `git status --short`, the current branch, relevant diffs and running test/build processes. Keep the existing worktree and user state intact. Test authorization does not authorize commits, releases, deployments or deleting saved pairings.

Useful headless inventory:

```sh
xcodebuild -version
bash script/verify_companion_toolchain.sh 27.0
xcrun simctl list devices available
swift --version
go version
```

`docs/COMPANION.md` gives the supported Xcode/iOS versions. Finish Xcode's first-launch and required component installation before UI testing. Metal installation is described there. Opening Simulator/DeviceHub or launching a physical device can report missing **XcodeDeviceHub** or another system component. Gordon must complete Xcode's component installation/authorization; repeated app rebuilds cannot fix it. Explain this prerequisite and resume after it is installed. Do not substitute a Simulator result for a requested physical-device result.

## Select tests from the change

Discover current names with `swift test list` and `rg -n 'func test|@Test'` in the relevant test directory. Use a class/suite filter for a focused first pass:

```sh
swift test --filter TerminalSnippetCommandTests
swift test --package-path Packages/MyTermRemote --filter DevTestAuthorizationTests
```

`Packages/MyTermRemote` owns auth, cryptography, transport and interoperability. Interoperability tests compile a temporary Go relay fixture and require the repository's declared Go toolchain. Desktop models live in `Tests/MyTermTests`, terminal runtime in `Tests/MyTermPlatformTests`, helper behavior in `Tests/MyTermContinuityTests`, and companion models in `Companion/Tests`. UI suites live in `Companion/UITests`.

Broaden after focused checks pass, as the change warrants:

```sh
swift test --parallel
swift test --package-path Packages/MyTermRemote
bash script/channel_isolation_test.sh
```

`make verify` bundles the production channel. Use it for requested production packaging verification, rather than as an automatic dev-GUI test step. Running an app, XCTest UI suite or Simulator control still needs the GUI authorization described in the main skill.

## UI runner flags

Set flags on the UI test runner through the device-control tools or test plan, not merely on the companion app process. Discover the current tests before selecting them.

| Suite | Required runner environment | Evidence |
|---|---|---|
| `CompanionTouchTests` | `MYTERM_TOUCH_UI_TEST=1` | Optional slow loopback touch/clipboard fixture; no live relay |
| `LiveDeviceTerminalTests`, `LiveDeviceTouchTests` | `MYTERM_LIVE_DEVICE_TEST=1`, explicit `MYTERM_LIVE_HOST_NAME` | Actual paired development Mac input/touch |
| `LiveDeviceLayoutTests` | `MYTERM_LIVE_IPAD_TEST=1`, explicit `MYTERM_LIVE_HOST_NAME`, `MYTERM_LIVE_WORKSPACE` | Real four-pane tablet workspace prepared on that Mac |

Use the installed XcodeBuildMCP `test_sim` operation to bridge runner variables; setting shell/app variables alone is insufficient. Discover its actual provider-prefixed tool name in the current session. Set its session defaults first to the selected `Companion/MyTermCompanion.xcodeproj`, `MyTermCompanion` scheme, current Simulator UUID and chosen derived-data directory. Then a live terminal request has this shape:

```javascript
test_sim({
  extraArgs: ["-only-testing:MyTermCompanionUITests/LiveDeviceTerminalTests"],
  testRunnerEnv: {
    MYTERM_LIVE_DEVICE_TEST: "1",
    MYTERM_LIVE_HOST_NAME: "<paired development Mac name>"
  },
  progress: false
})
```

For the optional loopback touch suite, select `CompanionTouchTests` and pass `testRunnerEnv: { MYTERM_TOUCH_UI_TEST: "1" }`. For tablet layout, first select the iPad in session defaults, then:

```javascript
test_sim({
  extraArgs: ["-only-testing:MyTermCompanionUITests/LiveDeviceLayoutTests"],
  testRunnerEnv: {
    MYTERM_LIVE_IPAD_TEST: "1",
    MYTERM_LIVE_HOST_NAME: "<paired development Mac name>",
    MYTERM_LIVE_WORKSPACE: "<prepared four-pane workspace>"
  },
  progress: false
})
```

These are tool-argument examples, not JavaScript to run through a shell. Use the existing iOS debugger skill for current tool selection and session-default APIs.

Missing flags yield skips. Keep clipboard suites serialized with each other and with pair-link copying. A unit/clipboard failure during concurrent pasteboard use requires a serialized rerun; concurrent failure is not an accepted product baseline.

## Process and evidence discipline

Give each new run its own chosen log/result directory. Discover live PIDs with `pgrep -fl 'xcodebuild|xctest|MyTerm|myterm-dev'`, then inspect the matching command/log before waiting or restarting. A tool timeout can leave a working build, test or local host running. Poll that run and preserve its result; avoid starting a second copy to chase a timeout.

The current iOS 27 Simulator can log `App animations complete notification not received, will attempt to continue` after roughly a minute around each interaction. A run may still advance very slowly. Compare new log entries before declaring it stuck; retain this environment limitation in the report rather than weakening assertions or treating an interaction timeout as success.

For a failed screen-OCR assertion, inspect the original full-resolution attachment before diagnosing connectivity. Vision has read this terminal font's slashed `0` as `Ø` even when the Mac returned the correct marker. Keep shell probes octal-encoded so keyboard echo cannot satisfy them, and use distinct uppercase letters for random markers rather than accepting an approximate match.

Serialize tests that touch the same Mac workspace or clipboard. Pair-link **Copy** uses the Mac pasteboard; Simulator clipboard tests and screenshot paste can overwrite it. Capture/use a fresh pairing ticket within its validity window after those tests finish. Keep secret-bearing pair tickets out of screenshots and retained logs.

After a live touch test fails inside its mouse-reporting `cat -v` step, use the selected terminal's control lease to stop that command and restore mouse tracking before continuing. Restore changed orientation and keyboard-row preferences. Remove only test-owned disposable workspaces when cleanup is authorized; preserve user work and cached pairings.

Use `.xcresult` attachments and fresh before/after screenshots as evidence. Use actual run counts, not counts embedded in a skill. An old screenshot, prior UUID or retained temporary file is not evidence of the current build. Report fixture, Simulator live-relay and physical-device evidence separately.
