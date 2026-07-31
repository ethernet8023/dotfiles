# Credit Card Tracker Implementation Plan

> **For Hermes:** implement task-by-task. TDD each one. Commit after every task.

**Goal:** A local budget tracker that pulls CIBC card transactions in automatically, categorizes them with learned rules, surfaces unknowns for one-tap tagging, supports splitting one charge across categories, and draws exactly one honest chart of monthly burn vs. plan.

**Architecture:** A Python package (`cctrack`) over a single SQLite file. Ingest is layered: a pure CSV parser at the bottom (testable, no network), a Playwright driver on top that logs into CIBC and downloads that CSV, and helpers that fetch the password from Bitwarden and the 2FA code from the local Beeper Desktop API. Categorization is a rules table evaluated in priority order; anything unmatched lands in a review queue. Splits are child rows that must sum to the parent. Reporting is one matplotlib chart.

**Tech stack:** Python 3.13, uv, SQLite (stdlib `sqlite3`), Playwright (Python), Typer CLI, matplotlib, pytest. Nix flake devShell for tooling.

---

## Current context

Verified on this machine, 2026-07-31:

| Thing | State |
|---|---|
| `/home/ari/src/credit-card-tracker` | contains only `IDEA.md`, **not a git repo yet** |
| `uv` | `/home/ari/.local/bin/uv` |
| `python3` | 3.13.13 (PEP 668 — must use a venv) |
| `nix` | Lix 2.96, flakes available |
| Beeper Desktop | running, API on `127.0.0.1:23373`. **API is v1** (not v0) with OAuth 2.0 + dynamic client registration + PKCE. Flow completed, token acquired, `read` scope is enough. |
| `bw` / `rbw` | added to the devShell — `bitwarden-cli` 2026.7.0, currently **unauthenticated** (`bw login` needed) |
| `playwright` | **from nix, not pip.** nixpkgs patches the python package to match its own chromium build; pypi's wheel expects a different revision and they will never agree. `python313.withPackages [ ps.playwright ]` + `playwright-driver.browsers`. |
| `cage` | added to the devShell — required, see Task 10 |

### Settled by measurement (was: assumptions)

1. **2FA delivery is SMS**, confirmed by the user, and real CIBC codes are visible in Beeper history. The Beeper OTP path is viable. Shortcode `242227` is sign-on; `242226` is 3-D Secure purchase auth and must be excluded — see Task 9.
2. **CIBC will not serve a headless browser.** Headless chromium is dropped during the h2 handshake by Akamai; JS stealth patches cannot help. Everything runs headed under `cage`. Full matrix in Task 10.
3. **The sign-on form is two-step** (card number, then password) and lives behind a redirect to `secure.cibc.com` with a short-lived session id. Selectors harvested to `docs/cibc-selectors.md`.

### Assumptions still to confirm before coding (do not guess)

1. **CIBC CSV shape.** Believed to be headerless: `date,description,debit,credit,card_number`, with debit/credit in separate columns and one blank. **Task 2 requires a real exported file** — ask the user to download one month manually from `My Accounts → Download transactions` and drop it at `fixtures/cibc_sample.csv`. Do not write the parser against an imagined format.
2. **Bitwarden item name.** Need the exact item name/ID for the CIBC login. Ask.

### Security rules for this repo

- Credentials never touch disk. Read from `bw` on stdout, hold in memory, never log.
- `data/`, `*.db`, `downloads/`, `.env` in `.gitignore` from the first commit.
- The OTP reader accepts only messages whose timestamp is **after** the login attempt started (replay protection) and from a known CIBC sender.
- Playwright runs headed-by-default the first time so the user can see what it does; `--headless` is opt-in.

---

## Phased shape

- **Phase A (Tasks 1–6):** repo skeleton, DB, CSV import, dedup. *End state: `cctrack import file.csv` works, a manually downloaded CSV loads and re-loads with zero duplicates.*
- **Phase B (Tasks 7–11):** Bitwarden, Beeper OTP, Playwright CIBC login + download. *End state: `cctrack sync` fetches with no human in the loop.*
- **Phase C (Tasks 12–16):** categories, rules, learning, review queue, cron. *End state: unknowns get surfaced, tagging one teaches the rule forever.*
- **Phase D (Tasks 17–19):** splits.
- **Phase E (Tasks 20–22):** plan, burn report, the one chart.

