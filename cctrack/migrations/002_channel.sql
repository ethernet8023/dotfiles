-- How the money moved: tap, ATM, preauthorized debit, e-transfer, and so on.
--
-- CIBC writes this at the start of every Chequing and Savings description but
-- nowhere on a VISA row, so NULL means the export did not say -- not that no
-- channel exists. Readers must not treat NULL as "online".
--
-- The description keeps its prefix. It is part of the transaction fingerprint,
-- so rewriting it here would change every row's identity and make the next
-- import insert the whole history over again.

ALTER TABLE transactions ADD COLUMN channel TEXT;

-- Backfill from what is already stored. The CASE arms are ordered and the two
-- point-of-sale prefixes share a stem, so the longer one must be tested first.
--
-- substr(...) = '...' rather than LIKE '...%': SQLite's LIKE is
-- case-insensitive for ASCII, Python's str.startswith is not, and a backfill
-- that classifies rows the parser would leave alone is a silent disagreement
-- between old and new rows.
UPDATE transactions SET channel = CASE
  WHEN substr(description, 1, 26) = 'Point of Sale - Visa Debit' THEN 'visa_debit_pos'
  WHEN substr(description, 1, 23) = 'Point of Sale - Interac' THEN 'interac_pos'
  WHEN substr(description, 1, 25) = 'Automated Banking Machine' THEN 'abm'
  WHEN substr(description, 1, 25) = 'Electronic Funds Transfer' THEN 'eft'
  WHEN substr(description, 1, 16) = 'Internet Banking' THEN 'online_banking'
  WHEN substr(description, 1, 18) = 'Branch Transaction' THEN 'branch'
  ELSE NULL
END;

-- Partial: the queries that use this ask for one channel at a time, and the
-- rows with no channel are the ones nothing can be asked about.
CREATE INDEX idx_tx_channel ON transactions(channel, posted_on)
  WHERE channel IS NOT NULL;
