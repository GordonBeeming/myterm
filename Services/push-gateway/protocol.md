# MyTerm push gateway protocol

Every route is relative to the configured HTTPS gateway origin. Tokens are accepted only in the `Authorization` header. JSON is strict: unknown fields fail the request.

Binary values use unpadded base64url unless a field says otherwise. `key_id` preserves the standard padded Base64 string returned by `DCAppAttestService.generateKey`. Timestamps are Unix seconds. Public signing keys use the 65-byte ANSI X9.62 uncompressed P-256 form.

## Enroll an app installation

Create a one-use App Attest challenge:

```http
POST /v1/enrollments
Content-Type: application/json

{}
```

```json
{
  "enrollment_id": "0561412a-20ac-47f1-8c6f-e5359c02f7d1",
  "challenge": "base64url random 32 bytes",
  "expires_at": 1789471200
}
```

The app calls `attestKey(_:clientDataHash:)` with `SHA256(challengeBytes)`, then submits the result:

```http
POST /v1/enrollments/{enrollment_id}/attest
Content-Type: application/json

{
  "key_id": "standard padded Base64 App Attest key identifier",
  "attestation_object": "base64url CBOR",
  "device_public_key": "base64url X9.62 P-256 key",
  "apns_token": "lowercase hexadecimal APNs device token"
}
```

The gateway verifies the Apple certificate chain, nonce, configured Team ID and bundle ID, counter, environment AAGUID, credential ID, and key identifier. It then sends a random ownership challenge to the supplied APNs token. The HTTP response does not contain that challenge:

```json
{
  "enrollment_id": "0561412a-20ac-47f1-8c6f-e5359c02f7d1",
  "status": "awaiting_apns_confirmation"
}
```

After receiving the notification, the app builds these exact UTF-8 bytes:

```text
myterm-app-attest-v1\nenrollment-activate\n{enrollment_id}\n{challenge}
```

It calls `generateAssertion(_:clientDataHash:)` using the App Attest key and `SHA256(canonicalBytes)`, then activates the record:

```http
POST /v1/enrollments/{enrollment_id}/activate
Content-Type: application/json

{
  "assertion": "base64url CBOR assertion"
}
```

```json
{
  "recipient_id": "c998bdb0-a80b-4e9f-bf30-4e2bb8f44c48",
  "device_session_token": "opaque device bearer",
  "token_type": "Device"
}
```

The enrollment challenge, App Attest counter, and APNs ownership challenge are one use. The device is inactive until all checks pass.

## Authenticate device management requests

Recipient-grant and APNs-token management requests carry these headers:

```http
Authorization: Device {device_session_token}
X-MyTerm-Timestamp: 1789470900
X-MyTerm-Nonce: base64url random 16 to 32 bytes
X-MyTerm-Signature: base64url DER ECDSA P-256 signature
```

Build the signature input from the exact request body bytes:

```text
myterm-device-v1\n{UPPERCASE_METHOD}\n{escaped_path}\n{timestamp}\n{nonce}\n{base64url_sha256_body}
```

Sign `SHA256(signatureInput)` with the private key matching `device_public_key`. The gateway allows five minutes of clock skew and consumes each nonce once.

## Manage recipient grants

Create a grant for one relay, one Mac installation, one pinned Mac signing key, and the authenticated recipient:

```http
POST /v1/recipient-grants
Authorization: Device ...

{
  "relay_origin": "https://relay.example.com",
  "host_id": "stable Mac installation UUID",
  "host_public_key": "base64url X9.62 P-256 key"
}
```

```json
{
  "grant_id": "10c9f30e-ad5f-442d-93ab-f1867ef89c60",
  "grant_token": "opaque bearer restricted to this recipient",
  "token_type": "Grant"
}
```

`POST /v1/recipient-grants/{grant_id}/rotate-token` returns a replacement token and immediately invalidates the old one. `DELETE /v1/recipient-grants/{grant_id}` revokes the grant. Both require device authentication. The gateway never contacts `relay_origin`; it is an identity string in the authorization record, not a fetch target.

## Update an APNs token

Token rotation repeats APNs possession proof. The authenticated device starts it with `POST /v1/apns-token-challenges` and `{"apns_token":"lowercase hexadecimal token"}`. The gateway sends a random value to that token and returns only `{"challenge_id":"...","status":"awaiting_apns_confirmation"}`.

After receiving the push, the device sends a signed `POST /v1/apns-token-challenges/{challenge_id}/confirm` request with `{"challenge":"base64url value from APNs"}`. The gateway changes the active APNs token only when the signature, challenge, expiry, and recipient all match.

## Request a notification

The relay or Mac uses the grant token and a host-signed event:

```http
POST /v1/notifications
Authorization: Grant {grant_token}
Content-Type: application/json

{
  "event_id": "06d368fc-1173-4f33-aac6-82cfc949374a",
  "timestamp": 1789470900,
  "ciphertext": "base64url opaque encrypted event",
  "host_signature": "base64url DER ECDSA P-256 signature"
}
```

The Mac signs `SHA256` of these exact UTF-8 bytes:

```text
myterm-host-event-v1\n{grant_id}\n{recipient_id}\n{event_id}\n{timestamp}\n{base64url_sha256_ciphertext}
```

The gateway checks the host key stored in the grant, timestamp, event replay, active recipient, grant token, and payload size before contacting APNs. Success returns HTTP 202:

```json
{
  "event_id": "06d368fc-1173-4f33-aac6-82cfc949374a",
  "apns_id": "APNs response identifier"
}
```

The APNs payload contains a generic alert, `mutable-content:1`, grant, recipient and event routing IDs, the integer event timestamp, and the opaque ciphertext. The app uses `grant_id` to load its pinned local record and reconstruct the authenticated context. The complete uncompressed JSON payload cannot exceed 4096 bytes. It contains no relay URL, host name, workspace, terminal title, command, or terminal content.

The gateway uses alert pushes as a notification hint. Delivery is not a reliable wakeup mechanism. APNs status 410 disables the device token. A request for an inactive recipient returns an explicit `recipient_not_available` error.
