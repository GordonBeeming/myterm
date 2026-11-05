# Releasing MyTerm

Publishing a GitHub release builds an Apple silicon app, gives the app and DMG their own distribution signatures and notarization tickets, uploads the DMG, and updates `GordonBeeming/homebrew-tap` with its SHA-256.

## Automatic beta channel

Every push to `main` enters the **Beta** workflow. It finishes the running batch and keeps one pending batch, replacing that pending batch when another push arrives. Once the slot opens, it verifies that the retained push still matches `main`, reserves its immutable beta tag, and freezes that commit. Both platforms use that exact SHA for macOS tests, signing and notarization, iPhone/iPad tests, and TestFlight upload. A stale event dispatches a fresh run from `main` and skips before building, so workflow definitions match the selected source even if events arrive out of order. Reserving the tag before later workflow edits lets publication use the existing Actions token. PR checks still run independently.

The macOS prerelease is published after both platforms succeed. Its immutable tag is `v0.0.N-beta`, where `N` is the number of commits reachable from the source snapshot. The numeric app version is `0.0.N`; the bundle carries `MyTermReleaseChannel=beta`. Stable and beta use the same app identity and configuration. Settings → General → Updates has a Stable/Beta selector. The selected channel is saved independently of the installed build, and changing it checks that channel immediately. Checks and skipped-release caches stay separate by channel. The stable Homebrew cask continues to distribute stable releases.

TestFlight uses the Beta workflow run number plus 1000, keeping it above the earlier Companion build sequence. The release notes identify the source SHA and TestFlight build. Apple may still be processing an uploaded build when the GitHub prerelease appears. A failed platform prevents the macOS prerelease publication; a successful TestFlight upload cannot be rolled back if a later job fails.

Use **Beta → Run workflow** on `main` to retry a failed batch. An already published snapshot is skipped. If publication left a draft, the workflow validates its source and batch metadata, downloads the original completed run's DMG, checks its SHA-256 against the release asset, and resumes publication without another platform build or TestFlight upload. Existing lightweight and annotated tags must resolve to that source; mismatched assets are rejected. Only empty failed-upload placeholders in a matching draft are removed. For a failure before draft creation, rerun failed jobs so a successful TestFlight upload is retained; rerunning an already successful upload can encounter Apple's duplicate build rejection. To resubmit a rejected companion build from a completed beta, dispatch **Beta** with **rebuild_companion** enabled and that beta's full **source_sha** (blank uses the selected main commit). This runs only companion validation and a new TestFlight upload; it preserves the macOS release and its original metadata. The default dispatch still skips completed snapshots. Signed DMGs are retained as workflow artifacts for 14 days, and IPAs for 90 days.

Publishing a stable `vMAJOR.MINOR[.PATCH]` release runs only the macOS release pipeline and updates the stable Homebrew cask. It does not trigger another iPhone build. Beta releases do not become GitHub's latest stable release, and publishing them does not recursively start the release workflow.

## Switching channels in the app

An older Homebrew installation first updates to a stable release containing the selector. Subsequent updates download the selected channel's immutable DMG, verify its SHA-256, Developer ID identity, notarization tickets, app version and channel, and stage the app beside the installed bundle. The incoming signed helper checks configuration compatibility with its own decoder. The running app stays in place until it quits.

**Update Now** prepares the download. **Restart Now** applies it after the old process exits and reopens the app. A normal quit also applies a prepared update, leaving the app closed until the user opens it. Persistent terminal helpers remain running in their private signed copies. Workspace state is saved before the handoff, and channels keep the same terminal protocol and namespace.

Entering beta saves the last stable workspace, app preferences and agent inbox after stable has exited. Returning to stable offers **Restore last stable configuration** or **Try current beta configuration**. The latter keeps the beta bytes as a backup and validates them before loading the model. An incompatible schema or a model-load failure triggers one retry with the stable snapshot and a visible explanation. A damaged snapshot never replaces current data silently: compatible current data can remain in use with a warning, and startup exposes backup recovery when neither copy can load.

Snapshots do not rewind shell commands or Keychain credentials. A beta installed directly without prior stable history has no historical snapshot to restore. It can try its current configuration only if the incoming stable decoder accepts it before installation; the UI explains that historical fallback is unavailable.

