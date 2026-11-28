CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY,
  role TEXT NOT NULL CHECK (role IN ('personal', 'operator')),
  user_handle TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS bootstrap_operator ON accounts(role) WHERE role = 'operator';

CREATE TABLE IF NOT EXISTS passkeys (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  public_key BLOB NOT NULL,
  counter INTEGER NOT NULL CHECK (counter >= 0)
) STRICT;

CREATE TABLE IF NOT EXISTS passkey_challenges (
  challenge TEXT PRIMARY KEY,
  purpose TEXT NOT NULL CHECK (purpose IN ('register', 'login', 'bootstrap')),
  user_handle TEXT,
  invitation_hash TEXT,
  expires_at INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS passkey_challenge_expiry ON passkey_challenges(expires_at);

CREATE TABLE IF NOT EXISTS login_sessions (
  token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS login_session_expiry ON login_sessions(expires_at);
CREATE INDEX IF NOT EXISTS login_session_account ON login_sessions(account_id);

CREATE TABLE IF NOT EXISTS registration_invitations (
  token_hash TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS registration_invitation_expiry ON registration_invitations(expires_at);
