"""CSV parser tests. Fixtures are real rows from the downloaded history,
with amounts and card numbers altered.
"""

from __future__ import annotations

import pytest

from cctrack.ingest.cibc_csv import ParseError, parse_csv

VISA_ROW = "2026-06-03,TIM HORTONS #1234 TORONTO ON,12.34,,4500********0000\n"
CHEQUING_ROW = "2026-06-05,Branch Transaction SERVICE CHARGE,4.95,\n"


# --- shape ----------------------------------------------------------------


def test_parses_a_five_column_visa_row():
    (tx,) = parse_csv(VISA_ROW)
    assert tx.posted_on == "2026-06-03"
    assert tx.description == "TIM HORTONS #1234 TORONTO ON"
    assert tx.amount_cents == -1234
    assert tx.card_last4 == "0000"


def test_parses_a_four_column_chequing_row():
    """Chequing and Savings have no card column; assuming five would crash."""
    (tx,) = parse_csv(CHEQUING_ROW)
    assert tx.amount_cents == -495
    assert tx.card_last4 is None


def test_credit_is_positive():
    (tx,) = parse_csv("2026-06-05,PAYMENT THANK YOU,,150.00,4500********0000\n")
    assert tx.amount_cents == 15000


def test_debit_is_negative():
    (tx,) = parse_csv(VISA_ROW)
    assert tx.amount_cents < 0


def test_blank_lines_are_skipped():
    assert len(parse_csv(f"\n{VISA_ROW}\n\n{CHEQUING_ROW}")) == 2


# --- money ----------------------------------------------------------------


def test_amounts_are_exact_cents_not_floats():
    """float('12.34') * 100 is 1233.9999...; Decimal keeps it exact."""
    for raw, expected in (("12.34", -1234), ("0.01", -1), ("1999.99", -199999)):
        (tx,) = parse_csv(f"2026-01-01,X,{raw},\n")
        assert tx.amount_cents == expected


def test_amount_is_an_integer_type():
    (tx,) = parse_csv(VISA_ROW)
    assert isinstance(tx.amount_cents, int)


def test_thousands_separators_are_rejected_loudly():
    """An unquoted 1,234.56 splits across columns; refuse rather than read 1.

    CIBC quotes such amounts, so this is a guard against a malformed file, not
    a case seen in the real history.
    """
    with pytest.raises(ParseError, match="exactly one of debit/credit"):
        parse_csv("2026-01-01,BIG,1,234.56,\n")


def test_quoted_thousands_separators_parse_exactly():
    (tx,) = parse_csv('2026-01-01,BIG,"1,234.56",\n')
    assert tx.amount_cents == -123456


# --- the malformed rows CIBC actually emits -------------------------------


REAL_BROKEN_ROW = (
    '2023-11-14,"TOYS "R" US #1234 TORONTO, ON",45.67,,4500********0000\n'
)


def test_unescaped_inner_quotes_do_not_corrupt_the_amount():
    """Regression from real data: three rows in the history look like this.

    CIBC does not double the inner quotes, so a plain CSV reader ends the
    description early and reads the amount as ' ON' -- a silently wrong number
    in a money tool, which is worse than a crash.
    """
    (tx,) = parse_csv(REAL_BROKEN_ROW)
    assert tx.amount_cents == -4567
    assert "TOYS" in tx.description
    assert tx.card_last4 == "0000"


def test_commas_inside_a_quoted_description_are_preserved():
    (tx,) = parse_csv('2026-01-01,"TST-RUDY College Toronto, ON",10.00,\n')
    assert tx.description == "TST-RUDY College Toronto, ON"
    assert tx.amount_cents == -1000


def test_padded_descriptions_are_collapsed():
    (tx,) = parse_csv("2026-01-01,A    B     C,1.00,\n")
    assert tx.description == "A B C"


# --- rejection ------------------------------------------------------------


def test_rejects_wrong_column_count():
    with pytest.raises(ParseError, match="expected 4 or 5 columns"):
        parse_csv("a,b\n")


def test_rejects_a_bad_date():
    with pytest.raises(ParseError, match="bad date"):
        parse_csv("06/03/2026,X,1.00,\n")


def test_rejects_both_debit_and_credit():
    """Ambiguous sign: refuse rather than guess which one is real."""
    with pytest.raises(ParseError, match="exactly one of debit/credit"):
        parse_csv("2026-01-01,X,1.00,2.00\n")


def test_rejects_neither_debit_nor_credit():
    with pytest.raises(ParseError, match="exactly one of debit/credit"):
        parse_csv("2026-01-01,X,,\n")


def test_error_names_the_line_number():
    with pytest.raises(ParseError, match="line 2"):
        parse_csv(VISA_ROW + "2026-01-01,X,,\n")
