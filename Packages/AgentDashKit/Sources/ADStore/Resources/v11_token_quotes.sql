CREATE TABLE token_rate_bases (
    id INTEGER PRIMARY KEY,
    reference TEXT NOT NULL,
    bytes BLOB NOT NULL,
    UNIQUE(reference, bytes)
);

ALTER TABLE token_events ADD COLUMN rate_basis_id INTEGER REFERENCES token_rate_bases(id);

CREATE INDEX token_events_unpriced_with_model ON token_events(id)
    WHERE price_status='unpriced' AND model IS NOT NULL;

-- Quantity or attribution corrections still replace the complete old usage
-- contribution. Quote-only changes leave counts, peaks and routing in place.
DROP TRIGGER token_events_minute_au;
CREATE TRIGGER token_events_minute_au AFTER UPDATE ON token_events
WHEN OLD.ts IS NOT NEW.ts OR OLD.agent IS NOT NEW.agent OR OLD.project_id IS NOT NEW.project_id OR OLD.model IS NOT NEW.model
  OR OLD.precision IS NOT NEW.precision OR OLD.input_fresh IS NOT NEW.input_fresh OR OLD.cache_read IS NOT NEW.cache_read
  OR OLD.cache_write IS NOT NEW.cache_write OR OLD.cache_write_1h IS NOT NEW.cache_write_1h
  OR OLD.output IS NOT NEW.output OR OLD.reasoning IS NOT NEW.reasoning
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

CREATE VIEW token_quote_delta AS
SELECT bucket,agent,project_id,model,precision,cost_micro_usd,unpriced_tokens FROM token_minute WHERE 0;
CREATE TRIGGER token_quote_delta_apply INSTEAD OF INSERT ON token_quote_delta BEGIN
    UPDATE token_minute SET cost_micro_usd=cost_micro_usd+NEW.cost_micro_usd,
        unpriced_tokens=unpriced_tokens+NEW.unpriced_tokens
    WHERE bucket=NEW.bucket AND agent=NEW.agent AND project_id=NEW.project_id
      AND model=NEW.model AND precision=NEW.precision;
    UPDATE token_usage_scope SET cost_micro_usd=cost_micro_usd+NEW.cost_micro_usd,
        unpriced_tokens=unpriced_tokens+NEW.unpriced_tokens
    WHERE grain=1 AND bucket=NEW.bucket AND agent IN (NEW.agent,'') AND precision=NEW.precision;
    UPDATE token_usage_scope SET cost_micro_usd=cost_micro_usd+NEW.cost_micro_usd,
        unpriced_tokens=unpriced_tokens+NEW.unpriced_tokens
    WHERE grain=60 AND bucket=NEW.bucket/60-(NEW.bucket%60<0) AND agent=NEW.agent AND precision=NEW.precision;
END;

CREATE TRIGGER token_events_quote_au AFTER UPDATE OF cost_micro_usd,price_status ON token_events
WHEN (OLD.cost_micro_usd IS NOT NEW.cost_micro_usd OR OLD.price_status IS NOT NEW.price_status)
  AND OLD.ts IS NEW.ts AND OLD.agent IS NEW.agent AND OLD.project_id IS NEW.project_id AND OLD.model IS NEW.model
  AND OLD.precision IS NEW.precision AND OLD.input_fresh IS NEW.input_fresh AND OLD.cache_read IS NEW.cache_read
  AND OLD.cache_write IS NEW.cache_write AND OLD.cache_write_1h IS NEW.cache_write_1h
  AND OLD.output IS NEW.output AND OLD.reasoning IS NEW.reasoning
BEGIN
    INSERT INTO token_quote_delta VALUES (
        NEW.ts/60000-(NEW.ts%60000<0),NEW.agent,coalesce(NEW.project_id,0),coalesce(NEW.model,''),NEW.precision,
        NEW.cost_micro_usd-OLD.cost_micro_usd,
        ((NEW.price_status='unpriced')-(OLD.price_status='unpriced')) *
            (NEW.input_fresh+NEW.cache_read+NEW.cache_write+NEW.cache_write_1h+NEW.output));
END;
