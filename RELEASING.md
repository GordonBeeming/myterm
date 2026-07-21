# Releasing MyTerm

Publishing a GitHub release builds, signs, notarizes, and staples both `myterm.app` and its DMG. The same workflow uploads the DMG and updates `GordonBeeming/homebrew-tap` with its SHA-256.

## GitHub environment

The `prod` environment in `GordonBeeming/myterm` requires these secrets:

- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`
- `DEVELOPER_ID_CERTIFICATE` — base64-encoded Developer ID Application `.p12`
- `DEVELOPER_ID_PASSWORD`
- `HOMEBREW_TAP_DEPLOY_KEY` — the dedicated write deploy key for the tap
- `COMMIT_SIGNING_KEY` — SSH signing key used for the tap update commit

The dedicated deploy key is stored in the `ai-secrets` 1Password vault as `GitHub Deploy Key - myterm Homebrew tap`. Its public key is installed on `GordonBeeming/homebrew-tap` with write access; the private key is only injected into the `prod` environment secret.

## Publish

1. Confirm `swift test`, `make verify`, `actionlint .github/workflows/build.yml`, and `shellcheck run.sh script/*.sh` are green.
2. Create and publish a GitHub release tagged `vMAJOR.MINOR` or `vMAJOR.MINOR.PATCH`, for example `v0.1.0`.
3. Watch **Build and Test**. The release job imports the certificate into a temporary keychain, signs with hardened runtime and a secure timestamp, notarizes and staples the app and DMG, and validates both.
4. Confirm the release contains `myterm-VERSION-aarch64.dmg`.
5. Confirm `GordonBeeming/homebrew-tap/Casks/myterm.rb` was updated by a signed `myterm-release[bot]` commit.
6. Verify from a clean machine or Homebrew prefix:

   ```bash
   brew update
   brew install --cask gordonbeeming/tap/myterm
   codesign --verify --deep --strict /Applications/myterm.app
   spctl --assess --type execute --verbose=2 /Applications/myterm.app
   ```

The main MyTerm repository must remain public so Homebrew can fetch the GitHub release without authentication.

## Passkey entitlement

`Packaging/MyTerm.entitlements` deliberately does not contain Apple's managed browser passkey entitlement yet. Add `com.apple.developer.web-browser.public-key-credential` only after Apple approves the capability for the signing team and the distribution provisioning path includes it.
