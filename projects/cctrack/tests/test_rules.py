"""Rules, categories and the learning loop.

Merchant strings here are real ones from the downloaded history, because the
derivation is only as good as the shapes it was built against.
"""

from __future__ import annotations

import pytest

from cctrack import categories, rules
from cctrack.categorize import (
    categorize,
    propose_rule,
    set_category,
    tag_and_learn,
)
from cctrack.db import connect
from cctrack.ingest.importer import ensure_account, import_csv
from cctrack.rules import Rule, add_rule, derive_pattern, match, would_match


@pytest.fixture
def con(tmp_path):
    c = connect(tmp_path / "t.db")
    categories.seed(c)
    return c


def rule(id_, pattern, category_id=1, priority=100, origin="seed"):
    return Rule(id_, pattern, category_id, priority, origin)


# --- categories -----------------------------------------------------------


def test_seed_creates_the_starter_set(con):
    assert categories.count(con) == len(categories.seed_names())
    assert categories.by_name(con, "groceries") is not None


def test_seeding_twice_adds_nothing(con):
    assert categories.seed(con) == 0


def test_names_are_case_insensitive(con):
    """'Fun' and 'fun' as separate rows would split a category's totals."""
    first = categories.add(con, "Fun")
    assert categories.add(con, "fun") == first
    assert categories.add(con, "FUN") == first


def test_empty_name_is_rejected(con):
    with pytest.raises(ValueError, match="cannot be empty"):
        categories.add(con, "   ")


# --- matching -------------------------------------------------------------


def test_lowest_priority_number_wins():
    hit = match("AMZN Mktp CA", [
        rule(1, "^AMZN", 10, priority=100),
        rule(2, "^AMZN", 20, priority=5),
    ])
    assert hit.category_id == 20


def test_ties_go_to_the_older_rule():
    hit = match("AMZN", [rule(9, "^AMZN", 90), rule(2, "^AMZN", 20)])
    assert hit.id == 2


def test_no_match_returns_none():
    assert match("SOMETHING ELSE", [rule(1, "^AMZN", 10)]) is None


def test_a_broken_regex_does_not_break_the_others():
    """One bad learned rule must not stop categorization for everything else."""
    hit = match("AMZN Mktp CA", [
        rule(1, "^[unclosed", 10, priority=1),
        rule(2, "^AMZN", 20, priority=2),
    ])
    assert hit.category_id == 20


def test_matching_is_case_insensitive():
    assert match("amzn mktp ca", [rule(1, "^AMZN", 10)]) is not None


# --- pattern derivation, against real merchant strings --------------------


@pytest.mark.parametrize(("description", "expected_stem"), [
    ("HAMER'S COFFEE TORONTO, ON", "HAMER'S COFFEE"),
    ("7 ELEVEN STORE #25339 TORONTO, ON", "7 ELEVEN STORE"),
    ("FRESHCO #3820 TORONTO, ON", "FRESHCO"),
    ("SHOPPERS DRUG MART #12 TORONTO, ON", "SHOPPERS DRUG MART"),
    ("AMZN Mktp CA*132DP4PV3 WWW.AMAZON.CA, ON", "AMZN Mktp CA"),
    ("BELL MOBILITY VERDUN, QC", "BELL MOBILITY"),
])
def test_derivation_strips_the_parts_that_vary(description, expected_stem):
    import re
    assert derive_pattern(description) == f"^{re.escape(expected_stem)}"


def test_uber_eats_and_uber_trip_stay_separate():
    """505 rows are restaurants and 403 are transit; a stem of 'UBER' merges them."""
    eats = derive_pattern("UBER CANADA/UBEREATS TORONTO, ON")
    trip = derive_pattern("UBER CANADA/UBERTRIP TORONTO, ON")
    assert eats != trip
    assert "UBEREATS" in eats and "UBERTRIP" in trip


def test_a_merchant_name_after_a_star_is_not_eaten():
    """Regression: '*AGENDA' looked like an order ref and left the stem 'SQ CAFE'.

    Order references contain digits; merchant names generally do not.
    """
    assert "AGENDA" in derive_pattern("SQ *AGENDA CAFE TORONTO, ON")


def test_bank_prefixes_are_stripped_so_the_merchant_is_reachable():
    """Debit rows bury the merchant behind boilerplate and a reference number."""
    derived = derive_pattern(
        "Point of Sale - Interac RETAIL PURCHASE 532001001047 FRESHCO #3820"
    )
    assert derived is not None
    assert "FRESHCO" in derived


def test_foreign_currency_tails_are_stripped():
    derived = derive_pattern("UBER *TRIP HELP.UBER.COM 5.20 EUR @ 1.456789")
    assert "EUR" not in derived


def test_a_dangerously_short_stem_is_refused():
    """'SQ' matches 639 unrelated Square merchants in the real history.

    These reduce to a two- or three-character stem once the store number and
    city come off, which as a prefix would swallow whole categories.
    """
    assert derive_pattern("SQ *1234567 TORONTO, ON") is None
    assert derive_pattern("A&W TORONTO, ON") is None
    assert derive_pattern("KFC #1234 TORONTO, ON") is None


def test_a_stem_at_the_length_limit_is_allowed():
    """The guard must not reject legitimate short merchant names outright."""
    assert derive_pattern("METRO TORONTO, ON") is not None


# --- would_match: the safety number ---------------------------------------


def test_would_match_counts_before_committing(con):
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, (
        "2026-06-01,HAMER'S COFFEE TORONTO,4.50,\n"
        "2026-06-02,HAMER'S COFFEE TORONTO,5.00,\n"
        "2026-06-03,FRESHCO #3820 TORONTO,80.00,\n"
    ))
    assert would_match(con, "^HAMER'S COFFEE") == 2
    assert would_match(con, "^FRESHCO") == 1


