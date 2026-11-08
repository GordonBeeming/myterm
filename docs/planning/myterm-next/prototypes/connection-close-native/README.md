# Connection and close prototype

Throwaway native SwiftUI prototype for [Prototype mixed-server connection and close states](https://github.com/GordonBeeming/myterm/issues/157). Connection outcomes, terminal output and server confirmations are scripted in memory. It does not connect to MyTerm, create shells or change account data.

## Run on Mac

From the repository root:

```sh
bash docs/planning/myterm-next/prototypes/connection-close-native/script/build_and_run.sh
```

Launching the window requires Gordon's GUI opt-in. Add `--bundle` to compile and stage the app without launching. Generated files stay in `/private/tmp/myterm-157-native-build`.

## Build for iPhone and iPad

XcodeGen and Xcode are required. Keep generated files outside the repository:

```sh
mkdir -p /private/tmp/myterm-157-ios
xcodegen generate --spec docs/planning/myterm-next/prototypes/connection-close-native/project.yml --project /private/tmp/myterm-157-ios
xcodebuild -project /private/tmp/myterm-157-ios/ConnectionClosePrototype.xcodeproj -scheme ConnectionClosePrototype -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/myterm-157-ios-build CODE_SIGNING_ALLOWED=NO build
```

The generated application supports iPhone and iPad. Installing, launching and controlling it requires GUI opt-in. It uses its own bundle identifier and has no dependency on the production app's credentials or saved workspaces.

## Review

Gordon selected A and asked for a local feel. The current revision hides persistent server names, IDs, routes and connection explanations from normal panes. A small header icon exposes details and recovery actions; Mac hover provides a short hint and click/tap opens the details. Interrupted sessions retain their last frame with a subtle status icon and accessible paused-state text. Input is unavailable until connected.

Ordinary idle closure removes the pane immediately without showing close activity or a pending-count badge. Cleanup is background work. Close activity is optional diagnostic history; removed-server outcomes do not require a dismissal task. Local close intent must survive until synchronization/reconciliation is possible; server removal still preserves local processes/data under the trust policy. Gordon confirmed the existing rule: a running foreground process requires confirmation, while an idle shell closes immediately. After confirmation, the pane disappears immediately and cleanup continues in the background.

Use the bottom arrows to compare status inside each pane, a workspace connection strip, and a server inspector. Narrow windows show a pane picker; wider windows show four panes. Use the fixture-state picker to inspect connected, connecting, disconnected, reconnecting, failed and unauthorized states.

The scenario menu includes partial workspace closure, failed submission, server removal, seven-day queue expiry, remote renaming and focused-item deletion. Close activity shows relay acknowledgment separately from server confirmation. Its fixture buttons simulate later outcomes. Navigating away preserves the fixture's sessions.

Enable Prototype controls to reveal fixture-state pickers, active-work toggles and the event log. Earlier screenshots preserve the initial exploration, including the superseded manual-dismissal flow; the current quiet revision opens first in the comparison page.

## Validation status

The Mac SwiftPM build and generic iOS Simulator build passed. The iOS build compiled ARM64 and x86-64 for deployment target iOS 26.0 using the installed iOS 27.2 SDK. No automated tests were added, as required by the prototype skill.

The prototype was installed and launched on iPhone 18 Pro and iPad Pro 13-inch (M5) Simulators running iOS 27.0. The native checks covered variant switching, single-item close confirmation, partial-close rendering, failed submission and retry, relay acknowledgment versus server confirmation, queue-expiry rendering, focused-item deletion and connection-state rendering. A route-specific copy error was corrected and both platform builds passed again.

The screenshots and comparison page are retained in `evidence/` and `review.html`. The comparison page passed headless checks across fifteen views at 1920×1080 and a phone-width layout at 390×844, with no horizontal overflow, clipped headings/captions, broken images, encoding errors or JavaScript errors. Seven page text/background combinations meet a 4.5:1 contrast ratio. These checks cover the review page; they are not an accessibility audit of the native app.

Gordon authorized AppleScript as an alternative after the Computer Use native-pipe connection failed. macOS Accessibility automation successfully launched, resized and inspected the isolated Mac app and switched its three variants. The expired-command fixture rejected stale layout without confirming termination; its fresh-layout action then changed the Linux build session to confirmed termination. A remote rename preserved the selected App pane. Screenshots were captured from the prototype window with `screencapture`, using its window ID from CoreGraphics. The Mac followed the existing system dark appearance. Its narrow close-activity sheet truncates the long fixture-action label.

The dedicated expired-command confirmation button was below the iPad sheet viewport; tapping it dismissed the sheet without confirming termination. The equivalent Mac actions were subsequently verified. The iPad expiry transition and app restart remain unverified. Generic server confirmation was exercised separately on iPad.

The quiet revision built successfully for Mac and iOS. It was launched on Mac, iPhone and iPad. Mac Accessibility checks verified server details on demand and closing the offline Build pane with no sheet presented; iPhone checks verified details on tap. Current captures include the normal workspace, the details popover and the workspace after an offline pane closes.

Gordon completed the live design decisions: A with a local feel, subtle indicators, server details on demand, background cleanup and existing running-process confirmation. Build and fixture checks do not establish terminal fidelity, network behavior or the future relay's correctness. The resolution is recorded on the decision ticket. Production UI was not changed.

The final Mac running-process fixture showed the confirmation dialog. Cancel preserved the pane; confirming Close removed it without opening cleanup activity. The existing production regression test `swift test --filter AppModelTests.testClosePaneAndQuitRequireConfirmationForForegroundProcesses` passed one test with zero failures after regenerating a stale build plan; `evidence/existing-close-test-passed.log` records the run.

[Canonical design resolution](https://github.com/GordonBeeming/myterm/issues/157#issuecomment-6725574787) and [passing regression-test follow-up](https://github.com/GordonBeeming/myterm/issues/157#issuecomment-6725628044).

[Original source and evidence snapshot](https://github.com/GordonBeeming/myterm/releases/download/assets/myterm-157-native-connection-close-prototype-20261109.zip). This snapshot predates the passing regression-test follow-up.

The initial build failure and passing retry are retained separately. Metal was installed and runnable, but a cached Swift Build manifest referenced an old unmounted toolchain path. Regenerating that generated `.xcbuilddata` plan used the current mount; no component reinstall or production source change was needed.
