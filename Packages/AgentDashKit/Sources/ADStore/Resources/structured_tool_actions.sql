-- Normalized evidence belongs to its deduplicated transcript event.
ALTER TABLE events ADD COLUMN tool_action TEXT;
ALTER TABLE events ADD COLUMN action_outcome_id TEXT GENERATED ALWAYS AS (
    CASE WHEN kind IN ('tool_result','system') AND tool_action IS NOT NULL
        AND length(CAST(meta_json AS BLOB))<=16384 AND json_valid(meta_json)
    THEN CASE
        WHEN json_type(tool_action,'$.completion') IS NOT 'object' THEN NULL
        WHEN json_type(meta_json,'$.child_activity') IS 'true' THEN NULL
        WHEN json_type(meta_json,'$.call_id') NOT IN ('text','null') THEN NULL
        WHEN json_type(meta_json,'$.tool_use_id') NOT IN ('text','null') THEN NULL
        WHEN json_type(meta_json,'$.call_id')='text' AND json_type(meta_json,'$.tool_use_id')='text'
            AND (meta_json ->> '$.call_id') IS NOT (meta_json ->> '$.tool_use_id') THEN NULL
        WHEN length(CAST(coalesce(meta_json ->> '$.call_id',meta_json ->> '$.tool_use_id') AS BLOB)) BETWEEN 1 AND 512
            AND instr(coalesce(meta_json ->> '$.call_id',meta_json ->> '$.tool_use_id'),char(0))=0
        THEN coalesce(meta_json ->> '$.call_id',meta_json ->> '$.tool_use_id')
    END END
) VIRTUAL;
CREATE INDEX events_structured_outcome ON events(session_id,action_outcome_id,seq,id)
    WHERE action_outcome_id IS NOT NULL;

ALTER TABLE commands ADD COLUMN event_id INTEGER REFERENCES events(id) ON DELETE CASCADE;
CREATE UNIQUE INDEX commands_source_event ON commands(event_id) WHERE event_id IS NOT NULL;
CREATE INDEX commands_recent ON commands(session_id,ts DESC,id DESC);

ALTER TABLE file_touches ADD COLUMN unknown_added INTEGER NOT NULL DEFAULT 0;
ALTER TABLE file_touches ADD COLUMN unknown_removed INTEGER NOT NULL DEFAULT 0;
CREATE INDEX file_touches_rank ON file_touches(session_id,count DESC,last_ts DESC,path,op);

CREATE TABLE action_file_events (
    event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    op TEXT NOT NULL,
    ts INTEGER NOT NULL,
    added INTEGER,
    removed INTEGER,
    PRIMARY KEY(event_id,path,op)
);
CREATE INDEX action_file_events_rollup ON action_file_events(session_id,path,op,ts DESC);
CREATE INDEX action_file_events_recent ON action_file_events(session_id,ts DESC,event_id DESC,path,op);

-- Rollups change by exactly one event contribution. An indexed max lookup
-- replaces last_ts when that event is removed; no historical list is loaded.
CREATE TRIGGER action_file_events_insert AFTER INSERT ON action_file_events BEGIN
    INSERT INTO file_touches(session_id,path,op,count,lines_added,lines_removed,last_ts,unknown_added,unknown_removed)
    VALUES(new.session_id,new.path,new.op,1,coalesce(new.added,0),coalesce(new.removed,0),new.ts,
           new.added IS NULL,new.removed IS NULL)
    ON CONFLICT(session_id,path,op) DO UPDATE SET
        count=count+1, lines_added=coalesce(lines_added,0)+excluded.lines_added,
        lines_removed=coalesce(lines_removed,0)+excluded.lines_removed, last_ts=max(last_ts,excluded.last_ts),
        unknown_added=unknown_added+excluded.unknown_added, unknown_removed=unknown_removed+excluded.unknown_removed;
END;

CREATE TRIGGER action_file_events_delete AFTER DELETE ON action_file_events BEGIN
    DELETE FROM file_touches WHERE session_id=old.session_id AND path=old.path AND op=old.op AND count<=1;
    UPDATE file_touches SET
        count=count-1, lines_added=coalesce(lines_added,0)-coalesce(old.added,0),
        lines_removed=coalesce(lines_removed,0)-coalesce(old.removed,0),
        unknown_added=unknown_added-(old.added IS NULL), unknown_removed=unknown_removed-(old.removed IS NULL),
        last_ts=CASE WHEN last_ts=old.ts THEN coalesce((
            SELECT max(ts) FROM action_file_events WHERE session_id=old.session_id AND path=old.path AND op=old.op
        ),last_ts) ELSE last_ts END
    WHERE session_id=old.session_id AND path=old.path AND op=old.op;
END;

CREATE TRIGGER event_tool_actions_insert AFTER INSERT ON events
WHEN new.kind='tool_call' AND new.tool_action IS NOT NULL BEGIN
    INSERT INTO action_file_events(event_id,session_id,ts,path,op,added,removed)
        SELECT new.id,new.session_id,new.ts, f.value ->> '$.path', f.value ->> '$.operation',
            CASE WHEN count(*)=count(f.value ->> '$.added') THEN sum(f.value ->> '$.added') END,
            CASE WHEN count(*)=count(f.value ->> '$.removed') THEN sum(f.value ->> '$.removed') END
        FROM json_each(new.tool_action,'$.files') f
        WHERE new.kind='tool_call'
        GROUP BY f.value ->> '$.path', f.value ->> '$.operation';
    INSERT INTO commands(session_id,ts,command,event_id)
        SELECT new.session_id,new.ts,new.tool_action ->> '$.command',new.id
        WHERE json_type(new.tool_action,'$.command')='text';
END;

CREATE TRIGGER event_tool_actions_update AFTER UPDATE OF tool_action,kind,ts,session_id ON events
WHEN (old.kind='tool_call' OR new.kind='tool_call') AND (old.tool_action IS NOT NULL OR new.tool_action IS NOT NULL)
    AND (old.tool_action IS NOT new.tool_action OR old.kind IS NOT new.kind OR old.ts IS NOT new.ts OR old.session_id IS NOT new.session_id)
BEGIN
    DELETE FROM action_file_events WHERE event_id=new.id;
    DELETE FROM commands WHERE event_id=new.id;
    INSERT INTO action_file_events(event_id,session_id,ts,path,op,added,removed)
        SELECT new.id,new.session_id,new.ts, f.value ->> '$.path', f.value ->> '$.operation',
            CASE WHEN count(*)=count(f.value ->> '$.added') THEN sum(f.value ->> '$.added') END,
            CASE WHEN count(*)=count(f.value ->> '$.removed') THEN sum(f.value ->> '$.removed') END
        FROM json_each(new.tool_action,'$.files') f
        WHERE new.kind='tool_call'
        GROUP BY f.value ->> '$.path', f.value ->> '$.operation';
    INSERT INTO commands(session_id,ts,command,event_id)
        SELECT new.session_id,new.ts,new.tool_action ->> '$.command',new.id
        WHERE new.kind='tool_call' AND json_type(new.tool_action,'$.command')='text';
END;
