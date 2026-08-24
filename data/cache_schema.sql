-- Rime Bilingual V0.2 cache schema.
-- The application id is the fixed four-byte magic "RBIL" (0x5242494C).
PRAGMA application_id = 1380075852;
PRAGMA user_version = 1;

CREATE TABLE IF NOT EXISTS translations (
    source_text TEXT NOT NULL COLLATE BINARY,
    source_language TEXT NOT NULL COLLATE BINARY,
    target_language TEXT NOT NULL COLLATE BINARY,
    translation_mode TEXT NOT NULL COLLATE BINARY,
    translated_text TEXT NOT NULL,
    source TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL,
    PRIMARY KEY (source_text, source_language, target_language, translation_mode)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS cache_meta (
    id INTEGER NOT NULL PRIMARY KEY CHECK (id = 1),
    revision INTEGER NOT NULL,
    updated_at_utc TEXT NOT NULL
);

INSERT OR IGNORE INTO cache_meta (id, revision, updated_at_utc)
VALUES (1, 0, '1970-01-01T00:00:00.000Z');
