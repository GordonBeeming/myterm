# Cloudflare relay candidate from the Pokemon reference

## Context

Gordon asked to reconsider a managed Cloudflare deployment for MyTerm after pointing to his Pokemon repository at /Users/gordonbeeming/Developer/github/gordonbeeming/pokemon. Gordon subsequently selected Cloudflare's managed developer platform for this release. User-operated relays deploy into their own Cloudflare account. Independent container/VPS self-hosting and portability adapters are outside this effort. No replacement has been implemented or deployed.

The Pokemon repository was inspected read-only at commit e5a282f3f4eee142a4d35a27f7fb7a45b413abf6. The referenced source files match that commit; unrelated local metadata was left untouched. Its configuration establishes how that application is written and deployed, not its actual bill or MyTerm's capacity.

## What the reference contains

- apps/web/wrangler.jsonc declares a TypeScript Worker, a D1 database with SQL migrations, SQLite-backed Durable Objects, private R2 storage and Workflows.
- apps/web/src/worker/index.ts defines a Hono application and an AuthCoordinator Durable Object with SQL-backed challenge consumption and rate limiting.
- apps/web/migrations contains versioned schema migrations.
- apps/web/src/worker/lib/backup.ts and associated restore/consistency tests implement application-level backup and restore.
- The README documents passkey authentication, local development isolation, generated binding types, integration checks and deployment validation.

Pinned reference sources:
- [Worker bindings](https://github.com/GordonBeeming/pokemon/blob/e5a282f3f4eee142a4d35a27f7fb7a45b413abf6/apps/web/wrangler.jsonc)
- [HTTP and authentication coordinator](https://github.com/GordonBeeming/pokemon/blob/e5a282f3f4eee142a4d35a27f7fb7a45b413abf6/apps/web/src/worker/index.ts)
- [Backup format and latest-ten cleanup](https://github.com/GordonBeeming/pokemon/blob/e5a282f3f4eee142a4d35a27f7fb7a45b413abf6/apps/web/src/worker/lib/backup.ts)
- [Backup workflow](https://github.com/GordonBeeming/pokemon/blob/e5a282f3f4eee142a4d35a27f7fb7a45b413abf6/apps/web/src/worker/workflows/backup.ts)
- [Operating instructions](https://github.com/GordonBeeming/pokemon/blob/e5a282f3f4eee142a4d35a27f7fb7a45b413abf6/README.md)

These are useful patterns for a managed MyTerm relay. The card catalogue does not establish streaming-relay cost or performance: no WebSocket relay was found in the inspected Worker code.

## Relevant platform capabilities

Durable Objects can accept WebSockets from clients and servers, coordinate connections, and handle binary messages. Their hibernation API preserves idle connections while the object sleeps, with no duration charge during eligible idle periods. Active messages wake the object and must be included in cost and capacity measurements.

Sources:
- https://developers.cloudflare.com/durable-objects/best-practices/websockets/
- https://developers.cloudflare.com/durable-objects/platform/pricing/

SQLite-backed Durable Objects are available on Workers Free. Free capacity is bounded, and exceeding a free-tier limit causes operations to fail. A zero-cost initial deployment is a candidate to measure, not a cost guarantee derived from the Pokemon application's bill.

Source: https://developers.cloudflare.com/durable-objects/platform/pricing/

## Portability boundary

Gordon narrowed the map's self-hosting requirement: the same Cloudflare relay software runs in our account and in user-owned Cloudflare accounts. A versioned container distribution is no longer a release deliverable. The runtime observations below explain the earlier portability investigation; no portability implementation is required.

workerd is an open-source Workers runtime that can serve production traffic. Its direct Wrangler configuration support excludes D1, R2 and Workflows, and its local Durable Object persistence is marked experimental. Those limitations need an explicit supported deployment design. Miniflare simulates bindings for development/testing; a passing local Worker run is not production deployment evidence.

Sources:
- https://github.com/cloudflare/workerd
- https://github.com/cloudflare/workerd/blob/main/src/workerd/server/workerd.capnp
- https://developers.cloudflare.com/workers/testing/miniflare/

## Assessment and next evidence

Cloudflare is the selected relay deployment platform. Finalize its managed persistence and Durable Object routing design, using the Pokemon application as a reference. Our hosted service and user-operated relays use the same versioned Cloudflare deployment with separate resources and configuration.

The comparison needs evidence for encrypted binary forwarding, idle sockets and active streaming, reconnect after object eviction or rollout, slow receivers, account isolation, durable admission/revocation state, deletion and restoration, and a repeatable deployment into a separate user-owned Cloudflare account.

Record requests, messages, active object duration, database reads/writes, storage growth, latency, memory and disconnects under repeatable workloads. Measure quiet and continuously active sessions separately. Cloudflare selection and the Cloudflare-only self-hosting scope are settled. Schema layout and detailed deployment settings remain to be finalized.

No prototype, load test, paid service, secret access, deployment or source-control write occurred as part of this investigation.
