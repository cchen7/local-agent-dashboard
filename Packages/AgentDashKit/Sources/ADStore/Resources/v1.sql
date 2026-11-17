
CREATE TABLE sources (
  id INTEGER PRIMARY KEY,
  agent TEXT NOT NULL,                 -- claude_code | codex | copilot | grok_build | ...
  label TEXT NOT NULL,
  root_path TEXT NOT NULL,
  environment TEXT NOT NULL DEFAULT 'Local',
  path_mappings_json TEXT NOT NULL DEFAULT '[]',
  env_rules_json TEXT NOT NULL DEFAULT '[]',    -- EnvironmentRule list (EXP-1)
  access_kind TEXT NOT NULL,           -- default_location | bookmark
  bookmark BLOB,
  enabled INTEGER NOT NULL DEFAULT 1,
  last_scan_at INTEGER, status TEXT, last_error TEXT,
  UNIQUE(agent, root_path)
);

CREATE TABLE source_files (
  id INTEGER PRIMARY KEY,
  source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  rel_path TEXT NOT NULL,
  role TEXT NOT NULL,                  -- session | subagent | prompt_history | sidecar | metadata_db
  inode INTEGER, size INTEGER, mtime_ns INTEGER,
  read_offset INTEGER NOT NULL DEFAULT 0,
  last_seq INTEGER NOT NULL DEFAULT -1,  -- resume file order across launches
  previous_ts INTEGER,                 -- timestamp inheritance across launches
  parser_version INTEGER NOT NULL,
  state TEXT NOT NULL,                 -- ok | partial | error | gone
  unknown_records INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  UNIQUE(source_id, rel_path)
);

CREATE TABLE projects (
  id INTEGER PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,            -- normalized repository URL if known, else root path
  root_path TEXT,                      -- host path (after path mapping)
  display_name TEXT NOT NULL,          -- default: last path component
  repo_url TEXT,
  first_seen_at INTEGER, last_active_at INTEGER,
  pinned INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sessions (
  id INTEGER PRIMARY KEY,
  agent TEXT NOT NULL,
  native_id TEXT NOT NULL,             -- the agent's own session id
  source_id INTEGER NOT NULL REFERENCES sources(id),
  file_id INTEGER REFERENCES source_files(id),
  project_id INTEGER REFERENCES projects(id),
  parent_session_id INTEGER REFERENCES sessions(id),      -- subagents
  resumed_from_session_id INTEGER REFERENCES sessions(id), -- resume / fork
  entrypoint TEXT,                     -- cli | desktop | app | ... (from originator/producer)
  environment TEXT NOT NULL,
  cwd TEXT, git_branch TEXT, git_sha TEXT,
  title TEXT, title_source TEXT,       -- agent | first_prompt | user
  first_prompt TEXT,
  started_at INTEGER, last_event_at INTEGER, ended_at INTEGER,
  status TEXT NOT NULL,                -- running | waiting | completed | failed | unknown
  status_reason TEXT,                  -- e.g. pending_tool_approval | turn_ended | error
  model_primary TEXT, cli_version TEXT,
  turn_count INTEGER DEFAULT 0, message_count INTEGER DEFAULT 0, tool_count INTEGER DEFAULT 0,
  tokens_input_fresh INTEGER DEFAULT 0, tokens_cache_read INTEGER DEFAULT 0,
  tokens_cache_write INTEGER DEFAULT 0, tokens_cache_write_1h INTEGER DEFAULT 0,
  tokens_output INTEGER DEFAULT 0, tokens_reasoning INTEGER DEFAULT 0,
  cost_micro_usd INTEGER DEFAULT 0,    -- list-price estimate (§8.4), 1e-6 USD
  context_window INTEGER, context_used INTEGER,
  latest_summary TEXT,                 -- the agent's own latest summary, if any
  source_deleted_at INTEGER,           -- when the agent cleaned up the raw file
  UNIQUE(agent, native_id)
);
CREATE INDEX sessions_last_event ON sessions(last_event_at DESC);
CREATE INDEX sessions_project ON sessions(project_id, last_event_at DESC);
CREATE INDEX sessions_status ON sessions(status);

CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,                -- order within the file
  ts INTEGER NOT NULL,                 -- UTC ms
  kind TEXT NOT NULL,                  -- user | assistant | tool_call | tool_result | summary | system | error | prompt_history | unknown
  tool_name TEXT,
  text TEXT,                           -- searchable text (truncated per ADP-7)
  meta_json TEXT,                      -- small structured fields: command, path, +/- lines, exit code, duration, inherited flag, ...
  blob_id INTEGER REFERENCES blobs(id),
  dedupe_key TEXT NOT NULL UNIQUE
);
CREATE INDEX events_session_seq ON events(session_id, seq);
CREATE INDEX events_ts ON events(ts);