Phase A is independently useful. If Phase B fights back, the tool is still good with manual CSV drops.

---

## Task 1: Repo skeleton + git init

**Objective:** A committable project with a working venv and a green (empty) test run.

**Files:**
- Create: `pyproject.toml`, `.gitignore`, `flake.nix`, `nix/devShell.nix`, `cctrack/__init__.py`, `tests/__init__.py`

**Step 1:** `git init` and write `.gitignore`:

```gitignore
.venv/
__pycache__/
*.pyc
data/
downloads/
*.db
*.db-wal
*.db-shm
.env
fixtures/cibc_*.csv
!fixtures/cibc_sample_redacted.csv
.pytest_cache/
```

**Step 2:** `pyproject.toml`:

```toml
[project]
name = "cctrack"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = [
    "typer>=0.15",
    "playwright>=1.49",
    "matplotlib>=3.9",
    "httpx>=0.28",
    "platformdirs>=4.3",
]

[project.optional-dependencies]
dev = ["pytest>=8.3", "pytest-asyncio>=0.24"]

[project.scripts]
cctrack = "cctrack.cli:app"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.pytest.ini_options]
testpaths = ["tests"]
```

**Step 3:** `nix/devShell.nix` — extend the existing devShell pattern, do not create single-purpose shells:

```nix
{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [
    python313
    uv
    bitwarden-cli   # `bw` — not installed on this machine yet
    jq
    sqlite
  ];
  shellHook = ''
    export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    [ -d .venv ] || uv venv
    source .venv/bin/activate
    uv pip install -e '.[dev]' --quiet
  '';
}
```

`flake.nix` wires `devShells.default = import ./nix/devShell.nix { inherit pkgs; };` for `x86_64-linux`.

**Step 4:** Verify.

Run: `nix develop -c pytest -q`
Expected: `no tests ran` (exit 5) — proves the shell, venv, and pytest all resolve.

**Step 5:** Commit.

```bash
git add -A && git commit -m "chore: project skeleton with nix devShell"
```

---

## Task 2: Obtain a real CIBC CSV fixture

**Objective:** Ground the parser in reality instead of a guess.

**Steps:**
1. Ask the user to log into CIBC, download one month of card transactions as CSV, save to `fixtures/cibc_sample.csv`.
2. Inspect it: `head -5 fixtures/cibc_sample.csv` and `python3 -c "import csv,sys; print(next(csv.reader(open('fixtures/cibc_sample.csv'))))"`.
3. Write `fixtures/cibc_sample_redacted.csv` — same structure, 6 rows, merchant names kept, amounts rounded, card number replaced with `4506XXXXXXXX0000`. **This redacted file is the committed test fixture.**
4. Record the observed column order in `docs/cibc-csv-format.md`.

**Blocked until the user provides the file.** Do not proceed to Task 3 with an invented format.

---

## Task 3: SQLite schema + migration runner

**Objective:** A versioned database that opens idempotently.

**Files:**
- Create: `cctrack/db.py`, `cctrack/migrations/001_initial.sql`, `tests/test_db.py`

**Step 1: failing test** (`tests/test_db.py`):

```python
from cctrack.db import connect, schema_version

def test_connect_creates_schema(tmp_path):
    db = tmp_path / "t.db"
    con = connect(db)
    assert schema_version(con) == 1
    tables = {r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"transactions", "accounts", "categories", "rules", "splits"} <= tables

def test_connect_is_idempotent(tmp_path):
    db = tmp_path / "t.db"
    connect(db).close()
    con = connect(db)
    assert schema_version(con) == 1
```

**Step 2:** `pytest tests/test_db.py -v` → FAIL, no module `cctrack.db`.

**Step 3:** `cctrack/migrations/001_initial.sql`:

