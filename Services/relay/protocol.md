# MyTerm relay protocol

The relay serves one owner account and several registered Macs. Every URL below is relative to the configured HTTPS public origin. Native clients must reject redirects to another origin and send bearer credentials only in the `Authorization` header.

## Browser authentication

The native app generates a PKCE verifier, its S256 challenge, and at least 32 random bytes for `state`. It starts `ASWebAuthenticationSession` with one of these URLs:

```text
GET /auth/register?redirect_uri=<allowed-uri>&state=<state>&code_challenge=<S256>&code_challenge_method=S256&device_name=<name>&device_kind=host|client#bootstrap_token=<initial-owner-token>
GET /auth/register?redirect_uri=<allowed-uri>&state=<state>&code_challenge=<S256>&code_challenge_method=S256&device_name=<name>&device_kind=host|client#enrollment_token=<add-or-recovery-token>
GET /auth/login?redirect_uri=<allowed-uri>&state=<state>&code_challenge=<S256>&code_challenge_method=S256&device_name=<name>&device_kind=host|client
```

`bootstrap-owner` is the only way to create the owner account. After that, `add-passkey` issues a token that preserves every existing credential, while `recover-owner` issues a token that replaces every credential and revokes every device session after the new credential has passed WebAuthn verification. The server stores each token's purpose; the browser cannot choose or change it. Every command prints a URL that MyTerm imports, adds the PKCE query fields to, and opens as a browser session. The token stays in the URL fragment, which browsers do not send to the relay or Caddy. Each token is one use and expires. The login page performs a WebAuthn passkey ceremony with user verification required. A successful ceremony returns:

```text
myterm-companion://auth/callback?code=<one-time-code>&state=<state>
```

The exact redirect allowlist is:

- `myterm-companion://auth/callback`
- `myterm-companion-dev://auth/callback`
- `myterm://companion-auth/callback`
- `myterm-dev://companion-auth/callback`

The app compares `state` before exchanging the code.

`POST /v1/oauth/token` accepts JSON and returns JSON. An authorization-code request is:

```json
{
  "grant_type": "authorization_code",
  "code": "opaque code",
  "code_verifier": "original PKCE verifier",
  "redirect_uri": "myterm-companion://auth/callback"
}
```

A refresh request is:

```json
{
  "grant_type": "refresh_token",
  "refresh_token": "opaque refresh token"
}
```

Both return:

```json
{
  "access_token": "opaque access token",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "new opaque refresh token",
  "device_id": "6e772287-dcb1-4b38-a543-f2d14dc8bbf6",
  "account_id": "d07b3589-a41c-49b8-9f7b-2ee7f2c45201"
}
```

Refresh tokens rotate on every successful use. Reuse of an old value fails. `POST /v1/oauth/revoke` with `{"token":"..."}` revokes the owning device token family. Revocation is idempotent.

## Host registrations

All host routes require a bearer access token. A host token can register its own installation; either host or client tokens can list hosts in their account.

`PUT /v1/hosts/{host_id}` uses a stable UUID generated and persisted by the Mac installation. The relay does not assign this ID. Repeating the request after login or token refresh updates the same registration.

```json
{
  "name": "Gordon's MacBook Pro",
  "public_key": "base64url encoded pinned HPKE key-agreement public key"
}
```

The response is:

```json
{
  "host": {
    "host_id": "ed97b573-629c-43d7-ae74-dc64e356a31c",
    "name": "Gordon's MacBook Pro",
    "public_key": "base64url encoded pinned HPKE key-agreement public key",
    "transport_online": false
  }
}
```

`GET /v1/hosts` returns `{"hosts":[...]}` using the same host shape. `transport_online` reports only that an authenticated host WebSocket is present. It is not proof that the peer owns the pinned host key. Native code must authenticate an encrypted, signed application hello before enabling input.

`DELETE /v1/hosts/{host_id}` requires the host device that owns the registration and removes the host plus its stored legacy relay state.