CREATE VIRTUAL TABLE events_fts USING fts5(
  text, tool_name,
  content='events', content_rowid='id',
  tokenize='agentdash'                 -- custom tokenizer, §9.2
);
-- keep events_fts in sync with events via insert/update/delete triggers

CREATE TABLE blobs (                   -- compressed archive of large tool outputs
  id INTEGER PRIMARY KEY,
  codec TEXT NOT NULL DEFAULT 'lzfse',
  raw_len INTEGER NOT NULL,
  data BLOB NOT NULL
);

CREATE TABLE file_touches (
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  path TEXT NOT NULL, op TEXT NOT NULL,         -- read | edit | write | delete
  count INTEGER NOT NULL, lines_added INTEGER DEFAULT 0, lines_removed INTEGER DEFAULT 0,
  last_ts INTEGER NOT NULL,
  PRIMARY KEY(session_id, path, op)
);

CREATE TABLE commands (
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  ts INTEGER NOT NULL, command TEXT NOT NULL,
  exit_code INTEGER, duration_ms INTEGER, status TEXT
);

CREATE TABLE token_events (
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  agent TEXT NOT NULL, project_id INTEGER, model TEXT,
  ts INTEGER NOT NULL,
  input_fresh INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
  cache_write INTEGER NOT NULL DEFAULT 0, cache_write_1h INTEGER NOT NULL DEFAULT 0,
  output INTEGER NOT NULL DEFAULT 0, reasoning INTEGER NOT NULL DEFAULT 0,
  precision TEXT NOT NULL DEFAULT 'call',        -- call | snapshot | checkpoint
  cost_micro_usd INTEGER NOT NULL DEFAULT 0,     -- 1e-6 USD
  price_status TEXT NOT NULL DEFAULT 'unpriced', -- priced | approx | unpriced
  price_ref TEXT,                                -- matched price entry: model id + effectiveFrom
  dedupe_key TEXT NOT NULL UNIQUE
);
CREATE INDEX token_events_ts ON token_events(ts);

CREATE TABLE token_minute (            -- per-minute rollup; charts query this table
  bucket INTEGER NOT NULL,             -- UTC minute (epoch / 60)
  agent TEXT NOT NULL, project_id INTEGER NOT NULL DEFAULT 0, model TEXT NOT NULL DEFAULT '',
  input_fresh INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
  cache_write_1h INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL,
  cost_micro_usd INTEGER NOT NULL, unpriced_tokens INTEGER NOT NULL,
  calls INTEGER NOT NULL, has_coarse INTEGER NOT NULL DEFAULT 0,   -- contains snapshot/checkpoint data
  PRIMARY KEY(bucket, agent, project_id, model)
);
-- hour/day statistics aggregate token_minute in SQL; add materialized token_hour / token_day only if NFRs require it

CREATE TABLE rate_limit_snapshots (
  ts INTEGER NOT NULL, agent TEXT NOT NULL, limit_id TEXT NOT NULL,
  window TEXT NOT NULL,                -- primary | secondary
  window_minutes INTEGER, used_percent REAL, resets_at INTEGER, plan_type TEXT,
  PRIMARY KEY(agent, limit_id, window, ts)
);

CREATE TABLE session_keywords (
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  term TEXT NOT NULL, weight REAL NOT NULL,
  PRIMARY KEY(session_id, term)
);
CREATE TABLE term_df (term TEXT PRIMARY KEY, df INTEGER NOT NULL);   -- document frequency for keywords

CREATE TABLE saved_searches (id INTEGER PRIMARY KEY, name TEXT NOT NULL, query TEXT NOT NULL, sort TEXT);
CREATE TABLE app_meta (key TEXT PRIMARY KEY, value TEXT);   -- incl. pricing_hash, pricing_source, pricing_updated_at

CREATE TRIGGER events_ai AFTER INSERT ON events BEGIN
  INSERT INTO events_fts(rowid, text, tool_name) VALUES (new.id, new.text, new.tool_name);
END;
CREATE TRIGGER events_ad AFTER DELETE ON events BEGIN
  INSERT INTO events_fts(events_fts, rowid, text, tool_name) VALUES ('delete', old.id, old.text, old.tool_name);
END;
CREATE TRIGGER events_au AFTER UPDATE OF text, tool_name ON events BEGIN
  INSERT INTO events_fts(events_fts, rowid, text, tool_name) VALUES ('delete', old.id, old.text, old.tool_name);
  INSERT INTO events_fts(rowid, text, tool_name) VALUES (new.id, new.text, new.tool_name);
END;