The signed `MyTermUpdateAgent` checks the prepared app again before an atomic same-volume exchange. A failed exchange, preference update or relaunch restores the previous bundle and configuration, and clears any pending configuration switch. A relaunch is committed only after the new app acknowledges a loaded model and visible main window. Missing or failed startup acknowledgement rolls back the trial. Quiet installs retain a trial marker and the previous app until their first later launch confirms startup. Successful startup prunes completed staging folders after their helper exits. Interrupted configuration restores retain their original beta backup and marker for recovery.

Keep the version-1 update-agent commands, manifests and snapshot envelopes readable by the last stable release. The snapshot's workspace payload remains in the stable schema that created it. Do not change terminal attachment/checkpoint formats merely to add an update channel.

For a downloaded release, the helper has read-only checks:

```bash
myterm.app/Contents/MacOS/MyTermUpdateAgent --verify-app /path/to/myterm.app VERSION stable
myterm.app/Contents/MacOS/MyTermUpdateAgent --verify-configuration /path/to/config com.gordonbeeming.myterm current
```

The first checks the real app and both signed helpers. The second uses that build's configuration decoder without applying a configuration or installing an app. Use `stable` to check a saved stable snapshot, or `try-beta` to accept either compatible current settings or the saved fallback. Live GUI switch testing still requires explicit GUI authorization; isolated filesystem tests cover swap rollback, preference rollback, schema incompatibility and failed-model recovery.

## Release security chain

- Release source commits are SSH-signed. Confirm the release head is shown as verified on GitHub and with `git log -1 --show-signature` before publishing.
- `myterm.app` is signed with a Developer ID Application certificate, hardened runtime, and a secure timestamp. The workflow verifies the signature, submits the app to Apple, staples the ticket, and validates it.
- The generated DMG is then signed with the Developer ID identity and secure timestamp as a separate artifact. It receives a separate notarization submission and stapled ticket before `codesign`, `hdiutil`, and Gatekeeper validation.
- The Homebrew tap update is committed and pushed as `myterm-release[bot]` through the dedicated tap deploy key, without commit signing.

## GitHub environment

The `prod` environment in `GordonBeeming/myterm` requires these secrets:

- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`
- `DEVELOPER_ID_CERTIFICATE` — base64-encoded Developer ID Application `.p12`
- `DEVELOPER_ID_PASSWORD`
- `HOMEBREW_TAP_DEPLOY_KEY` — the dedicated write deploy key for the tap

The dedicated deploy key is stored in the `ai-secrets` 1Password vault as `GitHub Deploy Key - myterm Homebrew tap`. Its public key is installed on `GordonBeeming/homebrew-tap` with write access; the private key is only injected into the `prod` environment secret.

## Publish

1. Confirm the release head has a valid signature, then run `swift test --parallel`, `make verify`, `actionlint .github/workflows/build.yml`, and `shellcheck run.sh script/*.sh Resources/myterm-browser`.
2. Create and publish a GitHub release tagged `vMAJOR.MINOR` or `vMAJOR.MINOR.PATCH`, for example `v0.1.0`.
3. Watch **Build and Test**. The release job imports the certificate into a temporary keychain, signs/notarizes/staples the app, then separately signs/notarizes/staples the DMG, and validates both artifacts.
4. Confirm the release contains `myterm-VERSION-aarch64.dmg`.
5. Confirm `GordonBeeming/homebrew-tap/Casks/myterm.rb` was updated by a `myterm-release[bot]` commit.
6. Verify from a clean machine or Homebrew prefix:

   ```bash
   brew update
   brew install --cask gordonbeeming/tap/myterm
   codesign --verify --deep --strict /Applications/myterm.app
   spctl --assess --type execute --verbose=2 /Applications/myterm.app
   ```

   For a downloaded DMG, also run `codesign --verify --strict`, `xcrun stapler validate`, `hdiutil verify`, and `spctl --assess --type open --context context:primary-signature` against the DMG before mounting it.

The main MyTerm repository must remain public so Homebrew can fetch the GitHub release without authentication.

## Passkey entitlement

`Packaging/MyTerm.entitlements` deliberately does not contain Apple's managed browser passkey entitlement yet. Add `com.apple.developer.web-browser.public-key-credential` only after Apple approves the capability for the signing team and the distribution provisioning path includes it.

## Privacy entitlements

Programs running in a pane are checked against MyTerm as the responsible app, so `Packaging/MyTerm.entitlements` carries the hardened-runtime resource entitlements (microphone, camera, contacts, calendars, photos, location, Apple Events). Each one needs its usage string in `Packaging/Info.plist`, and `SystemPermission` in `Sources/MyTermCore/SystemPermission.swift` lists both. `SystemPermissionTests` fails if either file is missing one.
