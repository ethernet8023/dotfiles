"""Importer tests: dedup must never lose a real transaction or keep a dupe."""

from __future__ import annotations

from cctrack.db import connect
from cctrack.ingest.cibc_csv import parse_csv
from cctrack.ingest.importer import (
    assign_ordinals,
    ensure_account,
    fingerprint,
    import_csv,
    import_transactions,
)

SAMPLE = (
    "2026-06-01,COFFEE SHOP,4.50,,4500********0000\n"
    "2026-06-02,GROCERY STORE,89.12,,4500********0000\n"
    "2026-06-03,PAYMENT THANK YOU,,200.00,4500********0000\n"
)


def db(tmp_path):
    con = connect(tmp_path / "t.db")
    return con, ensure_account(con, "CIBC VISA", "credit", "0000")


# --- accounts -------------------------------------------------------------


def test_ensure_account_is_idempotent(tmp_path):
    con, first = db(tmp_path)
    assert ensure_account(con, "CIBC VISA", "credit", "0000") == first
    assert con.execute("SELECT count(*) FROM accounts").fetchone()[0] == 1


# --- the dedup guarantee --------------------------------------------------


def test_importing_twice_adds_nothing_the_second_time(tmp_path):
    con, acct = db(tmp_path)
    assert import_csv(con, acct, SAMPLE) == 3
    assert import_csv(con, acct, SAMPLE) == 0
    assert con.execute("SELECT count(*) FROM transactions").fetchone()[0] == 3


def test_two_identical_charges_on_one_day_both_land(tmp_path):
    """Two real coffees are not a duplicate. A naive hash would drop one."""
    con, acct = db(tmp_path)
    doubled = "2026-06-05,COFFEE,4.50,\n" * 2
    assert import_csv(con, acct, doubled) == 2


def test_a_third_identical_charge_lands_on_reimport(tmp_path):
    """The ordinal must not pin the count at whatever arrived first."""
    con, acct = db(tmp_path)
    import_csv(con, acct, "2026-06-05,COFFEE,4.50,\n" * 2)
    added = import_csv(con, acct, "2026-06-05,COFFEE,4.50,\n" * 3)
    assert added == 1
    assert con.execute("SELECT count(*) FROM transactions").fetchone()[0] == 3


def test_overlapping_windows_do_not_duplicate(tmp_path):
    """Chunked downloads overlap on purpose; dedup is what makes that safe."""
    con, acct = db(tmp_path)
    first = "2026-06-01,A,1.00,\n2026-06-02,B,2.00,\n"
    overlapping = "2026-06-02,B,2.00,\n2026-06-03,C,3.00,\n"
    assert import_csv(con, acct, first) == 2
    assert import_csv(con, acct, overlapping) == 1
    assert con.execute("SELECT count(*) FROM transactions").fetchone()[0] == 3


def test_repeated_charges_converge_instead_of_accumulating(tmp_path):
    """Regression: overlapping downloads must not multiply repeated charges.

    An earlier version numbered ordinals per batch, so importing overlapping
    windows inserted a fresh copy of the same charge each time -- 8,733 rows
    stored where the files held 6,211. Importing the same group repeatedly
    must converge on its true multiplicity.
    """
    con, acct = db(tmp_path)
    batch = "2026-06-05,COFFEE,4.50,\n" * 3

    assert import_csv(con, acct, batch) == 3
    for _ in range(4):
        assert import_csv(con, acct, batch) == 0
    assert con.execute("SELECT count(*) FROM transactions").fetchone()[0] == 3


def test_a_smaller_later_batch_does_not_delete_or_duplicate(tmp_path):
    """A window that happens to show fewer copies must be a no-op, not a change."""
    con, acct = db(tmp_path)
    import_csv(con, acct, "2026-06-05,COFFEE,4.50,\n" * 3)
    assert import_csv(con, acct, "2026-06-05,COFFEE,4.50,\n") == 0
    assert con.execute("SELECT count(*) FROM transactions").fetchone()[0] == 3


def test_chunked_and_whole_imports_agree(tmp_path):
    """Importing a period as many overlapping chunks must match one whole file."""
    whole = (
        "2026-06-01,A,1.00,\n"
        "2026-06-02,B,2.00,\n2026-06-02,B,2.00,\n"
        "2026-06-03,C,3.00,\n"
    )
    chunks = [
        "2026-06-01,A,1.00,\n2026-06-02,B,2.00,\n2026-06-02,B,2.00,\n",
        "2026-06-02,B,2.00,\n2026-06-02,B,2.00,\n2026-06-03,C,3.00,\n",
    ]

    con_a, acct_a = db(tmp_path / "a")
    import_csv(con_a, acct_a, whole)

    con_b, acct_b = db(tmp_path / "b")
    for chunk in chunks:
        import_csv(con_b, acct_b, chunk)

    def rows(con):
        return sorted(tuple(r) for r in con.execute(
            "SELECT posted_on, description, amount_cents FROM transactions"))

    assert rows(con_a) == rows(con_b)
    assert len(rows(con_a)) == 4


