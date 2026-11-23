-- Keep fingerprints, never a second copy of an excluded session ID or path.
CREATE TABLE session_exclusion_keys (
    digest BLOB PRIMARY KEY NOT NULL,
    revision INTEGER NOT NULL,
    disposition INTEGER NOT NULL CHECK(disposition IN (0,1,2))
) WITHOUT ROWID;

CREATE TABLE session_exclusion_inputs (
    file_id INTEGER NOT NULL REFERENCES source_files(id) ON DELETE CASCADE,
    digest BLOB NOT NULL,
    replay_on_admission INTEGER NOT NULL CHECK(replay_on_admission IN (0,1)),
    PRIMARY KEY(file_id,digest)
) WITHOUT ROWID;
CREATE INDEX session_exclusion_inputs_key ON session_exclusion_inputs(digest,replay_on_admission);
