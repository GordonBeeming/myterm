PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY
);

INSERT OR IGNORE INTO schema_migrations(version) VALUES (1);

CREATE TABLE IF NOT EXISTS owners (
    id TEXT PRIMARY KEY,
    webauthn_id BLOB NOT NULL UNIQUE,
    name TEXT NOT NULL,
    display_name TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS credentials (
    credential_id BLOB PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
    credential_json BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS bootstrap_tokens (
    token_hash BLOB PRIMARY KEY,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
);

CREATE TABLE IF NOT EXISTS ceremonies (
    id_hash BLOB PRIMARY KEY,
    kind TEXT NOT NULL CHECK(kind IN ('register', 'login')),
    session_json BLOB NOT NULL,
    oauth_json BLOB NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS auth_codes (
    code_hash BLOB PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
    redirect_uri TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    device_name TEXT NOT NULL,
    device_kind TEXT NOT NULL CHECK(device_kind IN ('host', 'client')),
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
);

CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('host', 'client')),
    name TEXT NOT NULL,
    refresh_hash BLOB NOT NULL UNIQUE,
    refresh_expires_at INTEGER NOT NULL,
    revoked_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS access_tokens (
    token_hash BLOB PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS hosts (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    public_key BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(owner_id, device_id)
);

CREATE TABLE IF NOT EXISTS pairing_tickets (
    ticket_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
    host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    encrypted_envelope BLOB NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_access_tokens_device ON access_tokens(device_id);
CREATE INDEX IF NOT EXISTS idx_hosts_owner ON hosts(owner_id);
CREATE INDEX IF NOT EXISTS idx_pairing_tickets_expiry ON pairing_tickets(expires_at);

CREATE TABLE IF NOT EXISTS owner_enrollment_tokens (
    token_hash BLOB PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
    purpose TEXT NOT NULL CHECK(purpose IN ('add', 'recover')),
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
);

-- consumed_at separates a client retrying for a reply it never received from a token being replayed
-- much later, which is the difference between answering and revoking the device.
--
-- The replay_* columns hold the answer that rotation produced, so a retry inside the window is told
-- the same thing again instead of being rotated a second time. They are the only place this relay
-- keeps a usable token rather than a hash, so they are cleared as soon as the window closes and the
-- read path refuses them on time regardless.
--
-- Databases created before these exist get the columns from ensureColumn at startup.
CREATE TABLE IF NOT EXISTS used_refresh_tokens (
    token_hash BLOB PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER,
    replay_access TEXT,
    replay_refresh TEXT,
    replay_access_expires_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_used_refresh_expiry ON used_refresh_tokens(expires_at);

CREATE TABLE IF NOT EXISTS used_auth_codes (
    code_hash BLOB PRIMARY KEY,
    device_id TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_used_auth_code_expiry ON used_auth_codes(expires_at);

CREATE TABLE IF NOT EXISTS revoked_device_ids (
    device_id TEXT PRIMARY KEY,
    expires_at INTEGER NOT NULL
);
