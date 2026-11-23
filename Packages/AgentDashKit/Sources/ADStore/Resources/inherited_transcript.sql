-- Copies reference one canonical event; neither text nor usage is duplicated.
-- The physical file and child IDs keep references isolated across replay.
CREATE TABLE inherited_transcript_items (
    file_id INTEGER NOT NULL REFERENCES source_files(id) ON DELETE CASCADE,
    child_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    owner_id INTEGER NOT NULL,
    copy_seq INTEGER NOT NULL,
    block INTEGER NOT NULL,
    PRIMARY KEY (file_id,event_id)
) WITHOUT ROWID;
CREATE INDEX inherited_transcript_child_order
    ON inherited_transcript_items(child_id,file_id,copy_seq,block,event_id);
CREATE INDEX inherited_transcript_child_owner
    ON inherited_transcript_items(child_id,file_id,owner_id);
CREATE INDEX inherited_transcript_event ON inherited_transcript_items(event_id);

-- A new body or owner cannot be attributed to an earlier copy with the same UUID.
CREATE TRIGGER inherited_transcript_invalidate AFTER UPDATE OF session_id,kind,text,tool_name ON events
WHEN OLD.session_id IS NOT NEW.session_id OR OLD.kind IS NOT NEW.kind OR OLD.text IS NOT NEW.text
    OR OLD.tool_name IS NOT NEW.tool_name
BEGIN
    DELETE FROM inherited_transcript_items WHERE event_id=NEW.id;
END;
