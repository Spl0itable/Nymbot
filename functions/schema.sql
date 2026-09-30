CREATE TABLE IF NOT EXISTS settings (
  pubkey TEXT NOT NULL,
  category TEXT NOT NULL,
  blob TEXT NOT NULL,
  content_hash TEXT,
  updated_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (pubkey, category)
);
CREATE INDEX IF NOT EXISTS settings_pubkey ON settings (pubkey);
CREATE INDEX IF NOT EXISTS settings_pubkey_updated ON settings (pubkey, updated_at);

CREATE TABLE IF NOT EXISTS profiles (
  pubkey TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  event TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS credits (
  pubkey TEXT PRIMARY KEY,
  balance INTEGER NOT NULL DEFAULT 0,
  total_purchased INTEGER NOT NULL DEFAULT 0,
  total_used INTEGER NOT NULL DEFAULT 0,
  rl TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS invoices (
  invoice_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  state TEXT NOT NULL,
  data TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (kind, state, invoice_id)
);

CREATE TABLE IF NOT EXISTS codes (
  code TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  owner TEXT,
  created_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS shop (
  pubkey TEXT PRIMARY KEY,
  owned TEXT NOT NULL DEFAULT '{}',
  active TEXT NOT NULL DEFAULT '{}',
  updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS botpm_thread (
  pubkey TEXT PRIMARY KEY,
  ids TEXT NOT NULL DEFAULT '[]',
  updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS botpm_wraps (
  pubkey TEXT NOT NULL,
  id TEXT NOT NULL,
  json TEXT NOT NULL,
  root TEXT,
  msg TEXT,
  misses INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  stored_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (pubkey, id)
);
CREATE INDEX IF NOT EXISTS botpm_wraps_pubkey ON botpm_wraps (pubkey);
CREATE INDEX IF NOT EXISTS botpm_wraps_root ON botpm_wraps (pubkey, root);

CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  channel TEXT,
  kind INTEGER NOT NULL,
  pubkey TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT 0,
  json TEXT NOT NULL,
  stored_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS events_channel_created ON events (channel, created_at DESC);
CREATE INDEX IF NOT EXISTS events_kind_created ON events (kind, created_at DESC);
CREATE INDEX IF NOT EXISTS events_pubkey ON events (pubkey);

CREATE TABLE IF NOT EXISTS emoji_packs (
  coord TEXT PRIMARY KEY,
  kind INTEGER NOT NULL,
  pubkey TEXT NOT NULL,
  d TEXT,
  created_at INTEGER NOT NULL DEFAULT 0,
  json TEXT NOT NULL,
  stored_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS emoji_packs_kind_created ON emoji_packs (kind, created_at DESC);

CREATE TABLE IF NOT EXISTS zaps (
  id TEXT PRIMARY KEY,
  target_id TEXT NOT NULL,
  pubkey TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT 0,
  json TEXT NOT NULL,
  stored_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS zaps_target ON zaps (target_id);

CREATE TABLE IF NOT EXISTS pm (
  pubkey TEXT NOT NULL,
  id TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT 0,
  event TEXT NOT NULL,
  stored_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (pubkey, id)
);
CREATE INDEX IF NOT EXISTS pm_pubkey_created ON pm (pubkey, created_at DESC);

CREATE TABLE IF NOT EXISTS shares (
  hash TEXT NOT NULL,
  part INTEGER NOT NULL,
  parts INTEGER NOT NULL,
  owner TEXT NOT NULL,
  data TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (hash, part)
);
CREATE INDEX IF NOT EXISTS shares_owner ON shares (owner);

CREATE TABLE IF NOT EXISTS api_keys (
  id TEXT PRIMARY KEY,
  pubkey TEXT NOT NULL,
  name TEXT NOT NULL,
  hash TEXT UNIQUE NOT NULL,
  hint TEXT,
  limit_sats INTEGER,
  reset_period TEXT,
  expire_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at INTEGER
);
CREATE INDEX IF NOT EXISTS api_keys_pubkey ON api_keys (pubkey, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS api_keys_name ON api_keys (pubkey, lower(name)) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS api_queries (
  id TEXT PRIMARY KEY,
  at INTEGER NOT NULL,
  pubkey TEXT NOT NULL,
  key_id TEXT,
  model TEXT,
  type TEXT NOT NULL,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cached_tokens INTEGER NOT NULL DEFAULT 0,
  cost_msat INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL,
  balance TEXT,
  web_search INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS api_queries_pubkey ON api_queries (pubkey, at);
CREATE INDEX IF NOT EXISTS api_queries_key ON api_queries (key_id, at);
CREATE INDEX IF NOT EXISTS api_queries_at ON api_queries (at);

CREATE TABLE IF NOT EXISTS api_video_jobs (
  id TEXT PRIMARY KEY,
  pubkey TEXT NOT NULL,
  key_id TEXT,
  model TEXT NOT NULL,
  status TEXT NOT NULL,
  job_url TEXT,
  hold_id TEXT NOT NULL,
  hold_credits INTEGER NOT NULL,
  key_limited INTEGER NOT NULL DEFAULT 0,
  milli INTEGER NOT NULL,
  seconds INTEGER,
  resolution TEXT,
  url TEXT,
  content_type TEXT,
  error TEXT,
  charged_milli INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  completed_at INTEGER,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS api_video_jobs_pubkey ON api_video_jobs (pubkey, created_at);
CREATE INDEX IF NOT EXISTS api_video_jobs_expires ON api_video_jobs (expires_at);

CREATE TABLE IF NOT EXISTS api_nwc (
  pubkey TEXT PRIMARY KEY,
  uri_enc TEXT NOT NULL,
  threshold_sats INTEGER NOT NULL,
  topup_sats INTEGER NOT NULL,
  tier TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_topup_at INTEGER,
  last_topup_sats INTEGER,
  last_error TEXT,
  last_attempt_at INTEGER
);
