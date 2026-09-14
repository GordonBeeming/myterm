PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY);
INSERT OR IGNORE INTO schema_migrations(version) VALUES(1);
CREATE TABLE IF NOT EXISTS enrollments(
 id TEXT PRIMARY KEY, challenge BLOB NOT NULL, expires_at INTEGER NOT NULL, attested_at INTEGER,
 key_id TEXT, app_attest_public_key BLOB, app_attest_receipt BLOB, app_attest_counter INTEGER,
 device_public_key BLOB, pending_apns_token TEXT, apns_challenge BLOB, activated_at INTEGER
);
CREATE TABLE IF NOT EXISTS devices(
 recipient_id TEXT PRIMARY KEY, key_id TEXT NOT NULL UNIQUE, app_attest_public_key BLOB NOT NULL,
 app_attest_receipt BLOB NOT NULL, app_attest_counter INTEGER NOT NULL, device_public_key BLOB NOT NULL,
 apns_token TEXT NOT NULL, session_hash BLOB NOT NULL UNIQUE, session_expires_at INTEGER NOT NULL,
 active INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS device_nonces(device_id TEXT NOT NULL REFERENCES devices(recipient_id) ON DELETE CASCADE, nonce_hash BLOB NOT NULL, expires_at INTEGER NOT NULL, PRIMARY KEY(device_id,nonce_hash));
CREATE TABLE IF NOT EXISTS grants(
 id TEXT PRIMARY KEY, recipient_id TEXT NOT NULL REFERENCES devices(recipient_id) ON DELETE CASCADE,
 relay_origin TEXT NOT NULL, host_id TEXT NOT NULL, host_public_key BLOB NOT NULL,
 token_hash BLOB NOT NULL UNIQUE, revoked_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS events(grant_id TEXT NOT NULL REFERENCES grants(id) ON DELETE CASCADE,event_id TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(grant_id,event_id));
CREATE TABLE IF NOT EXISTS apns_token_challenges(
 id TEXT PRIMARY KEY,recipient_id TEXT NOT NULL REFERENCES devices(recipient_id) ON DELETE CASCADE,
 pending_token TEXT NOT NULL,challenge BLOB NOT NULL,expires_at INTEGER NOT NULL,consumed_at INTEGER
);