```sql
CREATE TABLE accounts (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,      -- "CIBC Dividend Visa"
  kind TEXT NOT NULL,             -- 'credit' | 'debit'
  card_last4 TEXT
);

CREATE TABLE categories (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,      -- 'fun', 'home', 'groceries'
  parent_id INTEGER REFERENCES categories(id)
);

CREATE TABLE transactions (
  id INTEGER PRIMARY KEY,
  account_id INTEGER NOT NULL REFERENCES accounts(id),
  posted_on TEXT NOT NULL,        -- ISO 'YYYY-MM-DD'
  description TEXT NOT NULL,
  amount_cents INTEGER NOT NULL,  -- negative = money out. integers only, never float.
  fingerprint TEXT NOT NULL UNIQUE,
  category_id INTEGER REFERENCES categories(id),
  category_source TEXT,           -- 'rule' | 'manual' | NULL
  is_split_parent INTEGER NOT NULL DEFAULT 0,
  imported_at TEXT NOT NULL
);
CREATE INDEX idx_tx_posted ON transactions(posted_on);
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
```

**Step 4:** `cctrack/db.py` — `connect(path)` applies any `NNN_*.sql` above `user_version` inside a transaction, sets `PRAGMA foreign_keys=ON` and `journal_mode=WAL`, returns the connection. `schema_version(con)` reads `PRAGMA user_version`.

**Step 5:** `pytest tests/test_db.py -v` → 2 passed. Commit.

**Note on amounts:** `amount_cents` is an integer everywhere. No floats in the money path, ever — including the CSV parser, which must parse `"12.34"` via `Decimal` then `int(d * 100)`, not `float()`.

---

## Task 4: CSV parser (pure, no DB)

**Objective:** Turn CIBC CSV bytes into `ParsedTx` records.

**Files:**
- Create: `cctrack/ingest/cibc_csv.py`, `tests/test_cibc_csv.py`
- Fixture: `fixtures/cibc_sample_redacted.csv` (from Task 2)

**Step 1: failing test** — assert on real values from the redacted fixture:

```python
from decimal import Decimal
from cctrack.ingest.cibc_csv import parse_csv

def test_parses_fixture(fixture_path):
    rows = parse_csv(fixture_path.read_text())
    assert len(rows) == 6
    first = rows[0]
    assert first.posted_on == "2026-06-03"          # <- real value from fixture
    assert first.amount_cents == -1234              # debit is negative
    assert "TIM HORTONS" in first.description

def test_credit_column_is_positive():
    row = parse_csv("2026-06-05,PAYMENT THANK YOU,,150.00,4506XXXXXXXX0000\n")[0]
    assert row.amount_cents == 15000

def test_rejects_unexpected_column_count():
    import pytest
    with pytest.raises(ValueError, match="expected 5 columns"):
        parse_csv("a,b\n")
```

**Step 2:** Run → FAIL.

**Step 3:** Implement. `ParsedTx` is a frozen dataclass (`posted_on`, `description`, `amount_cents`, `card_last4`). Strip whitespace, collapse internal runs of spaces in descriptions (CIBC pads them), parse money via `Decimal`.

**Step 4:** Run → 3 passed. Commit.

---

## Task 5: Fingerprints + idempotent import

**Objective:** Import the same CSV twice, get each transaction once.

**Files:**
- Create: `cctrack/ingest/importer.py`, `tests/test_importer.py`

**The problem:** CIBC CSV has no transaction ID. Two identical `$4.50 TIM HORTONS` charges on the same day are legitimately distinct rows, so a naive hash of the fields collapses them.

**The fix:** fingerprint over `(account_id, posted_on, description, amount_cents, ordinal)` where `ordinal` is the 0-based index of that row *among identical rows in the same import batch*. Re-importing an overlapping file reproduces the same ordinals, so it dedups; a genuinely new third identical charge gets `ordinal=2` and lands.

**Step 1: failing test:**

```python
def test_import_twice_is_idempotent(tmp_path, sample_csv):
    con = connect(tmp_path / "t.db")
    acct = ensure_account(con, "CIBC Visa", "credit", "0000")
    n1 = import_csv(con, acct, sample_csv)
    n2 = import_csv(con, acct, sample_csv)
    assert n1 == 6 and n2 == 0
    assert con.execute("SELECT count(*) FROM transactions").fetchone()[0] == 6

def test_duplicate_same_day_charges_both_land(tmp_path):
    csv = ("2026-06-05,COFFEE,4.50,,0000\n" * 2)
    con = connect(tmp_path / "t.db")
    acct = ensure_account(con, "a", "credit", "0000")
    assert import_csv(con, acct, csv) == 2
```

