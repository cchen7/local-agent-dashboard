ALTER TABLE sessions ADD COLUMN user_title TEXT;
-- Respect the reserved legacy origin if an old index already used it.
UPDATE sessions
SET user_title=title,title=NULL,title_source=NULL
WHERE title_source='user';

CREATE INDEX events_first_title_prompt ON events(session_id,seq,id) WHERE kind='user';
CREATE INDEX events_first_title_summary ON events(session_id,seq,id) WHERE kind='summary';

-- Read only the first qualifying indexed record if no higher-priority
-- title is available. Never duplicate a prompt string into an at-rest title.
CREATE VIEW titled_sessions AS
WITH titles AS (
    SELECT s.*,
        CASE WHEN s.user_title IS NULL THEN coalesce(
            CASE WHEN length(CAST(s.title AS BLOB))<=16384 AND trim(s.title)<>'' THEN s.title END,
            CASE WHEN s.agent='claude_code' THEN (
                SELECT e.text FROM events e WHERE e.session_id=s.id AND e.kind='summary'
                  AND length(CAST(e.text AS BLOB))<=16384 AND trim(e.text)<>''
                ORDER BY e.seq,e.id LIMIT 1
            ) END
        ) END AS supplied_title
    FROM sessions s
)
SELECT t.*,
    coalesce(t.user_title, t.supplied_title, (
        SELECT e.text FROM events e WHERE e.session_id=t.id AND e.kind='user'
          AND length(CAST(e.text AS BLOB))<=16384 AND agentdash_meaningful_prompt(e.text)
        ORDER BY e.seq,e.id LIMIT 1
    )) AS display_title,
    CASE WHEN t.user_title IS NOT NULL THEN 'user'
         WHEN t.supplied_title IS NOT NULL THEN 'agent'
         ELSE 'first_prompt' END AS display_title_source
FROM titles t;