def test_would_match_rejects_a_bad_regex(con):
    with pytest.raises(ValueError, match="invalid regex"):
        would_match(con, "^[unclosed")


# --- categorize -----------------------------------------------------------


def test_categorize_applies_rules(con):
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, (
        "2026-06-01,HAMER'S COFFEE TORONTO,4.50,\n"
        "2026-06-02,FRESHCO #3820 TORONTO,80.00,\n"
    ))
    coffee = categories.by_name(con, "restaurants").id
    add_rule(con, "^HAMER'S COFFEE", coffee, origin="seed")

    result = categorize(con)
    assert result.categorized == 1
    assert result.remaining == 1


def test_categorize_never_overwrites_a_manual_choice(con):
    """A human decision outranks a pattern, always."""
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, "2026-06-01,HAMER'S COFFEE TORONTO,4.50,\n")
    tx_id = con.execute("SELECT id FROM transactions").fetchone()["id"]

    chosen = categories.by_name(con, "fun").id
    other = categories.by_name(con, "restaurants").id
    set_category(con, tx_id, chosen)
    add_rule(con, "^HAMER'S COFFEE", other, origin="seed")

    categorize(con)
    row = con.execute(
        "SELECT category_id, category_source FROM transactions WHERE id = ?", (tx_id,)
    ).fetchone()
    assert row["category_id"] == chosen
    assert row["category_source"] == "manual"


def test_categorize_is_idempotent(con):
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, "2026-06-01,HAMER'S COFFEE TORONTO,4.50,\n")
    add_rule(con, "^HAMER'S", categories.by_name(con, "restaurants").id)

    assert categorize(con).categorized == 1
    assert categorize(con).categorized == 0


def test_the_first_matching_rule_wins_not_the_last(con):
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, "2026-06-01,HAMER'S COFFEE TORONTO,4.50,\n")
    wanted = categories.by_name(con, "restaurants").id
    add_rule(con, "^HAMER", wanted, priority=1)
    add_rule(con, "COFFEE", categories.by_name(con, "fun").id, priority=50)

    categorize(con)
    assert con.execute(
        "SELECT category_id FROM transactions"
    ).fetchone()["category_id"] == wanted


# --- the learning loop ----------------------------------------------------


def test_tagging_one_charge_clears_the_rest(con):
    """The whole point: tag one Amazon charge, every Amazon charge clears."""
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, (
        "2026-06-01,AMZN Mktp CA*132DP4PV3 WWW.AMAZON.CA,25.00,\n"
        "2026-06-02,AMZN Mktp CA*RIN4D2913 WWW.AMAZON.CA,31.50,\n"
        "2026-06-03,AMZN Mktp CA*9K2LM0Q41 WWW.AMAZON.CA,12.00,\n"
        "2026-06-04,FRESHCO #3820 TORONTO,80.00,\n"
    ))
    first = con.execute(
        "SELECT id FROM transactions WHERE description LIKE 'AMZN%' ORDER BY id"
    ).fetchone()["id"]

    home = categories.by_name(con, "home").id
    cleared, proposal = tag_and_learn(con, first, home)

    assert proposal.matches_pending == 3
    assert cleared == 3, "the tagged charge plus the two the rule then cleared"
    assert con.execute(
        "SELECT count(*) n FROM transactions WHERE category_id IS NULL"
    ).fetchone()["n"] == 1, "the unrelated grocery charge is untouched"


def test_the_predicted_count_matches_what_is_applied(con):
    """If the number shown before saving is wrong, the safety check is theatre."""
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, "".join(
        f"2026-06-{d:02d},HAMER'S COFFEE TORONTO,4.50,\n" for d in range(1, 8)
    ))
    tx_id = con.execute("SELECT id FROM transactions ORDER BY id").fetchone()["id"]

    predicted = propose_rule(con, "HAMER'S COFFEE TORONTO").matches_pending
    cleared, _ = tag_and_learn(con, tx_id, categories.by_name(con, "restaurants").id)
    assert cleared == predicted


def test_tagging_without_learning_touches_only_one(con):
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, "".join(
        f"2026-06-{d:02d},HAMER'S COFFEE TORONTO,4.50,\n" for d in range(1, 4)
    ))
    tx_id = con.execute("SELECT id FROM transactions ORDER BY id").fetchone()["id"]

    cleared, _ = tag_and_learn(
        con, tx_id, categories.by_name(con, "restaurants").id, save_rule=False
    )
    assert cleared == 1
    assert not rules.all_rules(con)


def test_a_charge_with_no_safe_pattern_still_tags(con):
    """Refusing to learn must not stop the human from categorizing."""
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, "2026-06-01,A&W,12.00,\n")
    tx_id = con.execute("SELECT id FROM transactions").fetchone()["id"]

    cleared, proposal = tag_and_learn(
        con, tx_id, categories.by_name(con, "restaurants").id
    )
    assert proposal is None
    assert cleared == 1
    assert not rules.all_rules(con)


def test_learned_rules_are_marked_as_learned(con):
    acct = ensure_account(con, "VISA", "credit")
    import_csv(con, acct, "2026-06-01,HAMER'S COFFEE TORONTO,4.50,\n")
    tx_id = con.execute("SELECT id FROM transactions").fetchone()["id"]
    tag_and_learn(con, tx_id, categories.by_name(con, "restaurants").id)

    (learned,) = rules.all_rules(con)
    assert learned.origin == "learned"


def test_tagging_a_missing_transaction_is_an_error(con):
    with pytest.raises(ValueError, match="no transaction"):
        tag_and_learn(con, 9999, 1)
