-- A small projection for the default all-projects/agent usage view. Minute
-- slots support exact peaks; hour slots compose longer chart buckets.
CREATE TABLE token_usage_scope (
    grain INTEGER NOT NULL,
    bucket INTEGER NOT NULL,
    agent TEXT NOT NULL,
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
    volume INTEGER GENERATED ALWAYS AS (input_fresh+cache_read+cache_write+cache_write_1h+output) VIRTUAL,
    PRIMARY KEY (grain,bucket,agent,precision)
) WITHOUT ROWID;

INSERT INTO token_usage_scope(grain,bucket,agent,precision,input_fresh,cache_read,cache_write,cache_write_1h,output,reasoning,cost_micro_usd,unpriced_tokens,records)
SELECT 1,bucket,agent,precision,sum(input_fresh),sum(cache_read),sum(cache_write),sum(cache_write_1h),sum(output),sum(reasoning),
       sum(cost_micro_usd),sum(unpriced_tokens),sum(records) FROM token_minute GROUP BY bucket,agent,precision
UNION ALL
SELECT 1,bucket,'',precision,sum(input_fresh),sum(cache_read),sum(cache_write),sum(cache_write_1h),sum(output),sum(reasoning),
       sum(cost_micro_usd),sum(unpriced_tokens),sum(records) FROM token_minute GROUP BY bucket,precision
UNION ALL
SELECT 60,bucket/60-(bucket%60<0),agent,precision,sum(input_fresh),sum(cache_read),sum(cache_write),sum(cache_write_1h),sum(output),sum(reasoning),
       sum(cost_micro_usd),sum(unpriced_tokens),sum(records) FROM token_minute GROUP BY 2,agent,precision;

CREATE INDEX token_usage_scope_peak_tokens ON token_usage_scope(agent,volume DESC,bucket) WHERE grain=1 AND precision='call';
CREATE INDEX token_usage_scope_peak_output ON token_usage_scope(agent,output DESC,bucket) WHERE grain=1 AND precision='call';
CREATE INDEX token_events_session_time ON token_events(session_id,ts);

CREATE TRIGGER token_minute_delta_readouts INSTEAD OF INSERT ON token_minute_delta BEGIN
    INSERT INTO token_usage_scope(grain,bucket,agent,precision,input_fresh,cache_read,cache_write,cache_write_1h,output,reasoning,cost_micro_usd,unpriced_tokens,records)
    VALUES
        (1,NEW.bucket,NEW.agent,NEW.precision,NEW.input_fresh,NEW.cache_read,NEW.cache_write,NEW.cache_write_1h,
         NEW.output,NEW.reasoning,NEW.cost_micro_usd,NEW.unpriced_tokens,NEW.records),
        (1,NEW.bucket,'',NEW.precision,NEW.input_fresh,NEW.cache_read,NEW.cache_write,NEW.cache_write_1h,
         NEW.output,NEW.reasoning,NEW.cost_micro_usd,NEW.unpriced_tokens,NEW.records),
        (60,NEW.bucket/60-(NEW.bucket%60<0),NEW.agent,NEW.precision,NEW.input_fresh,NEW.cache_read,NEW.cache_write,NEW.cache_write_1h,
         NEW.output,NEW.reasoning,NEW.cost_micro_usd,NEW.unpriced_tokens,NEW.records)
    ON CONFLICT(grain,bucket,agent,precision) DO UPDATE SET
        input_fresh=token_usage_scope.input_fresh+excluded.input_fresh,
        cache_read=token_usage_scope.cache_read+excluded.cache_read,
        cache_write=token_usage_scope.cache_write+excluded.cache_write,
        cache_write_1h=token_usage_scope.cache_write_1h+excluded.cache_write_1h,
        output=token_usage_scope.output+excluded.output,
        reasoning=token_usage_scope.reasoning+excluded.reasoning,
        cost_micro_usd=token_usage_scope.cost_micro_usd+excluded.cost_micro_usd,
        unpriced_tokens=token_usage_scope.unpriced_tokens+excluded.unpriced_tokens,
        records=token_usage_scope.records+excluded.records;
    DELETE FROM token_usage_scope WHERE grain=1 AND bucket=NEW.bucket AND agent IN (NEW.agent,'') AND precision=NEW.precision AND records=0;
    DELETE FROM token_usage_scope WHERE grain=60 AND bucket=NEW.bucket/60-(NEW.bucket%60<0) AND agent=NEW.agent AND precision=NEW.precision AND records=0;
END;
