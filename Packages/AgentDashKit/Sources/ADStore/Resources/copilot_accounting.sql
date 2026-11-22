ALTER TABLE token_events ADD COLUMN source_seq INTEGER;
CREATE INDEX token_events_session_model ON token_events(session_id, model, precision, source_seq);

CREATE TABLE copilot_usage_snapshots (
    dedupe_key TEXT NOT NULL PRIMARY KEY,
    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    model TEXT NOT NULL,
    seq INTEGER NOT NULL,
    ts INTEGER NOT NULL,
    input_fresh INTEGER NOT NULL,
    cache_read INTEGER NOT NULL,
    cache_write INTEGER NOT NULL,
    output INTEGER NOT NULL,
    reasoning INTEGER NOT NULL
);
CREATE INDEX copilot_snapshots_session_model ON copilot_usage_snapshots(session_id, model, seq);
