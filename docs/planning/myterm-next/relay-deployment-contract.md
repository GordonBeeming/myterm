# Relay deployment contract

This is the release deployment design for [Choose the relay deployment configuration and service limits](https://github.com/GordonBeeming/myterm/issues/145), under [MyTerm next architecture and implementation](https://github.com/GordonBeeming/myterm/issues/125). It records the policy agreed with Gordon and technical defaults for implementation. It does not describe a deployed replacement for the current relay.

## Release boundary

Our hosted live and beta relays and user-operated relays use the same versioned Cloudflare application. A user-operated relay runs in that user's Cloudflare account. Container/VPS distribution, portability adapters and a second relay runtime are outside this release.

Use the Pokemon application's managed-backend pattern as a reference: TypeScript Workers for HTTP and passkeys, D1 for relay-managed account records, SQLite-backed Durable Objects for connection coordination, and private R2 storage for encrypted backup exports. MyTerm must add an hourly Worker Cron Trigger that starts idempotent, resumable backup work. A Workflow may run that work, without requiring a schedule attached directly to the Workflow. The Pokemon reference has on-demand backup workflows; it does not establish this hourly trigger. Native Rust MyTerm servers and Swift clients remain the endpoint applications.

This supersedes the provisional DigitalOcean/container deployment choice. Existing DigitalOcean/cloudflared services stay in place until a separately authorized cutover has passed validation. This document authorizes no provisioning, purchase, deployment or release.

## Deployment identity and isolation

Each deployment has its own public HTTPS origin, exact-hostname passkey RP ID, Worker identity, D1 database, Durable Object namespace, backup bucket, secrets and monitoring destination. Reject mismatched origins and unsafe RP configuration before accepting sign-in. Cloudflare account ID and resource bindings are operator configuration, not user-provided request data.

Hosted mapping confirmed by Gordon:

| Deployment | Public origin | Passkey RP ID |
| --- | --- | --- |
| Live | https://myterm-relay.gordonbeeming.dev | myterm-relay.gordonbeeming.dev |
| Beta | https://myterm-relay-beta.gordonbeeming.dev | myterm-relay-beta.gordonbeeming.dev |

The existing myterm-relay-dev.gordonbeeming.dev is Gordon's personal development relay, with no external accounts. Do not repurpose it as public beta or copy its accounts into beta. The new beta deployment gets fresh resources and its own passkey identity. Local development uses isolated local state. Development validation, UAT/beta and production/live have separate resources. Run and check changes in that order. A shared Cloudflare account is acceptable; sharing databases, namespaces, backup keys or export credentials across environments is not.

The installed Stable/Beta build supplies a default relay only during initial setup. A saved custom address or an account's verified move location takes precedence afterward. An independent deployment sets its own HTTPS origin and exact-hostname RP ID. Cloudflare hosting does not make independently created accounts the same account.

## Storage and connection authority

D1 holds relay-managed account, passkey, login-session, enrollment, encrypted-directory, move and operator-policy records. The directory remains endpoint-encrypted. Relay records never contain plaintext endpoint private keys or private workspace, terminal or browser contents.

Durable Objects coordinate authenticated encrypted connections. Both native endpoints connect inward to the relay; use hibernation-aware accepted sockets. Keep terminal data out of D1 and R2. Process-local socket state is disposable: on object eviction, code update or platform failure, endpoints reconnect and reauthenticate from authoritative durable state.

Define one authoritative owner for each security transition during implementation. Do not dual-write D1 and object storage as though they were one transaction. Any object-local admission cache must be fenced by durable revocation/deletion state and fail closed when that state cannot be verified. Exact trust, key-distribution and account-move protocols belong to their existing validation tickets.

Measure idle and actively forwarding objects separately. Platform free allowances are conditional on measured usage and shared account consumption. Free-tier exhaustion can cause errors; it is not automatic paid scaling. Deployment validation must report the required plan and measured headroom before activation. Any paid upgrade remains an explicit operator action.

## Configuration contract

The implementation must expose the following settings in a validated deployment manifest. These are logical configuration names, not claims about already implemented environment variables.

| Setting | Hosted default / rule |
| --- | --- |
| Deployment identity | Explicit channel, public HTTPS origin, exact-hostname RP ID |
| Cloudflare resources | Explicit account and environment-specific Worker, D1, Durable Object and R2 bindings |
| Registration | Public for hosted; invitation-only by default for user-operated relays; open mode configurable |
| Operator bootstrap | Authenticated Cloudflare deployment/setup command for hosted and user-operated relays; no first-public-visitor ownership |
| Invitations | Operator-managed, expiring, single-use registration authorizations |
| Diagnostics | Grafana Cloud for hosted; no export to our account from user-operated deployments by default |
| Log history | Start with Grafana Free's 14-day history; reassess plan from measurements and operational needs |
| Raw IP diagnostics | Off initially; enabling requires a restricted store with verified maximum seven-day retention, including recovery copies; excluded from exports |
| Backup interval | Hourly, resumable and idempotent |
| Backup retention | At most 30 days; shorter retention configurable |
| Account active-data deletion | Within 24 hours; access disabled immediately |
| Move forwarding | Two weeks by default, configurable; absolute expiry preserved across restores |
| Usage quotas | Deferred until measurements justify policy; retain authentication and protocol safety bounds |
| Version identity | Immutable application revision, schema versions and supported protocol/features |
| Alert destination | Gordon's configured email for hosted; operator-configurable for user-owned deployments |

For initial setup, the person deploying the relay signs into their own Cloudflare account and runs the deployment/setup command. We use the same setup for our hosted deployments. That authenticated setup creates their deployment's operator access and invitation controls, without allowing an unrelated first visitor to claim ownership. Operator setup establishes deployment administration, not endpoint approval. It cannot grant a client or server account trust, decrypt a directory or bypass the additional trusted-endpoint approval requirement. Suspension can disable relay access and revoke relay sessions without deleting server-local workspaces or stopping their processes.

Put deployment secrets in Cloudflare secret bindings or the provider's protected destination configuration. Keep operator credentials, backup encryption keys and export tokens out of repository manifests, command output, URLs and logs. Gordon-managed credentials use the ai-secrets vault and existing 1Password workflow. User-operated deployments use their own credentials. Rotation and restore instructions must state which secrets are required; never package our production secrets with the application.

## Diagnostics and alerts

Use Grafana Cloud for hosted searchable logs, service measurements and email alerts. Keep live and beta identifiable and access-controlled. Give each environment separate export credentials and destinations; verify actual provider isolation and plan support rather than assuming dashboard folders isolate data.

Service-owned diagnostics may retain opaque account, server, client, request and other entity reference IDs after account deletion. They remain linkable operational data. Allow typed event names, timestamp, severity, outcome, duration, bounded error code, software version, deployment identity and necessary entity references. Do not export personal names, entity display names, addresses, private contents, credentials, keys, full request URLs, query strings, headers or arbitrary exception payloads.

Entity IDs are searchable structured fields, not metric dimensions or Loki stream labels. Keep metric dimensions bounded. Application raw-IP collection is off initially. If an operator enables it, use a separate restricted R2 store excluded from exports and restore histories; check expiry on reads and actively purge before seven days. Do not put raw IPs in D1 or Durable Object state with longer recovery windows. Enabling requires evidence that all retained copies meet the seven-day maximum; otherwise leave it disabled. Inventory platform-created edge and invocation logs too; ordinary Grafana or backup retention cannot extend the IP window.

Emit a sanitized application-only OTLP stream to Grafana by default. Disable automatic invocation logging, trace capture, Cloudflare log persistence and tail/Logpush export unless the implementation verifies the same field and retention boundaries across every destination. Do not copy Pokemon's observability settings unchanged. Cloudflare's native logs/traces export is an optional path only after its complete envelope passes those checks; provider-managed metadata is not assumed to be redactable. Do not run a dedicated collector VM. Native log/trace export does not establish a metrics export path: demonstrate service measurements and alert queries using reviewed logs or explicit bounded metrics.

Start with alerts for externally observed relay failure, sustained server errors, resource/platform-limit failures and missing telemetry or backups. Alert on sustained authentication anomalies separately from ordinary rejected sign-ins. Email delivery and recovery notifications must be exercised with synthetic data. Initial engineering defaults are one-minute probes with three consecutive failures, five-minute sustained-error windows and a two-hour backup freshness warning; tune thresholds from validation without introducing user quota policy.

## Backups, deletion and restoration

Take consistent hourly exports of durable relay account state, with a versioned manifest, checksums, absolute expiries and application revision. Encrypt each export before private R2 storage using a fresh data key and authenticated encryption. Keep its protected key record and usable lifetime in a separate private R2 key bucket, excluded from every backup/restore and application version history. Do not store export keys in D1 or Durable Object recovery histories, or include a usable export key in the export. Purge key records before the 30-day limit and verify the provider's residual-copy behavior; if that bound cannot be established, report the retention gap before rollout rather than claiming cryptographic expiry. Exclude transient sockets, terminal traffic, raw-IP diagnostics and reusable plaintext service secrets. Export all durable state needed for account continuity; if authoritative state spans D1 and objects, implement a tested consistent checkpoint or explicitly quiesce mutations during the checkpoint.

Keep the current deletion/revocation ledger in a separate private R2 control bucket, never in the database or object namespace being restored. Commit its append-only suppression record before acknowledging deletion or revocation; new access must consult current suppression state, and a failed ledger write cannot produce a success acknowledgment. The record contains only opaque entity references, security epoch, action and timestamp. Record single-use invitation consumption in the same non-restored control state before acknowledging registration, so an old snapshot cannot make an invitation usable again. Retain these minimal service-owned records without expiry initially, so every recoverable snapshot and delayed credential is covered. Restore commands must never overwrite or roll back this bucket. A restore unable to obtain current suppression evidence stays offline. Service logs are not the ledger, and no account/client/server ID is reused.

Restoration runs in isolation before routes are enabled. Validate manifest integrity, schema/protocol compatibility and required secret references; apply the latest deletion/revocation ledger; reject expired login, enrollment and move records; rebuild ephemeral connection routing. A move must not regain another two weeks because an old snapshot was restored. A deleted account must not reappear or regain usable credentials.

Account deletion removes active account records within 24 hours; the account's encrypted data may remain in existing recovery copies until their expiry, at most 30 days after deletion. Exports begun or finalized after suppression must exclude the deleted account. Check the current ledger before finalizing an export; if deletion races with the checkpoint, discard/rebuild affected chunks or abort and retry. Never reset an account's deletion deadline by writing its data into a newer export. Service-owned suppression references remain. Each export's usable data key must expire no later than that export's 30-day limit; verify that no key-record recovery copies remain usable. Start physical export and abandoned-chunk cleanup before the limit, using a day-29 lifecycle rule as a backstop, application cleanup and expiry checks. Cloudflare says lifecycle deletion typically follows expiry within 24 hours, so lifecycle configuration alone is not proof of a hard deletion bound. Verify key expiry and removal behavior; report any provider-controlled residual-copy limitation before rollout rather than extending the agreed policy to 31 days.

Provider-managed recovery history is another copy of data. Inventory D1 and Durable Object recovery windows and prove restores preserve deletion/revocation. Do not claim individual historical rows are physically purged merely because active records were deleted.

Recovery initially aims at at most one hour of lost relay changes and service restoration within four hours, best effort rather than an SLA. A failed backup raises an alert and worsens the actual recovery point. A Cloudflare-account-wide loss is not covered by a backup kept only in that same account; independent disaster recovery is not promised for this initial deployment.

## Versions, upgrades and rollback

Pin the Worker source revision, dependency lockfile, compatibility date, D1 migrations, object schema transitions and backup format. Provide a preflight capability document with protocol range, required features and move-acceptance compatibility. Do not expose account contents through that public document. Account moves must check compatibility before commitment and otherwise follow their validation ticket.

For each upgrade: record the active code/schema revision, verify a recent usable backup, apply compatible schema expansion, deploy to development, verify, then UAT/beta, verify, then production/live and verify. Reconnecting endpoints must remain account-scoped and encrypted. Do not publish a release as a side effect.

Prefer additive schema changes with a tested previous-code compatibility window. Worker rollback does not roll back D1, R2 or Durable Object state, and some binding/class changes prevent native rollback. Every release must state whether code-only rollback is supported. Otherwise supply a tested isolated restore or forward-fix procedure before deployment. Preserve deletion suppression through either route.

## Required acceptance evidence

The implementation must ship one headless verification entry point per group below, with exact invocations in its README and machine-readable output. Commands are deliverables of the implementation, not commands that exist in this documentation-only change. Run local development first, then separately authorized Cloudflare development, UAT/beta and production smoke checks. A local simulator is not evidence of hosted provider behavior.

| Group | Required cases and evidence |
| --- | --- |
| Configuration/build | Manifest validation, generated bindings, type checks, migrations, unit tests and deployment dry run; reject crossed environment resources and unsafe origin/RP settings |
| Account operations | Passkey-only hosted registration, invitations/open self-host modes, operator bootstrap, trusted endpoint approval, suspension, deletion and move compatibility gates |
| Connections | Two native endpoint fixtures exchanging binary ciphertext; delete an account with active relay connections and verify neither direction delivers frames after successful deletion acknowledgment; wrong-account rejection; idle hibernation; eviction/redeploy reconnect; slow receivers and bounded memory |
| Privacy/diagnostics | Inject forbidden data into requests/errors; inspect complete Cloudflare and Grafana envelopes; verify entity search, bounded metric labels, IP expiry and email alert/recovery delivery |
| Backups | Repeat hourly jobs/retries, corrupt and partial exports, concurrent mutations, independent restore, old snapshots after deletion/revocation, deletion racing with export finalization, consumed-invitation replay after restore, expiry/cleanup and failed-ledger recovery |
| Upgrades | Beta-first promotion, old/new schema compatibility, code rollback where supported, incompatible migration restore/forward fix and no account resurrection |
| User-operated deployment | Follow repository instructions in a separate Cloudflare account with fresh resources, own origin/RP identity, own operator and diagnostics; no dependency on our secrets |
| Performance/cost | Quiet sockets and active binary streaming; fan-out, reconnect bursts and slow receivers; report latency, throughput, active object duration, rows read/written, export volume and platform headroom |

Record workload parameters, frame sizes/rates, concurrent connections, versions, region/account plan, duration and baseline for performance runs. The gate requires no cross-account delivery, lost/duplicated application data outside the documented reconnect contract, unbounded queues or unrecovered failures. Record performance/cost results for this release before introducing product quotas. Numerical performance acceptance thresholds must be set with the transport prototype and release-acceptance decision rather than invented from the Pokemon workload.

## Follow-up work

- [Implement the Cloudflare relay and account operations](https://github.com/GordonBeeming/myterm/issues/152)
- [Implement relay recovery and Grafana operations](https://github.com/GordonBeeming/myterm/issues/153)
- [Validate the Cloudflare relay before hosted cutover](https://github.com/GordonBeeming/myterm/issues/154)

Implement the Cloudflare relay and its repeatable deployment after the trust-protocol boundary is validated. Verify backup/deletion, privacy and metrics export against real provider behavior before hosted activation. Existing account-move and release-acceptance tickets retain their responsibilities.

This decision finishes deployment policy and the implementation contract. Passing the future acceptance groups, live cloud provisioning, cutover and application releases remain separate work.

## Evidence and sources

The Pokemon repository was inspected read-only at its current local checkout. Its versioned backup chunks, manifests, checksums, restore tests and latest-ten cleanup are useful references. The checked-in Wrangler manifest has no hourly trigger; it does not establish that the running deployment has one, nor does latest-ten retention establish a 30-day policy.

- [Cloudflare candidate investigation](../../research/myterm-next-cloudflare-relay-options.md)
- [Managed telemetry comparison](../../research/myterm-next-managed-telemetry-options.md)
- [Durable Object WebSockets and hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)
- [D1 Time Travel](https://developers.cloudflare.com/d1/reference/time-travel/)
- [Durable Object SQLite recovery](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [R2 lifecycle deletion timing](https://developers.cloudflare.com/r2/buckets/object-lifecycles/)
- [Workers OTLP export](https://developers.cloudflare.com/workers/observability/opentelemetry-export/)
- [Worker versions and external state](https://developers.cloudflare.com/workers/versions-and-deployments/)
- [Hourly Worker Cron Triggers](https://developers.cloudflare.com/workers/configuration/cron-triggers/)
- [Worker rollback constraints](https://developers.cloudflare.com/workers/versions-and-deployments/rollbacks/)