`DELETE /v1/hosts/{host_id}/connections/{connection_id}` requires the token for the host device that owns the registration. It closes only that live client WebSocket. A missing connection under a known host is an idempotent 204. A client token, another host token, a host-role connection ID, or a connection under another host returns 403. This endpoint changes transport presence only; the Mac keeps its revoked E2EE peer-key registry and rejects future application frames independently.

## Device sessions

`GET /v1/devices` returns `{"devices":[{"device_id":"...","kind":"client","name":"Gordon's iPhone","created_at":1789470900,"revoked_at":1789471200}]}`. `revoked_at` is absent for an active session, and token material is never returned.

`DELETE /v1/devices/{device_id}` is owner scoped, revokes its refresh and access state, closes all of that device's live WebSockets, and returns 204. Revoked records remain visible so owners can identify prior sessions. Pairing tickets and secrets are not relay HTTP resources; Pair Mode travels as opaque E2EE WebSocket traffic and the Mac is the authority.

## WebSocket transport

Connect to `GET /v1/transport/ws?host_id=<stable-host-uuid>&role=host|client` over `wss`. Supply `Authorization: Bearer <access-token>` during the HTTP upgrade. Tokens in the URL or subprotocol are rejected. A host role requires the access token for the device that owns the host registration. Client roles require a client device in the same account.

The server sends UTF-8 JSON control messages. A peer sends one only to refresh its authentication, described below; everything else it sends is binary.

```json
{
  "type": "ready",
  "protocol": 1,
  "connection_id": "fc0b4b58-0f39-41af-95be-83b15a15d39e",
  "host_id": "ed97b573-629c-43d7-ae74-dc64e356a31c",
  "role": "client",
  "max_frame_bytes": 1048576,
  "heartbeat_seconds": 20,
  "expires_at": 1790000000,
  "auth_refresh": true
}
```

`expires_at` is the Unix time at which the relay will close this connection, which is the expiry of
the access token it was opened with. `auth_refresh` says the relay accepts a refresh; a relay from
before that existed omits it and closes any connection that sends one, so a peer must treat a
missing field as false and stay silent.

To keep a connection past that time, a peer sends a text message with a current access token before
it expires:

```json
{
  "type": "auth",
  "access_token": "<access-token>"
}
```

The relay revalidates the token, requires it to belong to the same device, moves the connection's
expiry to the new token's expiry, and replies:

```json
{
  "type": "auth_ok",
  "expires_at": 1790000900
}
```

A token that is rejected closes the connection. A token the relay cannot check right now, because
its storage is unavailable, produces `{"type":"error","code":"auth_unavailable"}` and leaves the
connection on its existing expiry to try again. A device that can no longer obtain a valid token
still stops at its last validated expiry, so this does not extend how long a revoked device lasts.

```json
{
  "type": "peer",
  "connection_id": "ca249e21-da21-43e2-a37f-0eb42ed0d445",
  "role": "host",
  "transport_online": true
}
```

The relay sends a `peer` event with `transport_online:false` when that connection leaves. Connection IDs apply only to the current WebSocket lifetime. A host receives one online event for every client already present and later lifecycle changes. A client receives the current host event and later host lifecycle changes. There can be one host connection and many client connections for a host.

Application messages are binary:

```text
byte 0       protocol version, currently 0x01
bytes 1..16  destination connection UUID in network byte order
bytes 17..N  opaque authenticated ciphertext
```

For a client-to-host frame, the destination may be the current host connection ID or all zero bytes. For a host-to-client frame, it must be one live client connection ID; all zero bytes broadcasts to every live client. The relay validates the destination against the authenticated account, host, and role, then replaces bytes 1 through 16 with the trusted source connection UUID before forwarding. This prevents source spoofing while leaving ciphertext untouched.

The default maximum frame is 1 MiB, including the 17-byte relay header. Each connection has a bounded outbound queue. A slow receiver is closed with WebSocket status 1013. The relay uses WebSocket ping and pong for heartbeat and closes dead connections. It also closes a socket when the access token expires or its device session is revoked. JSON control messages describe transport presence only; application reachability and trust come from the encrypted protocol.
