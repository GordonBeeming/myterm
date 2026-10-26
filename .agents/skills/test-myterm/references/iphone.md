# iPhone

Load `build-ios-apps:ios-debugger-agent` to build/run/inspect with XcodeBuildMCP. For a requested browser-visible Simulator mirror or SwiftUI preview, load `build-ios-apps:ios-simulator-browser`. Prefer the installed XcodeBuildMCP tools for normal build/install/run and inspection. Use those skills' current device-control APIs instead of inventing coordinate or focus automation. The CLI examples below are fallbacks when a tool lacks the required operation, including secret-reference environment injection. Obtain explicit GUI authorization before visible launch or control of the selected Simulator/device and any Mac approval window. Authorized headless builds and installs do not need an extra focus permission gate.

## Fixture suites

Read `script/test_companion.sh` and preserve an existing result bundle before rerunning:

```sh
COMPANION_DEVICE_FAMILY=iPhone bash script/test_companion.sh
```

The script selects a matching installed runtime, creates an owned Simulator and normally deletes it afterward. `COMPANION_SIMULATOR_UDID` targets an existing device without deleting it; `COMPANION_KEEP_SIMULATOR=1` preserves a newly created one. It uses unsigned builds for isolated fixture suites. `CompanionTouchTests`, `CompanionPaneSwitcherTests` and other standard UI suites are fixtures; they do not prove a paired Mac, live input or clipboard delivery across the relay.

For selected classes, use the same project/scheme with `xcodebuild test -only-testing:MyTermCompanionTests/<Class>` or `-only-testing:MyTermCompanionUITests/<Class>`, a chosen destination and a fresh result-bundle path. Discover class names in `Companion/Tests` and `Companion/UITests`.

## Signed live Simulator

Use a dedicated, known Simulator with the supported runtime and no isolated/fixture launch flags. A live companion needs Keychain and App Group entitlements. A fully unsigned install (`CODE_SIGNING_ALLOWED=NO`) can launch and render fixtures yet fail live storage with a Keychain entitlement error. For live Simulator work, retain the project's entitlements and use ad-hoc Simulator signing. Set these build settings through XcodeBuildMCP where available; the equivalent CLI fallback is:

```sh
xcodebuild build -project Companion/MyTermCompanion.xcodeproj \
  -scheme MyTermCompanion -configuration Debug \
  -destination "platform=iOS Simulator,id=$companionSimulatorUDID" \
  -derivedDataPath "$companionDerivedData" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-
xcrun simctl install "$companionSimulatorUDID" \
  "$companionDerivedData/Build/Products/Debug-iphonesimulator/MyTermCompanion.app"
```

Headless installation can proceed within the authorized test task. Obtain the GUI opt-in before visible launch or control. Confirm the app's actual entitlement/signing state when troubleshooting; do not remove entitlements to suppress the error. If a new sign-in is needed, use [dev authentication](dev-auth.md) only in its supported Simulator configuration. Pair with a fresh Mac link and approve on the Mac. Relaunch the same app/device afterward to verify cached pairing independently of the one-time auth path.

## Verify device control

A successful DeviceHub/MCP tap response proves only that the tool accepted the request. Confirm the navigation or control change in a fresh snapshot. If the visible state is unchanged, refresh the surface and verify Simulator rotation, window fit and the actual target before another action. Use the native computer-use fallback only within the existing GUI authorization.

When stable and beta Xcode are installed, their device apps can share a bundle identifier. Discover the application inside the selected Xcode instead of selecting by bundle identifier alone. Xcode 27 on this machine uses `Contents/Applications/DeviceHub.app`; older installations may use `Contents/Developer/Applications/Simulator.app`. Select the existing **absolute application path** with native computer use and verify its fresh screen and selected device. Derive any coordinates from that current snapshot; retain neither old coordinates nor old Simulator IDs as authority.

## Clipboard permission during live Copy checks

`LiveDeviceTouchTests` reads the selected test word through `UIPasteboard` in `MyTermCompanionUITests-Runner`. iOS can pause that read at **Allow Paste**, sometimes naming the Simulator bridge `dtpasteboardd` as its source. Confirm the intended QA runner and generated test content, then obtain Gordon’s explicit authorization for that clipboard access before approving the prompt. GUI-control permission alone does not grant clipboard access. Keep the clipboard unchanged while the assertion is waiting and resume the same live test process afterward; do not restart it or change persistent paste-permission settings as a workaround.

## Live checks

The Mac must be awake, its dev app/relay online, and this companion paired. Set `MYTERM_LIVE_DEVICE_TEST=1` and `MYTERM_LIVE_HOST_NAME` explicitly on the **UI test runner** for `LiveDeviceTerminalTests` and `LiveDeviceTouchTests`. Missing flags produce skips, not live coverage. The existing test's physical-device wording does not turn a Simulator run into physical-device evidence. Set runner variables through the selected tool/test plan; `SIMCTL_CHILD_` app auth variables are a different process boundary.

Check compact navigation, normal and extra-key rows, keyboard dismissal, link taps, word selection/Copy and wheel reporting against real terminal output. After Safari or another background transition, wait for the terminal to reconnect, request control again and verify **You have control** before sending test commands or wheel events. Backgrounding releases the lease; a visible keyboard does not prove ownership. Run [workflow checks](workflows.md), especially leaving the inbox and retapping the same session, and creating a workspace while the inbox is visible. Verify creation opens the workspace detail and later inbox selection remains responsive.

For physical iPhone work, follow `docs/COMPANION.md` local signing/provisioning and Xcode setup. Normal passkeys apply; the Simulator test credential is unavailable. Hardware keyboard, camera pairing, push delivery and cellular interruptions need separately authorized physical-device tests. Report them as untested after a Simulator-only run.
