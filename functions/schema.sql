CREATE TABLE IF NOT EXISTS settings (
  pubkey TEXT NOT NULL,
  category TEXT NOT NULL,
  blob TEXT NOT NULL,
  content_hash TEXT,
  updated_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (pubkey, category)
);
CREATE INDEX IF NOT EXISTS settings_pubkey ON settings (pubkey);

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
  created_at INTEGER NOT NULL DEFAULT 0,
  stored_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (pubkey, id)
);
CREATE INDEX IF NOT EXISTS botpm_wraps_pubkey ON botpm_wraps (pubkey);

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
