CREATE TABLE usage_chart_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    revision INTEGER NOT NULL,
    pending_low INTEGER,
    pending_high INTEGER
);
INSERT INTO usage_chart_state VALUES(1,0,NULL,NULL);

CREATE TABLE usage_chart_changes (
    revision INTEGER PRIMARY KEY,
    low_ts INTEGER NOT NULL,
    high_ts INTEGER NOT NULL
);

CREATE VIEW usage_chart_dirty AS
SELECT pending_low AS low_ts,pending_high AS high_ts FROM usage_chart_state WHERE 0;
CREATE TRIGGER usage_chart_dirty_append INSTEAD OF INSERT ON usage_chart_dirty BEGIN
    UPDATE usage_chart_state
    SET pending_low=min(coalesce(pending_low,NEW.low_ts),NEW.low_ts),
        pending_high=max(coalesce(pending_high,NEW.high_ts),NEW.high_ts)
    WHERE singleton=1;
END;

CREATE TRIGGER usage_chart_token_ai AFTER INSERT ON token_events BEGIN
    INSERT INTO usage_chart_dirty VALUES(NEW.ts,NEW.ts);
END;
CREATE TRIGGER usage_chart_token_ad AFTER DELETE ON token_events BEGIN
    INSERT INTO usage_chart_dirty VALUES(OLD.ts,OLD.ts);
END;
CREATE TRIGGER usage_chart_token_au AFTER UPDATE OF ts,agent,project_id,precision,input_fresh,cache_read,cache_write,
    cache_write_1h,output,reasoning,cost_micro_usd,price_status ON token_events
WHEN (OLD.ts IS NOT NEW.ts OR OLD.agent IS NOT NEW.agent OR OLD.project_id IS NOT NEW.project_id
   OR OLD.precision IS NOT NEW.precision OR OLD.input_fresh IS NOT NEW.input_fresh OR OLD.cache_read IS NOT NEW.cache_read
   OR OLD.cache_write IS NOT NEW.cache_write OR OLD.cache_write_1h IS NOT NEW.cache_write_1h
   OR OLD.output IS NOT NEW.output OR OLD.reasoning IS NOT NEW.reasoning
   OR OLD.cost_micro_usd IS NOT NEW.cost_micro_usd OR OLD.price_status IS NOT NEW.price_status)
 AND NOT EXISTS(SELECT 1 FROM quote_batch_gate)
BEGIN
    INSERT INTO usage_chart_dirty VALUES(min(OLD.ts,NEW.ts),max(OLD.ts,NEW.ts));
END;
