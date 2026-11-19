# Native Mac service probe

This throwaway Rust executable checks launchd ownership, restart behavior and explicit file-Keychain access. It has no terminal, browser, account protocol, phone connection or updater. Those workflows remain unverified until the product supports them.

## Build and local checks

Run from the repository root on the test Mac. The paths below are reserved for this probe; inspect any existing files before reusing them.

```sh
mkdir -p /Users/Shared/myterm-probe168
chmod 700 /Users/Shared/myterm-probe168
rustc --edition 2021 -D warnings script/macos-service-probe/main.rs -o /Users/Shared/myterm-probe168/probe
MYTERM_PROBE_BINARY=/Users/Shared/myterm-probe168/probe python3 script/macos-service-probe/test_probe.py
python3 script/macos-service-probe/prepare.py
```

The native tests start disposable processes under `/tmp` and terminate only those processes. `prepare.py` writes a manifest and service definitions, plus administrator setup/removal scripts. It does not register a daemon or create a Keychain item.

## Login supervision

Register the temporary agent only after Gordon authorizes service changes. Substitute the test user's UID for `501` if needed.

```sh
launchctl bootstrap gui/501 /Users/Shared/myterm-probe168/com.gordonbeeming.myterm.native-probe168.login.plist
python3 script/macos-service-probe/check_launchagent.py
```

The check waits for native restarts after killing only the probe's PID, verifies duplicate-owner refusal and stable instance identity, then unloads the agent and confirms it remains stopped for twelve seconds. It retains `login-evidence.json`. Registering this plist from the scratch directory does not establish automatic registration at the next login or installer/background-item behavior.

## Unattended supervision

Inspect `/Users/Shared/myterm-probe168/install-unattended.sh` before running it. Gordon runs the administrator command in his terminal:

```sh
sudo /bin/bash /Users/Shared/myterm-probe168/install-unattended.sh
```

The script installs a root-owned executable in `/Library/Application Support/MyTermNativeProbe168`, creates one random disposable generic-password item in the system file Keychain, and registers `com.gordonbeeming.myterm.native-probe168.unattended` under the selected non-root owner. It checks the installed binary and plist hashes, then checks status and key access through a request from that owner. It refuses an existing destination, a different sudo caller or a still-registered login probe. Daemon logs go under the root-owned `/Library/Logs/MyTermNativeProbe168` directory.

Only the provisioning command runs as root. Server mode refuses root. Security API calls disable interaction before accessing the explicit system Keychain; no login-Keychain passwords or existing MyTerm items are used. The probe reports a SHA-256 fingerprint of its disposable secret to compare key availability across restarts. This checks secret retrieval; it does not prove private-key signing, a handshake, production signing ACL continuity or another user's denial. The executable has the Rust toolchain's ad-hoc signature.

The candidate system-Keychain ACL is deliberately unproven. If provisioning or non-root reading fails, record the OSStatus and stop before changing ACLs or introducing another storage backend. Setup failure triggers removal of the exact startup registration and payload; state, logs and any disposable key are retained for diagnosis. Check the rollback output before retrying, since removal can also fail. An existing key is never replaced; a retained disposable item needs a separate explicit erase decision before reprovisioning.

After successful setup:

```sh
/Users/Shared/myterm-probe168/probe request /Users/Shared/myterm-probe168/instance status
/Users/Shared/myterm-probe168/probe request /Users/Shared/myterm-probe168/instance key
launchctl print system/com.gordonbeeming.myterm.native-probe168.unattended
```

Check status and key access before asking Gordon to lock, log out or reboot. Gordon performs those actions after checking his other work. Repeat the same requests afterward and compare instance identity, key fingerprint and process start. Every five seconds the service records its own key-access result, epoch timestamp, PID and `/dev/console` owner UID. Inspect those heartbeat records during the logged-out interval; a post-login read alone does not prove logged-out availability. Console ownership is supporting evidence for logout, and does not distinguish an unlocked screen from a locked screen under the same user.

## Removal

Gordon runs:

```sh
sudo /bin/bash /Users/Shared/myterm-probe168/uninstall-unattended.sh
```

This unloads only the named probe daemon and removes its exact plist and executable. The instance state, evidence and disposable Keychain item are retained. Explicit key erasure is a separate action. The script does not change power policy, FileVault, Remote Login, production MyTerm services or direct/relay access.

Full native acceptance also requires protected-file failures, locked/restarted key access, cold boot after disk unlock, multiple users, child cleanup, genuine update races, installer denial/disabled-background-item handling and phone access. The seven local probe tests and the LaunchAgent check cover only their named mechanisms.
