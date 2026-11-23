ALTER TABLE token_events ADD COLUMN cache_savings_micro_usd INTEGER;

-- Only existing events with locked quote bases can be enriched. Keep the
-- migration bounded to capturing a horizon; pricing runs off the UI path.
INSERT INTO app_meta(key,value)
SELECT 'cache_savings_legacy_through',CAST(max(id) AS TEXT) FROM token_events
WHERE rate_basis_id IS NOT NULL AND price_status<>'unpriced' AND cache_read>0
HAVING max(id) IS NOT NULL;

CREATE TABLE cache_savings_hour (
    bucket INTEGER NOT NULL,
    agent TEXT NOT NULL,
    project_id INTEGER NOT NULL,
    savings_micro_usd INTEGER NOT NULL,
    measured_cache_read INTEGER NOT NULL,
    PRIMARY KEY (bucket,agent,project_id)
) WITHOUT ROWID;

-- This gate exists only inside an unpriced-backfill writer transaction.
-- Its caller applies the exact same cost and savings deltas in groups.
CREATE TABLE quote_batch_gate (id INTEGER PRIMARY KEY CHECK(id=1));

DROP TRIGGER token_events_quote_au;
CREATE TRIGGER token_events_quote_au AFTER UPDATE OF cost_micro_usd,price_status ON token_events
WHEN (OLD.cost_micro_usd IS NOT NEW.cost_micro_usd OR OLD.price_status IS NOT NEW.price_status)
  AND OLD.ts IS NEW.ts AND OLD.agent IS NEW.agent AND OLD.project_id IS NEW.project_id AND OLD.model IS NEW.model
  AND OLD.precision IS NEW.precision AND OLD.input_fresh IS NEW.input_fresh AND OLD.cache_read IS NEW.cache_read
  AND OLD.cache_write IS NEW.cache_write AND OLD.cache_write_1h IS NEW.cache_write_1h
  AND OLD.output IS NEW.output AND OLD.reasoning IS NEW.reasoning
  AND NOT EXISTS(SELECT 1 FROM quote_batch_gate)
BEGIN
    INSERT INTO token_quote_delta VALUES (
        NEW.ts/60000-(NEW.ts%60000<0),NEW.agent,coalesce(NEW.project_id,0),coalesce(NEW.model,''),NEW.precision,
        NEW.cost_micro_usd-OLD.cost_micro_usd,
        ((NEW.price_status='unpriced')-(OLD.price_status='unpriced')) *
            (NEW.input_fresh+NEW.cache_read+NEW.cache_write+NEW.cache_write_1h+NEW.output));
END;

CREATE VIEW cache_savings_delta AS SELECT * FROM cache_savings_hour WHERE 0;
CREATE TRIGGER cache_savings_delta_apply INSTEAD OF INSERT ON cache_savings_delta BEGIN
    INSERT INTO cache_savings_hour VALUES(NEW.bucket,NEW.agent,NEW.project_id,NEW.savings_micro_usd,NEW.measured_cache_read)
    ON CONFLICT(bucket,agent,project_id) DO UPDATE SET
        savings_micro_usd=cache_savings_hour.savings_micro_usd+excluded.savings_micro_usd,
        measured_cache_read=cache_savings_hour.measured_cache_read+excluded.measured_cache_read;
    DELETE FROM cache_savings_hour WHERE bucket=NEW.bucket AND agent=NEW.agent AND project_id=NEW.project_id
        AND NEW.measured_cache_read<0 AND measured_cache_read=0;
END;

CREATE TRIGGER token_cache_savings_ai AFTER INSERT ON token_events
WHEN NEW.cache_savings_micro_usd IS NOT NULL AND NEW.cache_read>0 BEGIN
    INSERT INTO cache_savings_delta VALUES(NEW.ts/3600000-(NEW.ts%3600000<0),NEW.agent,coalesce(NEW.project_id,0),
        NEW.cache_savings_micro_usd,NEW.cache_read);
END;

CREATE TRIGGER token_cache_savings_ad AFTER DELETE ON token_events
WHEN OLD.cache_savings_micro_usd IS NOT NULL AND OLD.cache_read>0 BEGIN
    INSERT INTO cache_savings_delta VALUES(OLD.ts/3600000-(OLD.ts%3600000<0),OLD.agent,coalesce(OLD.project_id,0),
        -OLD.cache_savings_micro_usd,-OLD.cache_read);
END;

CREATE TRIGGER token_cache_savings_au AFTER UPDATE OF ts,agent,project_id,cache_read,cache_savings_micro_usd ON token_events
WHEN (OLD.cache_savings_micro_usd IS NOT NULL OR NEW.cache_savings_micro_usd IS NOT NULL)
 AND (OLD.cache_savings_micro_usd IS NOT NEW.cache_savings_micro_usd OR OLD.cache_read IS NOT NEW.cache_read
      OR OLD.ts IS NOT NEW.ts OR OLD.agent IS NOT NEW.agent OR OLD.project_id IS NOT NEW.project_id)
 AND NOT EXISTS(SELECT 1 FROM quote_batch_gate)
BEGIN
    INSERT INTO cache_savings_delta
    SELECT OLD.ts/3600000-(OLD.ts%3600000<0),OLD.agent,coalesce(OLD.project_id,0),
           -OLD.cache_savings_micro_usd,-OLD.cache_read
    WHERE OLD.cache_savings_micro_usd IS NOT NULL AND OLD.cache_read>0;
    INSERT INTO cache_savings_delta
    SELECT NEW.ts/3600000-(NEW.ts%3600000<0),NEW.agent,coalesce(NEW.project_id,0),
           NEW.cache_savings_micro_usd,NEW.cache_read
    WHERE NEW.cache_savings_micro_usd IS NOT NULL AND NEW.cache_read>0;
END;
