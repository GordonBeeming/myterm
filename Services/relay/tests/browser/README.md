# Relay browser WebAuthn test

This test starts an isolated HTTPS relay at `relay.localhost`, creates a short-lived self-signed certificate and SQLite database, then drives the real authentication page with headless Chromium and a CDP virtual authenticator.

```sh
cd Services/relay/tests/browser
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci
npm test
```

The script uses the installed Google Chrome binary, trusts only the generated fixture certificate through its SPKI hash, and writes screenshots to `test-results` by default. Set `MYTERM_RELAY_EVIDENCE_DIR` to preserve them elsewhere, as CI does. It stops the fixture and removes its database, certificate keys, browser profile, bootstrap tokens, and passkeys when the test exits.

The virtual authenticator performs browser WebAuthn create/get operations through `navigator.credentials`. It does not simulate Apple Passwords, iCloud Keychain synchronization, or a hardware Secure Enclave.
