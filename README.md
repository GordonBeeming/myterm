# MyTerm

MyTerm is a lightweight native macOS workspace for long-lived terminal sessions and WebKit browser tabs. It keeps the first release deliberately small: SwiftTerm renders terminals, WebKit renders websites, and Chromium is not bundled.

It includes collapsible, color-coded workspace folders; pinned and draggable workspaces; terminal and browser tabs; native horizontal and vertical splits; persistent sessions; and cmux-compatible shortcuts for the core workflow.

## Install with Homebrew

```bash
brew install --cask gordonbeeming/tap/myterm
open -a myterm
```

The cask installs the signed and notarized Apple silicon app from the matching GitHub release. See [RELEASING.md](RELEASING.md) for the publishing workflow.

## Run locally

MyTerm requires macOS 14 or later and the Swift toolchain included with Xcode.

```bash
./run.sh
```

That command builds the development app, closes an existing `myterm-dev` process, installs the fresh bundle under `dist/`, and launches it.

```bash
./run.sh --prod
```

The production channel is named `myterm`. It uses a release build, a separate bundle identifier, and separate persisted workspace and browser settings from `myterm-dev`.

Use `./run.sh --verify` or `./run.sh --prod --verify` for a build-and-launch smoke test. The script also supports `--debug`, `--logs`, and `--telemetry`.

Closing the last MyTerm window quits the app. Opening MyTerm again restores the persisted workspace layout.

## Default terminal

Open MyTerm Settings with <kbd>⌘</kbd><kbd>,</kbd>, then choose **Make MyTerm the Default**. macOS may ask for confirmation. This registers MyTerm for `.command` and `.tool` shell scripts, UNIX executables, and SSH links.

Launch requests reuse the existing MyTerm window and create a terminal tab there. Opening a folder starts the tab in that folder; opening a script or executable runs it from its containing folder.

## Keyboard shortcuts

The everyday shortcuts match the requested cmux workflow: <kbd>⇧⌘N</kbd> creates a workspace, <kbd>⌘D</kbd> splits right, <kbd>⇧⌘D</kbd> splits below, <kbd>⌘W</kbd> closes the focused pane or tab, and <kbd>⇧⌘R</kbd> opens the rename sheet.

[SHORTCUTS.md](SHORTCUTS.md) lists the complete supported set. Every shortcut is also visible in the native Workspace, Tabs, or Pane menu.

## Browser profiles

Open MyTerm Settings with <kbd>⌘</kbd><kbd>,</kbd> and choose how new browser tabs remember cookies and website data:

- **Across all workspaces** shares one profile throughout that app channel.
- **Per workspace** isolates each workspace and is the default.
- **Per project folder** shares a profile for terminals inside the same Git repository or folder.

Existing browser tabs keep their assigned profile when the setting changes. Website data and the last URL survive app restarts.

## Passkeys

MyTerm never stores passkeys. `WKWebView` passes WebAuthn requests to macOS, which uses the credential provider selected by the user, such as Apple Passwords or 1Password.

Local builds correctly report passkeys as unavailable. To enable passkeys for arbitrary websites in a distributed build:

1. The Account Holder for an organization Apple Developer account requests the managed `com.apple.developer.web-browser.public-key-credential` capability from Apple.
2. After Apple approves it, add that entitlement with a Boolean value of `true` to the distribution entitlements file.
3. Sign the complete app bundle with the approved Developer Team, hardened runtime, and a provisioning profile containing the capability.
4. Notarize and staple the app before distribution.
5. Open MyTerm Settings and choose **Allow passkey access** when macOS reports the authorization state as not determined.

The generated `Info.plist` already declares HTTP and HTTPS handling, and the app provides a URL field as required for Apple's browser review. Do not add the managed entitlement to local or distribution signing until Apple grants it to the Developer Team.

## Optional Chromium engine

The main app remains WebKit-only and was measured at roughly 5 MB as a release bundle during the MVP audit. [BROWSER_ENGINES.md](BROWSER_ENGINES.md) records the boundary and security requirements for a separately downloaded, same-team-signed Chromium engine later.

## Test

```bash
swift test
```

The test suite covers persistent workspaces and layouts, split behavior, channel isolation, browser profile resolution, real WebKit cookie isolation, terminal working-directory tracking, and URL normalization.
