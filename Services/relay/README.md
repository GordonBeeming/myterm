# MyTerm relay

The MyTerm relay connects a Mac host to its iPhone and iPad clients without seeing terminal content. It has one owner account, supports several registered Macs, and forwards opaque encrypted WebSocket frames within the authenticated account and host boundary.

The relay stores WebAuthn public credential records, token hashes, host public keys, and device metadata in SQLite. Passkey private keys, terminal content, pairing secrets, APNs provider keys, and arbitrary proxy destinations do not enter the service.

## Requirements

For a complete deployment through Cloudflare Tunnel, follow [the proxy setup guide](../../docs/PROXY_SETUP.md). Cloudflare handles public HTTPS and cloudflared connects to local HTTP; the Caddy instructions below are an alternative.

- Go 1.26.6 or the supplied container image
- A DNS name with an HTTPS certificate
- Caddy or another reverse proxy that supports WebSocket upgrades
- A persistent volume for the SQLite database

WebAuthn requires a secure origin and a DNS RP ID. An IP address, plain HTTP origin, or public URL inferred from a request is rejected. The server listens on `127.0.0.1:8787` by default so TLS can terminate at Caddy on the same machine.

## Release distribution

The relay packaging workflow builds Linux amd64 and arm64 Docker image archives and SHA-256 checksum files for product releases. Follow [the proxy setup guide](../../docs/PROXY_SETUP.md) to download and load a published image. Source builds below are for relay development.

Each architecture is smoke-tested on a matching Linux runner before publication. Release uploads deliberately refuse to overwrite existing assets. If an upload is interrupted, inspect the release's assets and compare their checksums with the retained workflow artifacts, then upload only the missing files from that same run. Publish a new version for changed binaries instead of replacing an existing release's images.

## Configure and run

Copy `.env.example` into the environment used by the service and change the public origin and RP ID. The RP ID must equal the public hostname or be its registrable suffix.

```sh
cd Services/relay
set -a
. ./.env
set +a
go run ./cmd/myterm-relay serve
```

The service creates the database directory with owner-only permissions and applies its embedded migration at startup. Back up the SQLite database and its WAL files together, or use SQLite's online backup command while the service is running.

Put `Caddyfile.example` in Caddy's configuration after replacing the hostname. Keep the relay listener on loopback when Caddy runs on the host. For Caddy running on the Linux host, publish the container port only on host loopback. Prepare `/srv/myterm-relay` with owner UID 65532 and mode 0700, then mount it at `/data`:

```sh
docker build -t myterm-relay ./Services/relay
docker run -d --name myterm-relay --restart unless-stopped \
  --read-only --tmpfs /tmp -p 127.0.0.1:8787:8787 \
  --user 65532:65532 \
  --mount type=bind,src=/srv/myterm-relay,dst=/data \
  -e MYTERM_RELAY_PUBLIC_URL=https://relay.example.com \
  -e MYTERM_RELAY_RP_ID=relay.example.com \
  -e MYTERM_RELAY_LISTEN=0.0.0.0:8787 \
  -e MYTERM_RELAY_DATABASE=/data/relay.sqlite3 \
  myterm-relay
```

For the container above, create the first enrollment link with `docker exec myterm-relay /app/myterm-relay bootstrap-owner --expires 15m`. The `add-passkey` and `recover-owner` commands use the same form. These commands share the running service's persistent database.

The final public hostname must resolve on every Mac and mobile device, including devices on the local network. Use split DNS or a public name with local routing. Do not weaken TLS verification for a private certificate.

## Register the owner

Anonymous first-claim registration is disabled. Run the bootstrap command on the relay host:

```sh
go run ./cmd/myterm-relay bootstrap-owner --expires 15m
```

Paste the printed URL into MyTerm. MyTerm adds its PKCE and callback parameters, then opens the system browser. The bootstrap token is in the URL fragment, so it is not sent in HTTP request lines or referrers. It is submitted once inside the HTTPS page and stored only as a SHA-256 hash. Restarting the command after the owner exists fails.

The browser creates a passkey with user verification required. The relay verifies the ceremony challenge, HTTPS origin, RP ID, and user-verification flag before it creates the account. It stores the public credential record returned by WebAuthn. Authentication then returns a short-lived one-use code bound to the callback and PKCE challenge.

Add another owner passkey while preserving the existing credentials:

```sh
go run ./cmd/myterm-relay add-passkey --expires 15m
```

If every passkey is unavailable, run recovery on the relay host:

```sh
go run ./cmd/myterm-relay recover-owner --expires 15m
```

Recovery preserves the owner account ID. It replaces the credential set and revokes every device session only after the new WebAuthn credential has been verified and stored in the same transaction. Failed, expired, wrong-purpose, and replayed tokens leave the existing credentials and sessions unchanged.

## Operations

`GET /healthz` returns a small readiness response. It does not inspect the database, so use a separate SQLite backup check if storage health needs monitoring.

The service deliberately avoids request logging. Caddy access logs are optional; if you enable them, configure retention and avoid logging authorization headers. Bootstrap tokens remain absent because URL fragments never reach the server.

Rate limits use the original client address from `X-Forwarded-For` only when the immediate socket peer belongs to `MYTERM_RELAY_TRUSTED_PROXY_CIDRS`. The default trusts loopback Caddy. If Caddy or `cloudflared` runs on a container network, replace this value with the narrow CIDRs for every proxy hop that can connect directly to the relay. Use `none` for a direct deployment without a reverse proxy. The resolver walks the forwarded chain from right to left and ignores client-supplied entries before the first untrusted address. It rejects dangerously broad proxy ranges such as `0.0.0.0/0` and `::/0`.

Access tokens expire after 15 minutes. Refresh tokens expire after 30 days and rotate on every use. A refresh rotates away the previous access token. Revoking either token or deleting a device revokes its device session and closes its active WebSockets. A socket also closes when its access token expires. Authentication routes have per-source-IP token-bucket limits. The relay reads the socket peer address and does not trust forwarded IP headers.

WebSocket messages are capped at 1 MiB by default and each connection has a bounded outbound queue. A slow receiver is disconnected. Ping and pong heartbeats remove dead connections, and clients receive transport presence events. Transport presence is not peer identity: native clients must finish their encrypted signed handshake against the pinned Mac public key before accepting terminal input.

See [protocol.md](protocol.md) for routes, response fields, and the binary frame format.

## Verify

```sh
go test ./...
go test -race ./...
```

The tests generate a P-256 authenticator credential, CBOR attestation object, and signed assertion. They exercise the actual WebAuthn verifier and its challenge, origin, RP ID, and user-verification checks. The TLS WebSocket test covers bearer authentication, source identity stamping, cross-host isolation, routing, and offline events.