def test_file_order_does_not_change_fingerprints(tmp_path):
    """Importing a period as one file or several must produce the same rows."""
    con_a, acct_a = db(tmp_path / "a")
    con_b, acct_b = db(tmp_path / "b")

    whole = "2026-06-01,A,1.00,\n2026-06-02,B,2.00,\n2026-06-03,C,3.00,\n"
    import_csv(con_a, acct_a, whole)
    for line in reversed(whole.strip().splitlines()):
        import_csv(con_b, acct_b, line + "\n")

    fps_a = {r[0] for r in con_a.execute("SELECT fingerprint FROM transactions")}
    fps_b = {r[0] for r in con_b.execute("SELECT fingerprint FROM transactions")}
    assert fps_a == fps_b


def test_the_same_charge_on_two_accounts_is_kept_twice(tmp_path):
    con = connect(tmp_path / "t.db")
    visa = ensure_account(con, "VISA", "credit")
    chequing = ensure_account(con, "Chequing", "debit")
    row = "2026-06-01,TRANSFER,10.00,\n"
    assert import_csv(con, visa, row) == 1
    assert import_csv(con, chequing, row) == 1


# --- fingerprints ---------------------------------------------------------


def test_fingerprint_changes_with_every_identifying_field(tmp_path):
    (tx,) = parse_csv("2026-06-01,A,1.00,\n")
    base = fingerprint(1, tx, 0)
    (other,) = parse_csv("2026-06-01,A,2.00,\n")

    assert fingerprint(2, tx, 0) != base       # account
    assert fingerprint(1, tx, 1) != base       # ordinal
    assert fingerprint(1, other, 0) != base    # amount


def test_fingerprint_ignores_the_card_number(tmp_path):
    """A reissued card must not resurrect every past transaction."""
    (old,) = parse_csv("2026-06-01,A,1.00,,4500********1111\n")
    (new,) = parse_csv("2026-06-01,A,1.00,,4500********2222\n")
    assert fingerprint(1, old, 0) == fingerprint(1, new, 0)


def test_ordinals_count_identical_rows_only():
    txs = parse_csv(
        "2026-06-01,A,1.00,\n"
        "2026-06-01,A,1.00,\n"
        "2026-06-01,B,1.00,\n"
    )
    assert assign_ordinals(txs) == [0, 1, 0]


# --- stored values --------------------------------------------------------


def test_amounts_and_cards_are_stored(tmp_path):
    con, acct = db(tmp_path)
    import_csv(con, acct, SAMPLE)
    rows = con.execute(
        "SELECT description, amount_cents, card_last4 FROM transactions "
        "ORDER BY posted_on"
    ).fetchall()
    assert [r["amount_cents"] for r in rows] == [-450, -8912, 20000]
    assert {r["card_last4"] for r in rows} == {"0000"}


def test_importing_nothing_is_not_an_error(tmp_path):
    con, acct = db(tmp_path)
    assert import_transactions(con, acct, []) == 0


# --- channel --------------------------------------------------------------


CHANNELLED = (
    "2026-06-01,Point of Sale - Interac RETAIL PURCHASE 1 SHOP,10.00,\n"
    "2026-06-02,Automated Banking Machine ATM WITHDRAWAL COLLEGE,20.00,\n"
    "2026-06-03,Internet Banking E-TRANSFER 999 someone,30.00,\n"
)


def test_the_channel_is_stored(tmp_path):
    con, acct = db(tmp_path)
    import_csv(con, acct, CHANNELLED)
    stored = [
        r["channel"] for r in con.execute(
            "SELECT channel FROM transactions ORDER BY posted_on"
        )
    ]
    assert stored == ["interac_pos", "abm", "online_banking"]


def test_a_visa_row_stores_no_channel(tmp_path):
    con, acct = db(tmp_path)
    import_csv(con, acct, "2026-06-01,TIM HORTONS #1 TORONTO ON,4.50,,4500****0000\n")
    assert con.execute("SELECT channel FROM transactions").fetchone()["channel"] is None


def test_adding_the_channel_did_not_change_any_fingerprint(tmp_path):
    """The channel must be derived, never part of a row's identity.

    Deriving it from the description means it cannot shift a fingerprint --
    but only as long as the description is stored untouched. If a later change
    trims the prefix out, this pins the resulting silent re-import.
    """
    (tx,) = parse_csv("2026-06-01,Branch Transaction SERVICE CHARGE,4.95,\n")
    assert tx.channel == "branch"
    assert fingerprint(1, tx, 0) == (
        "a86c9d5d700e2969b3b5175c41773149e41a2809af0f573eb7dddc9be7ab69e6"
    )


def test_reimporting_after_the_channel_landed_adds_nothing(tmp_path):
    con, acct = db(tmp_path)
    assert import_csv(con, acct, CHANNELLED) == 3
    assert import_csv(con, acct, CHANNELLED) == 0
