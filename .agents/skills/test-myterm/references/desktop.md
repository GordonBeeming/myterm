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

The development Companion host uses noninteractive Keychain access. A denied legacy item becomes **saved relay sign-in is unavailable**, not an automatic password prompt or a relay retry storm. This preserves ACLs and existing secrets. A denied legacy ACL requires Gordon's manual Keychain Access authorization for the stable app identity first. A fresh sign-in cannot repair access to that existing denied item. Fresh sign-in is appropriate for missing or expired relay credentials after Keychain access works. The test workflow does not grant itself access, widen ACLs, reset the Keychain or write plaintext substitutes.

## Live desktop checks

After explicit Mac GUI opt-in, use the available native computer-use tools to inspect the actual dev window. Normal launches focus a healthy existing instance, so quit intentionally before verifying a rebuilt executable. A terminal helper can outlive that quit; record its shell/helper identity before changing the UI process.

For session UI changes, run [workflow checks](workflows.md), then inspect keyboard shortcuts, destination labels, search/inbox entry reuse and browser-context preview. Verify the same input never creates a duplicate tab. On persistent-terminal changes, distinguish UI restart continuity from a host reboot or helper exit. The latter cannot preserve an executing shell command.

Useful focused tests include `TerminalSnippetCommandTests`, `TerminalSnippetStoreTests`, `BrowserContextDeliveryTests`, `BrowserContextArtifactsTests`, `PersistentTerminalRuntimeTests`, `PersistentTerminalStartupTests` and `SessionHostTests`; discover the current names before filtering. Use `bash script/test_signing_identity.sh` and remote `KeychainInteractionPolicyTests` for mocked signing-selection/Keychain policy checks. Those tests do not prove the live machine's ACL allows access.

Keep the Mac dev UI running and awake for companion tests: the persistent PTY helper does not host the relay connection or notifications.
