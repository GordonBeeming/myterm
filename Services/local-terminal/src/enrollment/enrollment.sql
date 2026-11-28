CREATE TABLE account (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    anchor TEXT NOT NULL,
    head TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    last_clock INTEGER NOT NULL
) STRICT;

CREATE TABLE credentials (
    id TEXT PRIMARY KEY NOT NULL,
    holder TEXT UNIQUE NOT NULL,
    issue_sequence INTEGER NOT NULL,
    revoked INTEGER NOT NULL DEFAULT 0,
    allocated TEXT,
    rate_window INTEGER NOT NULL DEFAULT 0,
    rate_count INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE admissions (
    id TEXT PRIMARY KEY NOT NULL,
    request_digest TEXT NOT NULL,
    sequence INTEGER NOT NULL
) STRICT;

CREATE TABLE tombstones (
    id TEXT PRIMARY KEY NOT NULL
) STRICT;

CREATE TABLE events (
    sequence INTEGER PRIMARY KEY,
    receipt BLOB NOT NULL
) STRICT;

CREATE TABLE operations (
    actor TEXT NOT NULL,
    operation TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    result BLOB NOT NULL,
    PRIMARY KEY (actor, operation)
) STRICT;

PRAGMA user_version=1;
