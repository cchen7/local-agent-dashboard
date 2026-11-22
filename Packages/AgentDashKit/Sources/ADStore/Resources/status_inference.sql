ALTER TABLE sessions ADD COLUMN status_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sessions ADD COLUMN status_dirty INTEGER NOT NULL DEFAULT 1;
ALTER TABLE sessions ADD COLUMN status_next_at INTEGER;
CREATE INDEX sessions_status_dirty ON sessions(id) WHERE status_dirty=1;
CREATE INDEX sessions_status_next ON sessions(status_next_at) WHERE status_next_at IS NOT NULL;

-- Track only changes that alter status evidence, including reassignment of
-- a copied record to its original session. Derived status writes never loop.
CREATE TRIGGER status_events_insert AFTER INSERT ON events
WHEN new.kind NOT IN ('unknown','prompt_history')
BEGIN
    UPDATE sessions SET status_revision=status_revision+1,status_dirty=1 WHERE id=new.session_id;
END;

CREATE TRIGGER status_events_delete AFTER DELETE ON events
WHEN old.kind NOT IN ('unknown','prompt_history')
BEGIN
    UPDATE sessions SET status_revision=status_revision+1,status_dirty=1 WHERE id=old.session_id;
END;

CREATE TRIGGER status_events_update AFTER UPDATE OF session_id,seq,ts,kind,meta_json ON events
WHEN (old.kind NOT IN ('unknown','prompt_history') OR new.kind NOT IN ('unknown','prompt_history'))
    AND (old.session_id IS NOT new.session_id OR old.seq IS NOT new.seq OR old.ts IS NOT new.ts
         OR old.kind IS NOT new.kind OR old.meta_json IS NOT new.meta_json)
BEGIN
    UPDATE sessions SET status_revision=status_revision+1,status_dirty=1 WHERE id IN(old.session_id,new.session_id);
END;

CREATE TRIGGER status_sessions_archive AFTER UPDATE OF source_deleted_at ON sessions
WHEN old.source_deleted_at IS NOT new.source_deleted_at
BEGIN
    UPDATE sessions SET status_revision=status_revision+1,status_dirty=1 WHERE id=new.id;
END;
