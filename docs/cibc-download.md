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

History reaches back **13 months** ("Credit transactions dating back 13 months
from today's date", stated on the page). `HISTORY_DAYS = 400` covers it.

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
