# Live development authentication

Read **Opt-in authentication for automated simulator tests** in `docs/COMPANION.md` before configuring this path. That document is the authority for environment names, credential encoding, approved origins, callback and server preconditions.

Passkeys are the default. The alternative is limited to an explicitly enabled development relay and Debug iOS Simulator app. It issues a normal one-use PKCE authorization code. The app still performs normal callback/state checks, token exchange, Keychain storage, encrypted pairing and explicit Mac approval. It cannot authenticate a production relay, Release build or physical device. Invalid explicit configuration must fail rather than silently switch to passkeys.

## Use an existing authorized test environment

Confirm the selected Mac is awake, the development app is running, and its Companion connection is online. At the actual Mac **Pair** dialog, verify the exact QA device name and displayed access scope. GUI automation opt-in alone does not authorize granting a new device terminal access: use an existing explicit authorization for this exact pairing, or let Gordon approve the dialog. When pairing was already authorized, preserve that authorization rather than adding a new gate to each routine action. Use the configured development relay and an already enrolled owner. Prefer the Simulator's cached pairing on relaunch; new sign-in and Pair Mode are only needed for a genuinely new device or revoked credentials. Do not reset app data, delete credentials or unpair simply to rerun a test.

Load the `global:1password` skill before credential access and run `op whoami`; stop if it fails. The authorized item is `ai-secrets` → **MyTerm Dev - automated test authentication**. Discover its field metadata without printing values if the reference is not already documented. Use `op run`/`op inject` with secret references; never put a resolved credential in command arguments, source, screenshots or logs. For `simctl launch`, `SIMCTL_CHILD_` environment variables are inherited by the launched app. Keep only references in local launch environment files and use the exact variable mapping in `docs/COMPANION.md`.

A launch pattern is:

```sh
op run --env-file "$devAuthReferenceFile" -- \
  xcrun simctl launch "$companionSimulatorUDID" com.gordonbeeming.myterm.companion.dev
```

Here `devAuthReferenceFile` contains only these app environment entries:

```dotenv
SIMCTL_CHILD_MYTERM_DEV_TEST_AUTH_ENABLED=1
SIMCTL_CHILD_MYTERM_DEV_TEST_AUTH_TOKEN="op://ai-secrets/MyTerm Dev - automated test authentication/credential"
```

These are secret **references**, not resolved values. The relay-side credential must already match. Keep retained test-runner output free of environment dumps and shell tracing. Changing a running app's environment requires an intentional terminate/relaunch of that app; it does not justify resetting its Keychain or pairing.

## Probe the existing endpoint without a secret

For an approved development relay, a single unauthenticated probe can distinguish an available protected route from a missing route:

```sh
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' \
  --request POST --header 'Content-Type: application/json' --data '{}' \
  "$devRelayOrigin/v1/dev-test/authorize"
```

No Bearer token is sent and redirects are not followed. HTTP **401** means the protected test route is present; it does not prove the stored credential works. **404** can mean disabled mode or the wrong deployment/route, so inspect the intended dev deployment before changing anything. Respect **429** and avoid repeated probing. An unexpected unauthenticated success is a failure to investigate, not a QA pass.

## Server work is a separate operation

Testing uses the existing development deployment. Enabling or deploying the endpoint is not an automatic prerequisite the agent may perform. When server work is explicitly authorized, follow `docs/PROXY_SETUP.md`, `Services/relay/README.md` and the service protocol docs, with development-only configuration, a verified backup and a rollback plan before replacement. Production remains outside this test workflow.

The development deployment's optional override is `/opt/myterm-relay/compose.dev-test-auth.yaml`, with its protected server environment in `/opt/myterm-relay/dev-test-auth.env`; the normal base Compose file remains unchanged. Verify current deployment state rather than assuming these files mean the endpoint is active. Never print the resolved server environment. Activation/reconfiguration commands belong to an explicitly authorized server-change task, with the operational instructions in `docs/PROXY_SETUP.md`. Removing the override can select the **base image** as well as disable the auth flags, so record the intended Compose file set and image references, and check rollback for both code and configuration. Do not automatically remove that override as routine test cleanup.

The current development server uses the `root` SSH account; its address and key are stored in the `ai-secrets` item **Digital Ocean SSH** (`ip v4` and `private key` fields). Confirm that current item and host identity during authorized maintenance instead of copying an IP or private key into this skill.

For authorized SSH, remember that a configured global `IdentityAgent` can override `SSH_AUTH_SOCK`. If using an approved temporary agent, bind SSH explicitly with `-o IdentityAgent="$SSH_AUTH_SOCK"` and the intended identity; verify the effective route without printing private material. Loading/importing a key, creating a credential or changing server configuration requires its own existing authorization. Never diagnose auth by exposing a token.
