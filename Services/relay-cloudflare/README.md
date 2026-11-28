# MyTerm Cloudflare relay

The Cloudflare Worker uses SQLite-backed Durable Objects to route ciphertext between approved endpoints. D1 holds passkeys, login sessions and invitation expiry. R2 holds the invitation consumption record. The [relay deployment contract](../../docs/planning/myterm-next/relay-deployment-contract.md) records the full release requirements.

## Verify locally

From this directory, use Node.js 24 or newer.

```sh
npm ci
npm run check
npm run migrate:local
npm run build
node --test --test-reporter tap test/*.test.mjs
MYTERM_RELAY_MEASURE_LONG=1 npm run measure
```

`npm test` bundles the Worker and runs the same isolated tests with Node's default reporter. They use workerd through Miniflare with a fresh D1 database, R2 bucket and Durable Object namespace. The virtual authenticator exercises WebAuthn registration and signed login. Test endpoints generate Ed25519 keys and use the same HTTP and WebSocket entry points as clients. The measurement runs a quiet socket pair for four signed liveness renewals, then forwards 240 acknowledged 512-byte ciphertext round trips. Its TAP diagnostic contains timings as JSON. Omit `MYTERM_RELAY_MEASURE_LONG` to measure a single renewal.

On macOS ARM64 with Node 24.14.0, Wrangler 4.168.0 and Miniflare 5.20261123.1-beta, the local socket pair was quiet for 120.01 seconds. It forwarded the 240 round trips in 100.13 ms with no mismatches. The median was 0.37 ms and the 95th percentile was 0.69 ms. These timings are local workerd results. Cloudflare billing, hibernation and network latency need deployed measurements.

`npm run dev` listens on `http://localhost:8787` and uses its own Wrangler state. The checked-in manifest targets local development. A developer testing operator setup can provide a local-only `RELAY_OPERATOR_BOOTSTRAP` secret in `.dev.vars`. The value must be 32 random bytes encoded as unpadded base64url. Keep that file outside source control. Open `http://localhost:8787/auth/operator` to create the operator passkey and issue invitations.

## Prepare a Cloudflare deployment

Run development validation first, then beta and live. Use one Worker, D1 database and private security-control bucket per environment. The manifest uses a custom domain with an exact-hostname passkey RP ID and disables Workers.dev, preview URLs and automatic observability capture.

| Channel | Worker | Public origin | Registration |
| --- | --- | --- | --- |
| Self-hosted or isolated acceptance | Operator chooses a unique name | Operator's own HTTPS domain | Invitation by default |
| Beta | `myterm-relay-beta` | `https://myterm-relay-beta.gordonbeeming.dev` | Public |
| Live | `myterm-relay-live` | `https://myterm-relay.gordonbeeming.dev` | Public |

From this directory, sign in to the account that manages your Cloudflare zone. Use an authorized setup identity for the target deployment. Select an unused origin for an isolated acceptance environment.

```sh
npx wrangler whoami
npx wrangler d1 create "$relay_worker_name"
npx wrangler r2 bucket create "${relay_worker_name}-security-control"
```

Use the account ID and new D1 database ID from that account. Set the source revision to the commit being deployed.

```sh
npm run prepare-deployment -- \
  --channel self-hosted --name "$relay_worker_name" --origin "$relay_origin" \
  --revision "$relay_revision" --account-id "$relay_account_id" --database-id "$relay_database_id"
relay_manifest=".wrangler/deploy/${relay_worker_name}.json"
npx wrangler deploy --config "$relay_manifest" --dry-run
```

Use `--channel beta` or `--channel live` and omit `--name` for a hosted deployment. The manifest fixes the Worker name in those channels. It rejects the private Dev relay hostname. Confirm the configured D1 ID belongs to this deployment before applying migrations since a dry run cannot verify resource ownership.

Create a protected JSON secrets file outside the repository with a `RELAY_OPERATOR_BOOTSTRAP` value containing 32 random bytes in unpadded base64url. Load it through your deployment secret store. The setup value goes into the password field on the relay's `/auth/operator` page during first-time setup. Share the resulting registration invitation with the person creating a personal account.

```sh
npx wrangler d1 migrations apply ACCOUNT_DB --remote --config "$relay_manifest"
npx wrangler deploy --strict --config "$relay_manifest" --secrets-file "$relay_secrets_file"
curl --fail --silent "$relay_origin/v1/capabilities"
```

Check the returned channel, revision and schema before enrolling endpoints. Hosted promotion and the release gates are recorded in the [relay deployment contract](../../docs/planning/myterm-next/relay-deployment-contract.md). An existing custom domain that serves the Go relay needs its own cutover.

## Native passkey sign-in