**Step 2–4:** run red, implement `fingerprint()` as `sha256` hex of the joined tuple, `import_csv()` using `INSERT OR IGNORE` and returning the inserted count. Run green. Commit.

---

## Task 6: `cctrack import` CLI

**Objective:** End-to-end command against the real (unredacted) download.

**Files:** Create `cctrack/cli.py`, `cctrack/config.py`, `tests/test_cli_import.py`

DB path resolves to `platformdirs.user_data_dir("cctrack")/cctrack.db`, overridable with `--db` or `$CCTRACK_DB`.

```
cctrack import fixtures/cibc_sample.csv --account "CIBC Visa"
```

Test with Typer's `CliRunner` against a tmp DB. Then run it for real on the user's actual download and print the row count. Commit.

**Phase A done.** The tool is already useful here.

---

## Task 7: Bitwarden credential reader

**Objective:** Get the CIBC username/password out of `bw` without ever writing them down.

**Files:** Create `cctrack/secrets/bitwarden.py`, `tests/test_bitwarden.py`

**The item is `cibc.com`** (confirmed with the user; login username is a 16-digit card number ending 1883). Not `cibc business` — that is a different account with security questions and a PIN. Default to `cibc.com`, overridable via `--bw-item` / `CCTRACK_BW_ITEM`.

`get_login(item_name) -> Credential(username, password)` shells out to
`bw get item <name> --raw` and parses `login.username` / `login.password` from JSON.

- If `BW_SESSION` is unset → raise `BitwardenLocked("run: export BW_SESSION=$(bw unlock --raw)")`. Never prompt inside a cron run.
- Pass the session via the subprocess `env`, never on the argv — anything on argv is world-readable in `/proc/<pid>/cmdline`.
- `Credential` overrides `__repr__` and `__str__` to return `Credential(username='...', password=***)` so it cannot leak into a traceback or log line. **Test this explicitly.**

Tests mock `subprocess.run`. No network, no real vault.

```python
def test_repr_does_not_leak_password():
    c = Credential("me@example.com", "hunter2")
    assert "hunter2" not in repr(c)
    assert "hunter2" not in str(c)
    assert "hunter2" not in f"{c}"
```

Commit.

---

## Task 8: Beeper API probe — **DONE**

Findings are in `docs/beeper-api.md` and implemented in `cctrack/secrets/beeper.py`:

- API is **v1**, not v0. `/v0/*` returns 404.
- Auth is real **OAuth 2.0** (authorization code + PKCE + dynamic client registration) at `/oauth/register`, `/oauth/authorize`, `/oauth/token` — not a token pasted from Settings. Scope `read` suffices. Beeper Desktop shows an in-app approval prompt.
- Search is `GET /v1/messages/search` with `query`, `limit`, `sender`, `accountIDs`, and **`dateAfter`** (ISO 8601, filtered server-side — this is what makes stale-OTP rejection reliable).
- Message fields are camelCase: `id`, `chatID`, `accountID`, `senderID`, `senderName`, `timestamp` (ISO 8601), `text` (**may be `null`** on attachment-only messages).
- Token is persisted `0600` under `platformdirs.user_config_dir("cctrack")`, outside the repo. `BEEPER_ACCESS_TOKEN` overrides.

**Deliverable is the doc, not code.** Task 9 depends on real field names — do not invent them.

---

## Task 9: OTP reader

**Objective:** Pull a fresh CIBC 2FA code out of Beeper.

**Files:** Create `cctrack/secrets/beeper_otp.py`, `tests/test_beeper_otp.py`

```python
def wait_for_otp(since: datetime, timeout_s: int = 120,
                 poll_s: int = 3, client=None) -> str: ...
```

Rules, each with a test against a fake client:
- Only consider messages with `timestamp > since`. A code that arrived before the login attempt is **stale and must be ignored** — this is the whole point. Beeper's search takes a server-side `dateAfter`, so pass `since` straight through *and* re-check locally; belt and braces on the one rule that matters.
- **Sender must be shortcode `242227` exactly.** CIBC uses two shortcodes and they are not interchangeable:

  | shortcode | message | use |
  | --- | --- | --- |
  | **242227** | `Enter code: NNNNNN to authorize sign on to online banking` | **this one** |
  | 242226 | `Enter code: NNNNNN for CAD 734.49 at Amazon on card ending 6602` | 3-D Secure purchase auth — **never** |

  Matching loosely on "CIBC + six digits" can pick up a purchase-authorization code mid-login. Filter on sender first, and require the body to match `to authorize sign on`. Test this explicitly with a 242226 message present.
