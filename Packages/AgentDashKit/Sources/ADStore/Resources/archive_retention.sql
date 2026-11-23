-- Numeric history detached from expired transcripts. Keep source/workspace
-- attribution for later scoped clears and exclusions; never keep raw record IDs.
CREATE TABLE retained_archive_scopes (
    id INTEGER PRIMARY KEY,
    source_id INTEGER NOT NULL REFERENCES sources(id),
    project_key BLOB NOT NULL,
    label TEXT,
    location TEXT,
    workspace TEXT NOT NULL,
    UNIQUE(source_id,project_key,workspace)
);
CREATE INDEX retained_archive_scopes_project ON retained_archive_scopes(project_key);

CREATE TABLE expired_archive_sessions (
    digest BLOB PRIMARY KEY NOT NULL,
    scope_id INTEGER NOT NULL REFERENCES retained_archive_scopes(id) ON DELETE CASCADE
) WITHOUT ROWID;
CREATE INDEX expired_archive_sessions_scope ON expired_archive_sessions(scope_id);

CREATE TABLE expired_archive_tokens (
    digest BLOB PRIMARY KEY NOT NULL,
    scope_id INTEGER NOT NULL REFERENCES retained_archive_scopes(id) ON DELETE CASCADE
) WITHOUT ROWID;
CREATE INDEX expired_archive_tokens_scope ON expired_archive_tokens(scope_id);

-- Group at equal timestamps across each attribution, to keep partial-minute
-- reads exact. These sums have no session ID, quote basis or token event key.
CREATE TABLE retained_archive_usage (
    id INTEGER PRIMARY KEY,
    scope_id INTEGER NOT NULL REFERENCES retained_archive_scopes(id) ON DELETE CASCADE,
    ts INTEGER NOT NULL,
    agent TEXT NOT NULL,
    project_id INTEGER NOT NULL,
    model TEXT NOT NULL,
    precision TEXT NOT NULL,
    input_fresh INTEGER NOT NULL,
    cache_read INTEGER NOT NULL,
    cache_write INTEGER NOT NULL,
    cache_write_1h INTEGER NOT NULL,
    output INTEGER NOT NULL,
    reasoning INTEGER NOT NULL,
    cost_micro_usd INTEGER NOT NULL,
    unpriced_tokens INTEGER NOT NULL,
    records INTEGER NOT NULL,
    savings_micro_usd INTEGER NOT NULL,
    measured_cache_read INTEGER NOT NULL
);
CREATE INDEX retained_archive_usage_scope ON retained_archive_usage(scope_id);
CREATE INDEX retained_archive_usage_time ON retained_archive_usage(ts,agent,project_id);
CREATE INDEX retained_archive_usage_project ON retained_archive_usage(project_id);

CREATE TRIGGER retained_archive_usage_ai AFTER INSERT ON retained_archive_usage BEGIN
    INSERT INTO token_minute_delta VALUES (
        NEW.ts/60000-(NEW.ts%60000<0),NEW.agent,NEW.project_id,NEW.model,NEW.precision,
        NEW.input_fresh,NEW.cache_read,NEW.cache_write,NEW.cache_write_1h,NEW.output,
        NEW.reasoning,NEW.cost_micro_usd,NEW.unpriced_tokens,NEW.records);
    INSERT INTO cache_savings_delta
    SELECT NEW.ts/3600000-(NEW.ts%3600000<0),NEW.agent,NEW.project_id,NEW.savings_micro_usd,NEW.measured_cache_read
    WHERE NEW.measured_cache_read>0;
    INSERT INTO usage_chart_dirty VALUES(NEW.ts,NEW.ts);
END;

CREATE TRIGGER retained_archive_usage_ad AFTER DELETE ON retained_archive_usage BEGIN
    INSERT INTO token_minute_delta VALUES (
        OLD.ts/60000-(OLD.ts%60000<0),OLD.agent,OLD.project_id,OLD.model,OLD.precision,
        -OLD.input_fresh,-OLD.cache_read,-OLD.cache_write,-OLD.cache_write_1h,-OLD.output,
        -OLD.reasoning,-OLD.cost_micro_usd,-OLD.unpriced_tokens,-OLD.records);
    INSERT INTO cache_savings_delta
    SELECT OLD.ts/3600000-(OLD.ts%3600000<0),OLD.agent,OLD.project_id,-OLD.savings_micro_usd,-OLD.measured_cache_read
    WHERE OLD.measured_cache_read>0;
    INSERT INTO usage_chart_dirty VALUES(OLD.ts,OLD.ts);
END;
