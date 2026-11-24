# CIBC transaction download

Harvested live from `#/accounts/download`, reachable via the **`Download
Transactions` link** (an `<a>`, not a `<button>` — a button-only search finds
nothing) present on both the accounts home and each account detail page.

URL: `https://www.cibconline.cibc.com/ebm-resources/public/banking/cibc/client/web/index.html#/accounts/download`

## Controls

| control | options |
| --- | --- |
| account `<select>` | `Choose an account`, `Chequing (…)`, `Savings (…)`, `CIBC VISA (…)` — labels include the masked number and current balance |
| criteria radio `name="criteria"` | `LAST_DOWNLOAD`, `ALL_AVAILABLE`, `DATE_RANGE` |
| from date | three `<select>`: month name, day, year |
| to date | three `<select>`: month name, day, year |
| software `<select>` | `Choose your software`, `Microsoft Money`, `Intuit QuickBooks`, `Quicken`, `Sage 50`, `Spreadsheet (CSV)` |

Month selects use full English names (`January`…`December`). The year list is
finite — read it rather than assuming a range.

## Criteria: measured, not assumed

| criteria | result |
| --- | --- |
| `ALL_AVAILABLE` | **fails** — `{Result #0001}`, routes to `#/accounts/error` |
| `DATE_RANGE`, 30 / 180 / 380 days | **works**, returns `cibc.csv` |
| `LAST_DOWNLOAD` | "no transactions to display" once consumed |

So cctrack always uses `DATE_RANGE`, even for the backfill. Two reasons, and
only the first was anticipated:

1. `LAST_DOWNLOAD` is **server-side stateful** — CIBC marks a window consumed
   whether or not our import succeeded, so a crash loses those transactions
   permanently. `DATE_RANGE` is idempotent, safe to overlap, and the importer's
   fingerprint dedup drops repeats.
2. `ALL_AVAILABLE` is simply **broken** for a credit card. It is on the form and
   it does not work.

## How far back it goes

Two separate limits, and conflating them cost a while:

**Response size** caps a *single* request at roughly two years. Measured:

| window | result |
| --- | --- |
| 400d / 500d / 730d | ok (2523 / 2953 / 3894 rows) |
| 1100d | download never arrives |
| 1825d | browser dies |

`download_range()` slices any span into 31-day chunks, which removes this
ceiling entirely — 26 chunks returned 4162 rows with zero gaps.

**Retention** is the real floor, found by probing one month per period:

| probe | result |
| --- | --- |
| 2019-06, 2021-06, 2022-06, 2022-09 | fails |
| **2022-12** | 124 rows ✓ |
| 2023-02 / 2023-04 / 2023-06 | ok |

So history reaches back to somewhere between **2022-09 and 2022-12** — about
three years, not the "13 months" the page claims. `HISTORY_DAYS = 400` is only
a default for routine runs; pass an explicit `--since` to reach the floor.

A request below the floor does not error cleanly, it simply never produces a
download and burns the full 120s timeout. That is why a naive sweep from 2019
is unusably slow, and why chunk failures are reported and skipped rather than
retried.

## The submit button

A `<button type=submit>` measuring **0×0**, hidden under a
`<div class="ui-wrapper">` 191×40 that receives the click. Same pattern as the
criteria radios, which also cannot be `.check()`ed directly — click the
`<label>` instead. Any "element intercepts pointer events" error on this site
is this pattern.

## CSV format: verified against real downloads

Headerless, but **the column count depends on the account type**:

| account | rows (13mo) | columns |
| --- | --- | --- |
| VISA | 2523 | `date,description,debit,credit,card` |
| Chequing | 533 | `date,description,debit,credit` |
| Savings | ~20 | `date,description,debit,credit` |

- `date` is ISO `YYYY-MM-DD`.
- Exactly one of `debit`/`credit` is populated; the other is empty.
- Descriptions **contain commas** and are quoted, e.g.
  `"TST-RUDY College Toronto, ON"` — use a real CSV reader, never `split(",")`.
- The card column, when present, is masked: `4500********1234`.

A parser hardcoding five columns crashes on chequing; one hardcoding four
silently drops the card number on VISA. Handle both widths.
