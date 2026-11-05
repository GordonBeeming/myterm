# Releasing MyTerm

Publishing a GitHub release builds an Apple silicon app, gives the app and DMG their own distribution signatures and notarization tickets, uploads the DMG, and updates `GordonBeeming/homebrew-tap` with its SHA-256.

## Automatic beta channel

Every push to `main` enters the **Beta** workflow. It finishes the running batch and keeps one pending batch, replacing that pending batch when another push arrives. Once the slot opens, it freezes the newest `main` commit and uses that exact SHA for macOS tests, signing and notarization, iPhone/iPad tests, and TestFlight upload. PR checks still run independently.

The macOS prerelease is published after both platforms succeed. Its immutable tag is `v0.0.N-beta`, where `N` is the number of commits reachable from the source snapshot. The numeric app version is `0.0.N`; the bundle carries `MyTermReleaseChannel=beta`, so its updater checks beta prereleases and opens their download page. Downloading a beta replaces the installed app if you drag it over that copy. Stable installations continue checking stable releases, and the stable Homebrew cask is untouched.

TestFlight uses the Beta workflow run number plus 1000, keeping it above the earlier Companion build sequence. The release notes identify the source SHA and TestFlight build. Apple may still be processing an uploaded build when the GitHub prerelease appears. A failed platform prevents the macOS prerelease publication; a successful TestFlight upload cannot be rolled back if a later job fails.

Use **Beta → Run workflow** on `main` to retry a failed batch. An already published snapshot is skipped. Rerunning a job after a successful TestFlight upload can encounter Apple's duplicate build rejection; a new main commit starts a new batch and build number. Signed DMGs are retained as workflow artifacts for 14 days, and IPAs for 90 days.

Publishing a stable `vMAJOR.MINOR[.PATCH]` release runs only the macOS release pipeline and updates the stable Homebrew cask. It does not trigger another iPhone build. Beta releases do not become GitHub's latest stable release, and publishing them does not recursively start the release workflow.

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