Open `/auth/register` or `/auth/login` in an authentication session. Query parameters are `redirect_uri`, `state`, `code_challenge` and `code_challenge_method=S256`, using the MyTerm callback allowlist. Registration accepts a one-use invitation in the `bootstrap_token` fragment, or `invitation` as its alias. The callback includes an authorization `code` and the original `state`. After validating both, exchange with `POST /v1/passkeys/session` using `{code, codeVerifier, redirectUri}`. The response contains `{accountId, session, expiresAt}`. The code expires after 90 seconds and is redeemed atomically. `expiresAt` is milliseconds since the Unix epoch.

Passkey sign-in authorizes account access. Endpoint approval is separate. For the direct handoff, the candidate shares its signed `RelayAdmissionRequest` with the Mac. The Mac checks the candidate request against its relay and account, asks the person to approve, then submits the signed `admit` action. The Mac shares the signed `RelayAdmissionApproval` directly back to the candidate using a trusted channel such as in-person QR or AirDrop. The candidate pins the account anchor and server signing key from that response. Both handoff messages expire after five minutes and carry no private keys or relay session tokens.

## Endpoint relay interface

- `GET /v1/capabilities` reports protocol, schema, revision and features.
- `POST /v1/passkeys/{register,login}/{options,finish}` serves discoverable, user-verified passkeys. The finish payload contains `challenge` and the WebAuthn `credential`. Registration options accept an `invitation` in invitation mode.
- `POST /v1/operator/bootstrap/{options,finish}` requires the deployment bootstrap bearer token. Once the operator passkey exists, it signs in through regular passkey login. Its session can issue an invitation with `POST /v1/operator/invitations` and `lifetimeSeconds`.
- `POST /v1/accounts/<accountId>/endpoint-challenge` takes `endpointId` and `purpose` and returns one nonce. `POST /v1/accounts/<accountId>/actions/<purpose>` requires the endpoint ID in the JSON body and `MyTerm-Nonce` and `MyTerm-Signature` headers. The initial `genesis` requires a personal passkey session for that account and supplies an `anchor` and `signingKey`. For `admit`, supply `targetEndpointId`, `signingKey`, `kind` and `relayEnabled`. A server sends its own `relay-setting` with `revision` and `enabled`.
- The account's initial approving endpoint authorizes `admit` and `revoke`. For `revoke`, supply the approved Companion's `targetEndpointId`. Revocation closes its live sockets, clears pending challenges and tickets, and requires a new endpoint key for later pairing.
- `connect` returns a single-use bearer ticket for the WebSocket upgrade at `GET /v1/accounts/<accountId>/socket`. Read the `liveness` nonce, return `nonce` and `proof`, then wait for `ready` before sending ciphertext. Respond to later liveness challenges with a new signature over the nonce.
- An outbound binary body starts with 32 destination ID bytes followed by ciphertext up to 64 KiB. The relay delivers 32 source ID bytes, 16 receipt bytes and the unchanged ciphertext. The receiver releases frames in delivery order using `{"ack":"<base64url receipt>"}`. If the peer is missing or closes, the sender receives `{"unavailable":"<endpoint ID>"}`.
- Native clients connect with `?flow=1`, wait for `{"queued":"<endpoint ID>"}` before advancing to the next frame, and retry the same frame after `{"deferred":"<endpoint ID>"}`. The Worker defers delivery when the receiver has no space within its 24-frame and 256 KiB budget. Native clients reassemble large packets within their own bounded buffer before authenticating and processing the complete message.
- `POST /v1/accounts/<accountId>/suspension` with `suspended` requires an operator session. The account router serializes suspension with socket delivery and closes the account sockets before returning success.

Endpoint IDs are the lowercase hex SHA-256 digest of a raw Ed25519 public key. Keys, nonces and signatures use unpadded base64url. Sign the following UTF-8 text with one LF between fields and zero trailing LF. The payload hash is lowercase hex SHA-256 over the exact HTTP JSON bytes, or over empty bytes for `liveness`.

```text
myterm-relay-endpoint-v1
<configured public origin>
<stable account anchor>
<actor endpoint ID>
<purpose>
<nonce>
<payload SHA-256>
```

## Release work still open

The relay admission projection holds public route keys. Native endpoints retain membership validation, private keys and traffic encryption. Canonical membership and deployment delegation still need to compose with the relay, and the accepted eight-digit approval ceremony needs its authenticated implementation.

Cloudflare recovery must preserve the current invitation-consumption prefix `registration-invitations/consumed/v1/` outside database restores. Registration writes the conditional marker before acknowledging success. If the marker is written and D1 registration subsequently fails, an operator must issue a new invitation. Lifecycle deadlines currently deny relay access. Durable deletion and revocation suppression, active-data cleanup and lifecycle restore reconciliation require [relay recovery and Grafana operations](https://github.com/GordonBeeming/myterm/issues/153).

Work still to implement includes encrypted inventory and pending-operation storage, account moves, expired authentication-row cleanup and public registration abuse controls. Native opt-out notice delivery and retry cancellation also remain. Hosted WebSocket hibernation, idle cost, load capacity and native session continuity need deployed validation.
