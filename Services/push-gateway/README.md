# MyTerm shared push gateway

This service delivers encrypted MyTerm event hints through APNs. It authenticates iOS app installations with Apple App Attest, proves possession of each APNs token with a random challenge delivered through APNs, and accepts notifications only through recipient grants created by the attested device.

The gateway can see recipient and grant identifiers, delivery timing, and ciphertext length. It cannot decrypt the event. APNs receives a generic "MyTerm needs attention" alert, routing identifiers, and the opaque encrypted body. Workspace names, terminal titles, commands, relay URLs, and terminal content are excluded.

## Configuration

Copy `.env.example` into the service environment and set every placeholder. `MYTERM_PUSH_APNS_KEY_FILE` must point to the topic-specific Apple `.p8` signing key mounted outside the image. Do not put the key in the repository or image.

The App Attest environment must match the app entitlement. TestFlight, App Store, and Enterprise distributions use production App Attest even when the app was built from a development workflow. The APNs sandbox and production endpoints are separate settings.

The verifier is anchored to the [Apple App Attestation Root CA](https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem) and follows Apple's [server validation procedure](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server). It preserves Apple's standard Base64 key identifier and checks the certificate chain, nonce, configured app identifier, environment AAGUID, counter, credential ID, COSE public key, and key identifier. When Apple supplies distribution extensions, it also checks the bundle version and permits validation category 3 for development or categories 2 and 4 for production. Older attestations without those optional extensions remain valid. Production has no environment switch that skips attestation.

## Run behind HTTPS

The gateway listens on `127.0.0.1:8790` by default. Run it behind Caddy using `Caddyfile.example`:

```sh
cd Services/push-gateway
set -a
. ./.env
set +a
go run ./cmd/myterm-push-gateway
```

For a container deployment, mount the SQLite directory and `.p8` key separately. The final image runs as `nonroot:nonroot`.

```sh
docker build -t myterm-push-gateway ./Services/push-gateway
docker run -d --name myterm-push-gateway --restart unless-stopped \
  --read-only --tmpfs /tmp -p 127.0.0.1:8790:8790 \
  --mount type=bind,src=/srv/myterm-push,dst=/data \
  --mount type=bind,src=/srv/secrets/AuthKey.p8,dst=/run/secrets/AuthKey.p8,ro \
  --env-file /srv/myterm-push/gateway.env \
  -e MYTERM_PUSH_LISTEN=0.0.0.0:8790 \
  -e MYTERM_PUSH_DATABASE=/data/push-gateway.sqlite3 \
  -e MYTERM_PUSH_APNS_KEY_FILE=/run/secrets/AuthKey.p8 \
  myterm-push-gateway
```

Caddy runs on the Linux host and connects through the loopback-only published port. The mounted data directory must be writable by UID 65532. Keep the provider key readable only by that account.

`GET /livez` reports process liveness. `GET /readyz` checks SQLite availability. Neither response includes configuration or credential data.

## APNs behavior

The provider uses Apple's HTTP/2 API directly. Its ES256 provider JWT is cached for 30 minutes, within Apple's 20-to-60-minute refresh window. Requests set the configured topic, `alert` push type, priority 10, expiration 0, and an event collapse ID. The complete uncompressed JSON body is checked against Apple's 4096-byte limit before sending.

HTTP 429 and 5xx responses retry at most twice after the first attempt, honoring a bounded `Retry-After`. Network errors use the same three-attempt ceiling. An APNs 410 response deactivates the recipient until the app proves possession of an updated token. The gateway returns explicit unavailable errors and does not treat a silent notification as a dependable wakeup path. See Apple's [provider token guidance](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns) and [notification request limits](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).

## Security boundaries

Device management calls require the opaque device session, a timestamp, a one-use nonce, and a P-256 signature from the key enrolled with App Attest. Recipient grants bind one recipient to one HTTPS relay identity, one stable Mac installation ID, and one host notification signing key. Grant tokens rotate and revoke immediately. Host events carry a fresh timestamp, unique event ID, ciphertext, and a matching host signature.

The relay origin is stored as an authorization label. The gateway never connects to it and has no generic forwarding or URL-fetching endpoint. Request bodies use strict JSON and size limits. Enrollment and notification routes have source-IP rate limits. Request handlers and startup logs do not print tokens, APNs device identifiers, payloads, or provider credentials.

The full native wire contract and signature inputs are in [protocol.md](protocol.md).

## Verify

```sh
go test ./...
go test -race ./...
go vet ./...
```

Tests generate a certificate authority, App Attest-style leaf certificate, nonce extension, authenticator data, and P-256 assertions. APNs tests use a local HTTP transport with generated signing material. No Apple credential or device token is required.
