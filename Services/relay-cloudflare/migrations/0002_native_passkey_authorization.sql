ALTER TABLE passkey_challenges ADD COLUMN code_challenge TEXT;
ALTER TABLE passkey_challenges ADD COLUMN redirect_uri TEXT;

CREATE TABLE passkey_authorization_codes (
  code_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  code_challenge TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  expires_at INTEGER NOT NULL
) STRICT;

CREATE INDEX passkey_authorization_code_expiry ON passkey_authorization_codes(expires_at);
