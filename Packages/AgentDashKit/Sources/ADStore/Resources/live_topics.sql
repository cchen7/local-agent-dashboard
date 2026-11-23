-- Durable revisions survive restart. A regenerated opaque token also rejects
-- a read result after the original session row was deleted and its ID reused.
CREATE TABLE topic_jobs (
    session_id INTEGER PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
    revision BLOB NOT NULL
);
CREATE TABLE topic_documents (
    session_id INTEGER PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE
);
CREATE TABLE topic_term_counts (
    session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    term TEXT NOT NULL,
    count REAL NOT NULL,
    PRIMARY KEY(session_id,term)
);
CREATE INDEX topic_term_counts_term ON topic_term_counts(term,session_id);

-- Previous versions only materialized final topic labels, not raw term
-- frequencies. Rebuild the frequency ledger from eligible indexed records.
DELETE FROM term_df;
INSERT INTO topic_jobs SELECT id,randomblob(16) FROM sessions;

CREATE TRIGGER topic_count_insert AFTER INSERT ON topic_term_counts BEGIN
    INSERT INTO term_df(term,df) VALUES(new.term,1)
    ON CONFLICT(term) DO UPDATE SET df=df+1;
END;

CREATE TRIGGER topic_count_delete AFTER DELETE ON topic_term_counts BEGIN
    DELETE FROM term_df WHERE term=old.term AND df<=1;
    UPDATE term_df SET df=df-1 WHERE term=old.term;
END;

CREATE TRIGGER topics_session_insert AFTER INSERT ON sessions BEGIN
    INSERT INTO topic_jobs VALUES(new.id,randomblob(16));
END;

CREATE TRIGGER topics_session_file AFTER UPDATE OF file_id ON sessions
WHEN new.file_id IS NOT old.file_id BEGIN
    INSERT INTO topic_jobs VALUES(new.id,randomblob(16))
    ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision;
END;

CREATE TRIGGER topics_file_role AFTER UPDATE OF role ON source_files
WHEN new.role IS NOT old.role AND (new.role='prompt_history' OR old.role='prompt_history') BEGIN
    INSERT INTO topic_jobs SELECT id,randomblob(16) FROM sessions WHERE file_id=new.id
    ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision;
END;

CREATE TRIGGER topics_event_insert AFTER INSERT ON events
WHEN new.kind IN ('user','assistant') BEGIN
    INSERT INTO topic_jobs VALUES(new.session_id,randomblob(16))
    ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision;
END;

CREATE TRIGGER topics_event_delete AFTER DELETE ON events
WHEN old.kind IN ('user','assistant') BEGIN
    INSERT INTO topic_jobs SELECT id,randomblob(16) FROM sessions WHERE id=old.session_id
    ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision;
END;

CREATE TRIGGER topics_event_update AFTER UPDATE OF kind,text,seq,meta_json,session_id,transcript_channel ON events
WHEN (old.kind IN ('user','assistant') OR new.kind IN ('user','assistant'))
    AND (old.kind IS NOT new.kind OR old.text IS NOT new.text OR old.seq IS NOT new.seq
         OR old.meta_json IS NOT new.meta_json OR old.session_id IS NOT new.session_id
         OR old.transcript_channel IS NOT new.transcript_channel)
BEGIN
    INSERT INTO topic_jobs SELECT id,randomblob(16) FROM sessions WHERE id IN(old.session_id,new.session_id)
    ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision;
END;

CREATE TRIGGER topics_file_insert AFTER INSERT ON file_touches BEGIN
    INSERT INTO topic_jobs VALUES(new.session_id,randomblob(16))
    ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision;
END;

CREATE TRIGGER topics_file_delete AFTER DELETE ON file_touches BEGIN
    INSERT INTO topic_jobs SELECT id,randomblob(16) FROM sessions WHERE id=old.session_id
    ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision;
END;

CREATE TRIGGER topics_file_update AFTER UPDATE OF path,session_id ON file_touches
WHEN old.path IS NOT new.path OR old.session_id IS NOT new.session_id BEGIN
    INSERT INTO topic_jobs SELECT id,randomblob(16) FROM sessions WHERE id IN(old.session_id,new.session_id)
    ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision;
END;
