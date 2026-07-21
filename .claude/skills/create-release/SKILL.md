---
name: create-release
description: Publish and verify a signed MyTerm macOS release. Use only when Gordon explicitly asks to create, cut, publish, or ship a MyTerm release.
---

# Create a MyTerm release

Publish a release from `GordonBeeming/myterm` and follow it through app signing, app notarization, DMG signing, DMG notarization, the GitHub asset, and the signed Homebrew tap update. Do not create any release unless Gordon explicitly invokes this skill or clearly asks to publish one.

## Preconditions

Stop before publishing unless all of these are true:

- Work in a clean plain-Git checkout on `main`; this repository is not GitButler-managed.
- Local `main` is fast-forwarded to `origin/main` with no uncommitted or untracked release changes.
- The release head commit is signed locally and GitHub reports it verified.
- The public repository is `GordonBeeming/myterm`.
- The GitHub `prod` environment contains these secret names:
  - `APPLE_ID`
  - `APPLE_TEAM_ID`
  - `APPLE_APP_PASSWORD`
  - `DEVELOPER_ID_CERTIFICATE`
  - `DEVELOPER_ID_PASSWORD`
  - `HOMEBREW_TAP_DEPLOY_KEY`
  - `COMMIT_SIGNING_KEY`
- Local verification passes:

  ```bash
  swift test --parallel
  make verify VERSION=0.1.0 BUILD=1
  actionlint .github/workflows/build.yml
  shellcheck run.sh script/*.sh Resources/myterm-browser
  ```

List environment secret names with `gh secret list --repo GordonBeeming/myterm --env prod`. Never print or retrieve their values.

## Version convention

- Prefer `vMAJOR.MINOR` for normal releases, for example `v0.2`.
- Increment the minor version unless Gordon requests a different version.
- Use `vMAJOR.MINOR.PATCH` only for an explicit patch or hotfix release.
- The workflow accepts both forms, strips the leading `v` for the app version, and produces `myterm-VERSION-aarch64.dmg`.
- Never reuse, move, delete, or overwrite an existing tag or release.

## Publish

1. Synchronize and inspect the checkout:

   ```bash
   git fetch origin
   git switch main
   git pull --ff-only origin main
   git status --short --branch
   git log -1 --show-signature
   ```

2. Confirm GitHub verifies the exact head:

   ```bash
   HEAD_SHA=$(git rev-parse HEAD)
   gh api "repos/GordonBeeming/myterm/commits/${HEAD_SHA}" \
     --jq '{sha, verified: .commit.verification.verified, reason: .commit.verification.reason}'
   ```

3. List existing releases, choose the next version using the convention above, and review every change since the last tag:

   ```bash
   gh release list --repo GordonBeeming/myterm --limit 10
   LAST_TAG=$(gh release list --repo GordonBeeming/myterm --limit 1 --json tagName --jq '.[0].tagName // empty')
   if [[ -n "$LAST_TAG" ]]; then git log "${LAST_TAG}..HEAD" --oneline; else git log --oneline; fi
   ```

4. Write concise release notes from the actual commits. Include the Homebrew install command and any real compatibility or entitlement limitation.

5. Create a published release targeting `main`. Do not use `--draft`: the `release.published` event is what starts the distribution job.

   ```bash
   gh release create "vMAJOR.MINOR" \
     --repo GordonBeeming/myterm \
     --target main \
     --title "MyTerm vMAJOR.MINOR" \
     --notes-file /path/to/release-notes.md
   ```

## Watch the distribution workflow

Find the new `release` event run and watch it to completion:

```bash
gh run list \
  --repo GordonBeeming/myterm \
  --workflow "Build and Test" \
  --event release \
  --limit 10 \
  --json databaseId,createdAt,status,conclusion,headSha,url
gh run watch RUN_ID --repo GordonBeeming/myterm --exit-status
```

The successful run must perform this exact security chain:

1. Build the arm64 app.
2. Sign `myterm.app` with Developer ID Application, hardened runtime, and secure timestamp.
3. Verify, notarize, staple, and validate the app.
4. Create `myterm-VERSION-aarch64.dmg`.
5. Sign the DMG with Developer ID and secure timestamp as a separate artifact.
6. Verify, notarize, staple, and validate the DMG with `codesign`, `stapler`, `hdiutil`, and Gatekeeper.
7. Upload the DMG to the release.
8. Update `GordonBeeming/homebrew-tap/Casks/myterm.rb` with an SSH-signed `myterm-release[bot]` commit.

On failure, inspect `gh run view RUN_ID --log-failed`, report the exact failed gate, and fix forward. Never bypass signing, notarization, or validation, and never silently delete the failed release or tag.

## Verify the published result

1. Confirm the release is published and contains exactly the expected DMG asset:

   ```bash
   gh release view "vMAJOR.MINOR" --repo GordonBeeming/myterm \
     --json url,isDraft,isPrerelease,tagName,targetCommitish,assets
   ```

2. Download the asset into a temporary directory and verify the DMG independently:

   ```bash
   RELEASE_TMP=$(mktemp -d)
   gh release download "vMAJOR.MINOR" \
     --repo GordonBeeming/myterm \
     --pattern 'myterm-VERSION-aarch64.dmg' \
     --dir "$RELEASE_TMP"
   codesign --verify --strict --verbose=2 "$RELEASE_TMP/myterm-VERSION-aarch64.dmg"
   xcrun stapler validate "$RELEASE_TMP/myterm-VERSION-aarch64.dmg"
   hdiutil verify "$RELEASE_TMP/myterm-VERSION-aarch64.dmg"
   spctl --assess --type open --context context:primary-signature --verbose=2 \
     "$RELEASE_TMP/myterm-VERSION-aarch64.dmg"
   ```

3. Confirm the tap cask uses the release version, URL, and DMG SHA-256. Confirm the tap update commit is GitHub-verified.

4. Refresh Homebrew, verify its checksum path, then install or upgrade the cask:

   ```bash
   brew update
   brew fetch --cask gordonbeeming/tap/myterm
   if brew list --cask myterm >/dev/null 2>&1; then
     brew upgrade --cask gordonbeeming/tap/myterm
   else
     brew install --cask gordonbeeming/tap/myterm
   fi
   codesign --verify --deep --strict --verbose=2 /Applications/myterm.app
   spctl --assess --type execute --verbose=2 /Applications/myterm.app
   ```

5. Remove only the temporary verification directory after every check succeeds.

Report the release URL, workflow URL and conclusion, source commit verification, app and DMG trust checks, asset name, signed tap commit, cask SHA verification, and Homebrew install result. Do not call the release complete while any one of these remains unverified.
