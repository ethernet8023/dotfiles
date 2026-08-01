-- Initial schema. Money is integer cents everywhere; no floats in this database.

CREATE TABLE accounts (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,      -- 'CIBC VISA', 'Chequing'
  kind TEXT NOT NULL,             -- 'credit' | 'debit'
  card_last4 TEXT
);

CREATE TABLE categories (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  parent_id INTEGER REFERENCES categories(id)
);

CREATE TABLE transactions (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id),
  posted_on TEXT NOT NULL,        -- ISO 'YYYY-MM-DD'
  description TEXT NOT NULL,
  amount_cents INTEGER NOT NULL,  -- negative = money out
  card_last4 TEXT,                -- varies within an account: one VISA file
                                  -- carries two different cards
  fingerprint TEXT NOT NULL UNIQUE,
  category_id INTEGER REFERENCES categories(id),
  category_source TEXT,           -- 'rule' | 'manual' | NULL
  is_split_parent INTEGER NOT NULL DEFAULT 0,
  imported_at TEXT NOT NULL
);
CREATE INDEX idx_tx_posted ON transactions(posted_on);
CREATE INDEX idx_tx_account ON transactions(account_id, posted_on);
CREATE INDEX idx_tx_uncategorized
  ON transactions(category_id) WHERE category_id IS NULL;

CREATE TABLE splits (
  id INTEGER PRIMARY KEY,
  parent_tx_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  category_id INTEGER NOT NULL REFERENCES categories(id),
  amount_cents INTEGER NOT NULL,
  note TEXT
);
CREATE INDEX idx_splits_parent ON splits(parent_tx_id);

CREATE TABLE rules (
  id INTEGER PRIMARY KEY,
  pattern TEXT NOT NULL,          -- regex against description
  category_id INTEGER NOT NULL REFERENCES categories(id),
  priority INTEGER NOT NULL DEFAULT 100,  -- lower wins
  origin TEXT NOT NULL,           -- 'seed' | 'learned'
  created_at TEXT NOT NULL
);

CREATE TABLE plan (
  id INTEGER PRIMARY KEY,
  month TEXT NOT NULL,            -- 'YYYY-MM'
  category_id INTEGER REFERENCES categories(id),  -- NULL = whole-month total
  planned_cents INTEGER NOT NULL,
  UNIQUE(month, category_id)
);
