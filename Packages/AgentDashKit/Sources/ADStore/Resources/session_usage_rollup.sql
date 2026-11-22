-- Committed per-session quantities and quotes, including usage without a timestamp.
-- Only sessions with token events occupy a row; detached archive usage is not a session.
CREATE TABLE session_usage_rollup (
    session_id INTEGER PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
    input_fresh INTEGER NOT NULL,
    cache_read INTEGER NOT NULL,
    cache_write INTEGER NOT NULL,
    cache_write_1h INTEGER NOT NULL,
    output INTEGER NOT NULL,
    reasoning INTEGER NOT NULL,
    cost_micro_usd INTEGER NOT NULL,
    unpriced_tokens INTEGER NOT NULL,
    records INTEGER NOT NULL,
    approximate_records INTEGER NOT NULL
) STRICT;

INSERT INTO session_usage_rollup
SELECT session_id,sum(input_fresh),sum(cache_read),sum(cache_write),sum(cache_write_1h),
       sum(output),sum(reasoning),
       sum(CASE WHEN price_status<>'unpriced' THEN cost_micro_usd ELSE 0 END),
       sum(CASE WHEN price_status='unpriced' THEN input_fresh+cache_read+cache_write+cache_write_1h+output ELSE 0 END),
       count(*),sum(price_status='approx')
FROM token_events GROUP BY session_id;

-- Insertion and transfer admission share the same addition. Existing contributions
-- are changed in place; a quote-only correction does not remove and re-add a row.
CREATE VIEW session_usage_delta AS SELECT * FROM session_usage_rollup WHERE 0;
CREATE TRIGGER session_usage_delta_add INSTEAD OF INSERT ON session_usage_delta
WHEN NEW.records=1
BEGIN
    INSERT INTO session_usage_rollup VALUES (
        NEW.session_id,NEW.input_fresh,NEW.cache_read,NEW.cache_write,NEW.cache_write_1h,
        NEW.output,NEW.reasoning,NEW.cost_micro_usd,NEW.unpriced_tokens,NEW.records,NEW.approximate_records)
    ON CONFLICT(session_id) DO UPDATE SET
        input_fresh=input_fresh+excluded.input_fresh,
        cache_read=cache_read+excluded.cache_read,
        cache_write=cache_write+excluded.cache_write,
        cache_write_1h=cache_write_1h+excluded.cache_write_1h,
        output=output+excluded.output,
        reasoning=reasoning+excluded.reasoning,
        cost_micro_usd=cost_micro_usd+excluded.cost_micro_usd,
        unpriced_tokens=unpriced_tokens+excluded.unpriced_tokens,
        records=records+1,
        approximate_records=approximate_records+excluded.approximate_records;
END;
CREATE TRIGGER session_usage_delta_adjust INSTEAD OF INSERT ON session_usage_delta
WHEN NEW.records<=0
BEGIN
    UPDATE session_usage_rollup SET
        input_fresh=input_fresh+NEW.input_fresh,
        cache_read=cache_read+NEW.cache_read,
        cache_write=cache_write+NEW.cache_write,
        cache_write_1h=cache_write_1h+NEW.cache_write_1h,
        output=output+NEW.output,
        reasoning=reasoning+NEW.reasoning,
        cost_micro_usd=cost_micro_usd+NEW.cost_micro_usd,
        unpriced_tokens=unpriced_tokens+NEW.unpriced_tokens,
        records=records+NEW.records,
        approximate_records=approximate_records+NEW.approximate_records
    WHERE session_id=NEW.session_id;
    -- A cascading parent delete may already have removed the rollup row.
    DELETE FROM session_usage_rollup WHERE NEW.records<0 AND session_id=NEW.session_id AND records=0;
END;

CREATE TRIGGER session_usage_ai AFTER INSERT ON token_events BEGIN
    INSERT INTO session_usage_delta VALUES (
        NEW.session_id,NEW.input_fresh,NEW.cache_read,NEW.cache_write,NEW.cache_write_1h,NEW.output,NEW.reasoning,
        CASE WHEN NEW.price_status<>'unpriced' THEN NEW.cost_micro_usd ELSE 0 END,
        CASE WHEN NEW.price_status='unpriced'
            THEN NEW.input_fresh+NEW.cache_read+NEW.cache_write+NEW.cache_write_1h+NEW.output ELSE 0 END,
        1,NEW.price_status='approx');
END;
CREATE TRIGGER session_usage_ad AFTER DELETE ON token_events BEGIN
    INSERT INTO session_usage_delta VALUES (
        OLD.session_id,-OLD.input_fresh,-OLD.cache_read,-OLD.cache_write,-OLD.cache_write_1h,-OLD.output,-OLD.reasoning,
        CASE WHEN OLD.price_status<>'unpriced' THEN -OLD.cost_micro_usd ELSE 0 END,
        CASE WHEN OLD.price_status='unpriced'
            THEN -(OLD.input_fresh+OLD.cache_read+OLD.cache_write+OLD.cache_write_1h+OLD.output) ELSE 0 END,
        -1,-(OLD.price_status='approx'));