- Extract with `re.search(r"\b(\d{6})\b", text)`; if a message has two 6-digit runs, reject it as ambiguous rather than guessing.
- Timeout raises `OtpTimeout`, and the caller falls back to `typer.prompt("enter the code from your phone")` when interactive.

```python
def test_ignores_message_older_than_since():
    client = FakeClient([msg("123456", t=T0 - timedelta(minutes=1))])
    with pytest.raises(OtpTimeout):
        wait_for_otp(since=T0, timeout_s=0, client=client)

def test_returns_fresh_code():
    client = FakeClient([msg("654321", t=T0 + timedelta(seconds=5))])
    assert wait_for_otp(since=T0, client=client) == "654321"

def test_ignores_purchase_authorization_code():
    # 242226 is 3-D Secure, not sign-on. Fresh, six digits, still wrong.
    client = FakeClient([
        msg("999888", t=T0 + timedelta(seconds=2), sender="242226",
            text="Enter code: 999888 for CAD 734.49 at Amazon on card ending 6602"),
    ])
    with pytest.raises(OtpTimeout):
        wait_for_otp(since=T0, timeout_s=0, client=client)
```

Commit.

---

## Task 10: CIBC Playwright login

**Objective:** Get to the logged-in accounts page, unattended.

**Files:** Create `cctrack/ingest/cibc_web.py`; `docs/cibc-selectors.md` already exists (harvested, see below)

**Settled by measurement — do not re-litigate:**

CIBC's edge is Akamai Bot Manager. It refuses headless chromium *at the transport layer*:

| mode | result |
| --- | --- |
| headless shell (playwright default) | `ERR_HTTP2_PROTOCOL_ERROR` |
| full chromium, new-headless (`channel="chromium"`) | `ERR_HTTP2_PROTOCOL_ERROR` |
| new-headless + `navigator.webdriver` stealth patches | `ERR_HTTP2_PROTOCOL_ERROR` |
| headed, visible window | 200 |
| **headed under `cage` (`WLR_BACKENDS=headless`)** | **200, front door + sign-on** |

The connection dies during the h2 handshake — before any HTML, before any JS. JS stealth patches cannot help because the page they run in never loads. `channel="chromium"` rules out the headless-shell binary as the cause.

So the scraper **always runs `headless=False`**, wrapped in `cage`. There is no `--headless` flag; it would only ever fail. Re-run `scripts/diag_cibc_stealth.py` + `scripts/diag_cibc_cage.sh` if this ever regresses.

Entrypoint must be a shell wrapper like `scripts/harvest_cibc_selectors.sh`:

```bash
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1
unset WAYLAND_DISPLAY
exec cage -- python3 -m cctrack sync
```

**The real sign-on flow (harvested, not guessed):**

1. `https://www.cibconline.cibc.com/ebm-resources/public/client/web/index.html#/signon` **redirects** to `secure.cibc.com/etc/designs/cibcsecure/client/index.html?...&cahSessionId=<...>&iat=<ms>&exp=<ms>`. The session id is short-lived (~15 min). **Never hardcode the post-redirect URL** — always start from the public one and follow.
2. Login is **two-step**. Page one has *only* the card number field and Continue. The password field appears on the next screen. A single fill-both-and-submit will not work.
3. Element ids are Angular-generated (`textfield-40-input`, `checkbox-22-input`) and **will drift on redeploy**. Select on stable attributes:
   - card number: `input[name="Card"]` (maxlength 19, `autocomplete="username"`)
   - remember card: `input[name="RememberCard"]` — **tick it**, fewer 2FA prompts
   - submit: `button:has-text("Continue")`
   - form: `form[name="card-number-frm-cah"]`
4. A **OneTrust cookie banner** (`#onetrust-accept-btn-handler`) overlays the page and will intercept clicks. Dismiss it first, tolerating absence once the cookie is stored.

Then implement:

```python
async def login(page, cred: Credential, otp_provider) -> None: ...
async def download_transactions(page, account_label: str,
                                since: date, dest: Path) -> Path: ...
```

