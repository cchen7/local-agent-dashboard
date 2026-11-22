-- v1's placeholder grain conflated precision. Keep its rows rather than
-- destroying any older app-owned data; this version is built from events.
ALTER TABLE token_minute RENAME TO token_minute_legacy;
UPDATE token_events SET project_id=(SELECT project_id FROM sessions s WHERE s.id=token_events.session_id);

CREATE TABLE token_minute (
    bucket INTEGER NOT NULL,
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
    PRIMARY KEY (bucket, agent, project_id, model, precision)
) WITHOUT ROWID;

CREATE INDEX token_events_usage_scope ON token_events(ts, agent, project_id, model, session_id);

-- Raw events stay authoritative. SQLite integer division needs an explicit
-- correction for timestamps before the Unix epoch.
INSERT INTO token_minute
SELECT ts/60000-(ts%60000<0),agent,coalesce(project_id,0),coalesce(model,''),precision,
       sum(input_fresh),sum(cache_read),sum(cache_write),sum(cache_write_1h),sum(output),sum(reasoning),sum(cost_micro_usd),
       sum(CASE WHEN price_status='unpriced' THEN input_fresh+cache_read+cache_write+cache_write_1h+output ELSE 0 END),count(*)
FROM token_events GROUP BY 1,2,3,4,5;

-- The internal view centralizes positive/negative deltas. It stores no rows.
CREATE VIEW token_minute_delta AS SELECT * FROM token_minute WHERE 0;
CREATE TRIGGER token_minute_delta_apply INSTEAD OF INSERT ON token_minute_delta BEGIN
    INSERT INTO token_minute VALUES (
        NEW.bucket,NEW.agent,NEW.project_id,NEW.model,NEW.precision,
        NEW.input_fresh,NEW.cache_read,NEW.cache_write,NEW.cache_write_1h,NEW.output,NEW.reasoning,
        NEW.cost_micro_usd,NEW.unpriced_tokens,NEW.records
    ) ON CONFLICT(bucket,agent,project_id,model,precision) DO UPDATE SET
        input_fresh=token_minute.input_fresh+excluded.input_fresh,
        cache_read=token_minute.cache_read+excluded.cache_read,
        cache_write=token_minute.cache_write+excluded.cache_write,
        cache_write_1h=token_minute.cache_write_1h+excluded.cache_write_1h,
        output=token_minute.output+excluded.output,
        reasoning=token_minute.reasoning+excluded.reasoning,
        cost_micro_usd=token_minute.cost_micro_usd+excluded.cost_micro_usd,
        unpriced_tokens=token_minute.unpriced_tokens+excluded.unpriced_tokens,
        records=token_minute.records+excluded.records;
    DELETE FROM token_minute WHERE bucket=NEW.bucket AND agent=NEW.agent AND project_id=NEW.project_id
        AND model=NEW.model AND precision=NEW.precision AND records=0;
END;

CREATE TRIGGER token_events_minute_ai AFTER INSERT ON token_events BEGIN
    INSERT INTO token_minute_delta VALUES (
        NEW.ts/60000-(NEW.ts%60000<0),NEW.agent,coalesce(NEW.project_id,0),coalesce(NEW.model,''),NEW.precision,
        NEW.input_fresh,NEW.cache_read,NEW.cache_write,NEW.cache_write_1h,NEW.output,NEW.reasoning,NEW.cost_micro_usd,
        CASE WHEN NEW.price_status='unpriced' THEN NEW.input_fresh+NEW.cache_read+NEW.cache_write+NEW.cache_write_1h+NEW.output ELSE 0 END,1);
END;

CREATE TRIGGER token_events_minute_ad AFTER DELETE ON token_events BEGIN
    INSERT INTO token_minute_delta VALUES (
        OLD.ts/60000-(OLD.ts%60000<0),OLD.agent,coalesce(OLD.project_id,0),coalesce(OLD.model,''),OLD.precision,
        -OLD.input_fresh,-OLD.cache_read,-OLD.cache_write,-OLD.cache_write_1h,-OLD.output,-OLD.reasoning,-OLD.cost_micro_usd,
        CASE WHEN OLD.price_status='unpriced' THEN -(OLD.input_fresh+OLD.cache_read+OLD.cache_write+OLD.cache_write_1h+OLD.output) ELSE 0 END,-1);
END;

CREATE TRIGGER token_events_minute_au AFTER UPDATE ON token_events
WHEN OLD.ts IS NOT NEW.ts OR OLD.agent IS NOT NEW.agent OR OLD.project_id IS NOT NEW.project_id OR OLD.model IS NOT NEW.model
  OR OLD.precision IS NOT NEW.precision OR OLD.input_fresh IS NOT NEW.input_fresh OR OLD.cache_read IS NOT NEW.cache_read
  OR OLD.cache_write IS NOT NEW.cache_write OR OLD.cache_write_1h IS NOT NEW.cache_write_1h OR OLD.output IS NOT NEW.output
  OR OLD.reasoning IS NOT NEW.reasoning OR OLD.cost_micro_usd IS NOT NEW.cost_micro_usd OR OLD.price_status IS NOT NEW.price_status
BEGIN
    INSERT INTO token_minute_delta VALUES (
        OLD.ts/60000-(OLD.ts%60000<0),OLD.agent,coalesce(OLD.project_id,0),coalesce(OLD.model,''),OLD.precision,
        -OLD.input_fresh,-OLD.cache_read,-OLD.cache_write,-OLD.cache_write_1h,-OLD.output,-OLD.reasoning,-OLD.cost_micro_usd,
        CASE WHEN OLD.price_status='unpriced' THEN -(OLD.input_fresh+OLD.cache_read+OLD.cache_write+OLD.cache_write_1h+OLD.output) ELSE 0 END,-1);
    INSERT INTO token_minute_delta VALUES (
        NEW.ts/60000-(NEW.ts%60000<0),NEW.agent,coalesce(NEW.project_id,0),coalesce(NEW.model,''),NEW.precision,
        NEW.input_fresh,NEW.cache_read,NEW.cache_write,NEW.cache_write_1h,NEW.output,NEW.reasoning,NEW.cost_micro_usd,
        CASE WHEN NEW.price_status='unpriced' THEN NEW.input_fresh+NEW.cache_read+NEW.cache_write+NEW.cache_write_1h+NEW.output ELSE 0 END,1);
END;

-- Project grouping can arrive after parsing. Assign both new events and old
-- events in the same writer transaction as the corresponding rollup changes.
CREATE TRIGGER sessions_usage_project AFTER UPDATE OF project_id ON sessions
WHEN OLD.project_id IS NOT NEW.project_id BEGIN
    UPDATE token_events SET project_id=NEW.project_id WHERE session_id=NEW.id;
END;