END;
CREATE TRIGGER session_usage_au AFTER UPDATE OF session_id,input_fresh,cache_read,cache_write,cache_write_1h,
                                              output,reasoning ON token_events
WHEN OLD.session_id<>NEW.session_id OR OLD.input_fresh<>NEW.input_fresh OR OLD.cache_read<>NEW.cache_read
  OR OLD.cache_write<>NEW.cache_write OR OLD.cache_write_1h<>NEW.cache_write_1h OR OLD.output<>NEW.output
  OR OLD.reasoning<>NEW.reasoning
BEGIN
    INSERT INTO session_usage_delta SELECT OLD.session_id,
        CASE WHEN OLD.session_id=NEW.session_id THEN NEW.input_fresh ELSE 0 END - OLD.input_fresh,
        CASE WHEN OLD.session_id=NEW.session_id THEN NEW.cache_read ELSE 0 END - OLD.cache_read,
        CASE WHEN OLD.session_id=NEW.session_id THEN NEW.cache_write ELSE 0 END - OLD.cache_write,
        CASE WHEN OLD.session_id=NEW.session_id THEN NEW.cache_write_1h ELSE 0 END - OLD.cache_write_1h,
        CASE WHEN OLD.session_id=NEW.session_id THEN NEW.output ELSE 0 END - OLD.output,
        CASE WHEN OLD.session_id=NEW.session_id THEN NEW.reasoning ELSE 0 END - OLD.reasoning,
        CASE WHEN OLD.session_id=NEW.session_id AND NEW.price_status<>'unpriced' THEN NEW.cost_micro_usd ELSE 0 END
            - CASE WHEN OLD.price_status<>'unpriced' THEN OLD.cost_micro_usd ELSE 0 END,
        CASE WHEN OLD.session_id=NEW.session_id AND NEW.price_status='unpriced'
            THEN NEW.input_fresh+NEW.cache_read+NEW.cache_write+NEW.cache_write_1h+NEW.output ELSE 0 END
            - CASE WHEN OLD.price_status='unpriced'
                THEN OLD.input_fresh+OLD.cache_read+OLD.cache_write+OLD.cache_write_1h+OLD.output ELSE 0 END,
        -(OLD.session_id<>NEW.session_id),
        (OLD.session_id=NEW.session_id AND NEW.price_status='approx')-(OLD.price_status='approx');
    INSERT INTO session_usage_delta SELECT NEW.session_id,NEW.input_fresh,NEW.cache_read,NEW.cache_write,
        NEW.cache_write_1h,NEW.output,NEW.reasoning,
        CASE WHEN NEW.price_status<>'unpriced' THEN NEW.cost_micro_usd ELSE 0 END,
        CASE WHEN NEW.price_status='unpriced'
            THEN NEW.input_fresh+NEW.cache_read+NEW.cache_write+NEW.cache_write_1h+NEW.output ELSE 0 END,
        1,NEW.price_status='approx'
    WHERE OLD.session_id<>NEW.session_id;
END;

-- Foreground price corrections update just pricing fields. Backfills already
-- aggregate the same deltas by session inside the writer's quote batch gate.
CREATE TRIGGER session_usage_quote_au AFTER UPDATE OF cost_micro_usd,price_status ON token_events
WHEN NOT EXISTS (SELECT 1 FROM quote_batch_gate)
  AND (OLD.cost_micro_usd<>NEW.cost_micro_usd OR OLD.price_status<>NEW.price_status)
  AND OLD.session_id=NEW.session_id AND OLD.input_fresh=NEW.input_fresh AND OLD.cache_read=NEW.cache_read
  AND OLD.cache_write=NEW.cache_write AND OLD.cache_write_1h=NEW.cache_write_1h
  AND OLD.output=NEW.output AND OLD.reasoning=NEW.reasoning
BEGIN
    UPDATE session_usage_rollup SET
        cost_micro_usd=cost_micro_usd
            + (CASE WHEN NEW.price_status<>'unpriced' THEN NEW.cost_micro_usd ELSE 0 END
               - CASE WHEN OLD.price_status<>'unpriced' THEN OLD.cost_micro_usd ELSE 0 END),
        unpriced_tokens=unpriced_tokens + ((NEW.price_status='unpriced')-(OLD.price_status='unpriced'))
            * (NEW.input_fresh+NEW.cache_read+NEW.cache_write+NEW.cache_write_1h+NEW.output),
        approximate_records=approximate_records + (NEW.price_status='approx') - (OLD.price_status='approx')
    WHERE session_id=NEW.session_id;
END;