Hard requirements:
- **Persistent browser context** at `~/.local/share/cctrack/browser/` — CIBC remembers trusted devices, so after the first run 2FA usually stops firing entirely. This is the single biggest reliability win, and it pairs with the RememberCard checkbox.
- Selectors live in this one module, nowhere else.
- On any failure, screenshot to `downloads/failure-<ts>.png` and re-raise. Debugging a bank scraper blind is misery.
- Never log the page content of an authenticated page.

**This task cannot be unit-tested meaningfully.** Verification is a real run that produces a real CSV. Say that out loud rather than writing a mock that proves nothing.

---

## Task 11: `cctrack sync`

**Objective:** One command: Bitwarden → login → OTP → download → import.

Wire Tasks 7/9/10/5 together in `cctrack/cli.py`. `--since` defaults to `max(posted_on)` in the DB minus 5 days (overlap window; dedup absorbs it). Print `imported N new transactions`.

Verify with a real run. Commit.

**Phase B done.**

---

## Task 12: Category seeding

`cctrack/categories.py` + `cctrack/data/seed_categories.json` — groceries, restaurants, fun, home, transit, subscriptions, utilities, health, income, transfer. `cctrack categories add/list`. Tests on the CRUD. Commit.

---

## Task 13: Rule engine

**Files:** `cctrack/rules.py`, `tests/test_rules.py`

```python
def match(description: str, rules: list[Rule]) -> Rule | None:
    """Lowest priority number wins; ties broken by rule id (oldest first)."""
```

Tests: exact match, priority ordering, no-match returns `None`, an invalid regex in the table is skipped with a warning rather than crashing the whole run (one bad learned rule must not break categorization for everything else).

Commit.

---

## Task 14: `cctrack categorize`

Apply rules to every transaction where `category_id IS NULL`, set `category_source='rule'`. Never overwrite `category_source='manual'` — a human decision outranks a pattern, always. Test that specifically. Report `categorized N, N unknown remaining`. Commit.

---

## Task 15: Review queue + learning

**Files:** `cctrack/review.py`

```
cctrack review          # interactive: show unknowns newest-first, pick a category
cctrack review --json   # machine-readable, for the cron job
```

When the user tags a transaction interactively:
1. Set its category with `category_source='manual'`.
2. Derive a merchant pattern from the description (strip trailing store numbers, city, and reference digits — `AMZN MKTP CA*2H45R6` → `^AMZN MKTP CA`).
3. Show the derived pattern and how many *other* pending transactions it would catch, then ask to save it as a `learned` rule.
4. On yes: insert the rule and apply it to the rest of the queue immediately.

That last bit is the feature — tagging one Amazon charge should clear all the Amazon charges. Test that the count shown matches the count actually applied.

Commit.

---

## Task 16: The cron job

Register a Hermes cron job, daily at 09:00:

```
cronjob(action='create', schedule='0 9 * * *', name='cctrack daily',
        workdir='/home/ari/src/credit-card-tracker',
        prompt="Run `nix develop -c cctrack sync` then `nix develop -c cctrack categorize`. "
               "Then run `nix develop -c cctrack review --json`. If it returns an empty "
               "list, reply with exactly nothing. Otherwise show the unknown transactions "
               "as a markdown table (date, merchant, amount) and ask which category each "
               "belongs to.",
        enabled_toolsets=['terminal'])
```

Silence when there is nothing to review — no "0 unknowns found ✅" noise.

**Caveat to raise with the user:** if `BW_SESSION` has expired the sync step fails. Options are a long-lived unlocked session, or letting the job skip sync and only categorize what is already imported. Ask which they want before wiring it.

Verify with `cronjob(action='run', job_id=...)`. Commit.

---

## Task 17: Split model + invariant

**Files:** `cctrack/splits.py`, `tests/test_splits.py`

The invariant: **the splits of a transaction sum exactly to the parent amount.** Enforce it in `save_splits()`, not just in the UI.

```python
def test_splits_must_sum_to_parent(tmp_path):
    ...
    with pytest.raises(SplitMismatch, match="sum 4000 != parent 5000"):
        save_splits(con, tx_id, [(fun, -2000), (home, -2000)])

def test_valid_split_marks_parent(tmp_path):
    save_splits(con, tx_id, [(fun, -2000), (home, -3000)])
    assert con.execute("SELECT is_split_parent FROM transactions WHERE id=?",
                       (tx_id,)).fetchone()[0] == 1
```

