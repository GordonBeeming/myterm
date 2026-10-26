# Desktop

Load `build-macos-apps:macos-build-run-debug` for build/launch diagnostics and `build-macos-apps:macos-signing-entitlements` when signature or Keychain trust is involved. Use `build-macos-apps:swiftpm-macos` for package-first build/test work. Read the current `script/build_and_run.sh` and `script/select_signing_identity.sh` rather than reconstructing bundle resources by hand.

## Build before opening a window

```sh
bash script/build_and_run.sh --print-plan
bash script/build_and_run.sh --bundle
```

These are the development channel. `--bundle` builds without launching; `./run.sh` opens the GUI. Keep production installations and Launch Services handlers intact. For isolated UI checks, choose a separate application-support directory and UserDefaults suite. `script/build_and_run.sh` supports `MYTERM_APPLICATION_SUPPORT_DIRECTORY` and `MYTERM_USER_DEFAULTS_SUITE`:

```sh
MYTERM_APPLICATION_SUPPORT_DIRECTORY="$desktopQAApplicationSupport" \
MYTERM_USER_DEFAULTS_SUITE="$desktopQADefaultsSuite" \
  bash script/build_and_run.sh --bundle
```

Choose the absolute directory and suite name for this test session and pass the same values to the later authorized launch. Keep them stable for restart checks. Use the existing development state instead when claiming continuity of an existing live pairing.

This does not fully isolate every preference: `DesktopTerminalSnippetStore.shared` currently uses `UserDefaults.standard` and ignores `MYTERM_USER_DEFAULTS_SUITE`. Preserve the existing development snippet catalog and use uniquely named QA entries that can be identified for cleanup. Development and production still have separate bundle-default domains; a separate QA suite is not proof of snippet-catalog isolation.

The dev bundle selects Apple Development, then Developer ID Application. If neither exists it stops; ad-hoc signing requires explicit `CODESIGN_IDENTITY=-`. A stable identity avoids a changed designated requirement every build. Build/signing can itself require access to a signing key; follow the existing signing/1Password instructions and stop at a credential prompt rather than answering it unattended.

Persistent controllers and helpers authenticate each other's signing identities before exchanging terminal state or input. Production requires the matching Developer ID identity and hardened runtime. Stable development signing permits UI rebuilds to reconnect. Explicit ad-hoc development builds pin the exact executable requirement: close disposable panes intentionally before replacing those binaries, or retain the matching old build to close them. Do not loosen authentication or kill a user's helpers to get a test past this boundary. An ad-hoc production verification bundle proves packaging; it is not a runnable distribution build.

For unbundled Debug helper integration tests, reuse the existing fixture factories. They merge `SessionHostClientAuthentication.testEnvironment()` with image geometry measured from an actual native `TerminalView`. The allowlist identifies the test process's exact kernel audit token; copying its environment to a different process does not authorize that process. Packaged and Release helpers ignore the test allowlist. Do not replace this with a UID-only check or invented font metrics.

The development Companion host uses noninteractive Keychain access. A denied legacy item becomes **saved relay sign-in is unavailable**, not an automatic password prompt or a relay retry storm. This preserves ACLs and existing secrets. A denied legacy ACL requires Gordon's manual Keychain Access authorization for the stable app identity first. A fresh sign-in cannot repair access to that existing denied item. Fresh sign-in is appropriate for missing or expired relay credentials after Keychain access works. The test workflow does not grant itself access, widen ACLs, reset the Keychain or write plaintext substitutes.

## Live desktop checks

After explicit Mac GUI opt-in, use the available native computer-use tools to inspect the actual dev window. Normal launches focus a healthy existing instance, so quit intentionally before verifying a rebuilt executable. A terminal helper can outlive that quit; record its shell/helper identity before changing the UI process.

For session UI changes, run [workflow checks](workflows.md), then inspect keyboard shortcuts, destination labels, search/inbox entry reuse and browser-context preview. Verify the same input never creates a duplicate tab. On persistent-terminal changes, distinguish UI restart continuity from a host reboot or helper exit. The latter cannot preserve an executing shell command.

Useful focused tests include `TerminalSnippetCommandTests`, `TerminalSnippetStoreTests`, `BrowserContextDeliveryTests`, `BrowserContextArtifactsTests`, `PersistentTerminalRuntimeTests`, `PersistentTerminalStartupTests` and `SessionHostTests`; discover the current names before filtering. Use `bash script/test_signing_identity.sh` and remote `KeychainInteractionPolicyTests` for mocked signing-selection/Keychain policy checks. Those tests do not prove the live machine's ACL allows access.

For recovery and transport changes, also run `LocalProcessOutputDrainTests`, `PersistentTerminalImageTests`, `PersistentTerminalGeometryTests` and `AgentLifecycleTests`. The actual-helper checks cover simultaneous large input/output, complete output before exit, same-shell reconnect, stop under backpressure, queue overflow, signed-peer rejection and image/cursor checkpoint parity. Serialize SwiftPM builds across workers; stress tests can use owned copied binaries after the build finishes. For bounded output assertions, distinguish continued validated progress from inactivity rather than expiring a short total wall-clock budget under load.

Backpressure fixtures should observe the real high-water pause before releasing the consumer; sleeping per read fragment makes the workload depend on the runner's PTY chunk size. Image parity fixtures that compare a real helper against an in-memory native view must configure the producer PTY with `stty raw -echo`. Keep Kitty acknowledgements enabled: echoing those replies into the PTY would add text absent from the in-memory baseline. Confirm detached output was parsed before the first attachment, rather than relying on a short sleep.

Keep the Mac dev UI running and awake for companion tests: the persistent PTY helper does not host the relay connection or notifications.