Also test that re-splitting replaces the old splits rather than appending, and that deleting the parent cascades.

Commit.

---

## Task 18: `cctrack split`

```
cctrack split 412 --into fun=24.99 --into home=35.01 --note "amazon order"
```

Also accept `--into fun=24.99 --into home=rest` where `rest` takes the remainder — this is the common case and doing arithmetic by hand at the CLI is annoying. Commit.

---

## Task 19: Split-aware category totals

`category_totals(con, month)` must count split children, not the parent, whenever `is_split_parent=1`. Get this wrong and every report silently double-counts.

```python
def test_split_parent_not_double_counted():
    # one $50 tx split 20/30 → totals show fun=20, home=30, and NOT uncategorized=50
```

Commit. **Phase D done.**

---

## Task 20: Plan setting

```
cctrack plan set 2026-08 --total 3200
cctrack plan set 2026-08 --category groceries=600 --category fun=200
cctrack plan show 2026-08
```

Writes to the `plan` table. If a month has no plan, `cctrack plan copy 2026-07 2026-08`. Commit.

---

## Task 21: Burn report

`cctrack/report.py` → `burn(con, month) -> BurnReport` with `spent_cents`, `planned_cents`, `by_category`, `days_elapsed`, `days_in_month`, and `pace_cents` (planned × elapsed/total).

Excludes `income` and `transfer` categories — a paycheque is not negative burn, and a card payment is not spending. Test that explicitly, it is the classic budget-tracker lie.

`cctrack report 2026-08` prints a table with a `+?` marker on the uncategorized total when it is non-zero, so an unknown chunk is visible rather than silently rolled into the number.

Commit.

---

## Task 22: The one chart

**Files:** `cctrack/chart.py`

One chart, one truth: **cumulative spend this month vs. the straight-line plan pace.**

- x-axis: day of month, 1 → last day.
- Solid line: cumulative actual spend, stopping at today (do not draw the future as zero — that is the lie every budget app tells).
- Dashed line: plan pace from 0 to the month's planned total.
- Shaded band between them, red when actual is above pace, green when below.
- A single annotation: projected month-end at the current rate.
- No pie chart. No sparkline grid. No second axis.

```
cctrack chart 2026-08 --out chart.png
```

Test: assert the file is written and non-empty, and that `cumulative_series()` (the pure function behind it) returns the right numbers for a known set of transactions. Don't try to assert on pixels.

Commit.

---

## Validation

Per task: `nix develop -c pytest tests/test_<area>.py -v`
Full suite: `nix develop -c pytest -q`
Real end-to-end, run manually after Task 11 and again after Task 22:

```bash
nix develop -c cctrack sync
nix develop -c cctrack categorize
nix develop -c cctrack review
nix develop -c cctrack report 2026-08
nix develop -c cctrack chart 2026-08 --out /tmp/chart.png
```

---

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| CIBC changes their DOM | high, guaranteed eventually | selectors isolated in one module + documented; CSV import path always works as a manual fallback |
| Bot detection / account lockout | high | persistent context, human-speed delays, run once daily and no more, never retry a failed login automatically |
| `BW_SESSION` expiry breaks cron | medium | detect and fail loudly with the unlock command in the message; decide policy with the user in Task 16 |
| 2FA is push-to-app, not SMS | medium | Task 8's probe reveals this early; fall back to an interactive prompt |
| Amount sign confusion (refunds, payments) | medium | integer cents throughout, one convention (negative = out) asserted in parser tests |
| Double-counting splits in reports | medium | Task 19 exists purely to prevent this |
| Scraping ToS | — | user's own data, personal use, low volume. Their call. |

## Open questions

1. Which Bitwarden item holds the CIBC login (exact name)?
2. Which cards/accounts — just the one credit card, or debit too?
3. Does CIBC 2FA reach you by SMS (visible in Beeper) or through their app?
4. How far back should the first backfill go? CIBC's web download usually caps at ~18 months; older data needs PDF eStatements, which is a separate and much worse problem.
5. Cron behaviour when Bitwarden is locked — skip sync quietly, or shout?
