"""Parse CIBC transaction CSV exports.

Headerless, and the column count depends on the account type -- verified
against 134 real files, 7,860 rows:

    VISA               date,description,debit,credit,card
    Chequing/Savings   date,description,debit,credit

Exactly one of debit/credit is populated. Amounts are parsed via Decimal and
stored as integer cents; no float ever touches the money path.

Chequing and Savings descriptions additionally begin with a channel prefix
naming how the money moved; see CHANNEL_PREFIXES. VISA descriptions do not,
so a VISA row's channel is unknown rather than absent.
"""

from __future__ import annotations

import csv
import io
import re
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation

WHITESPACE_RUN = re.compile(r"\s+")

# How the money moved, keyed by the literal prefix CIBC writes at the start of
# a Chequing/Savings description. Checked longest-first, because the two
# point-of-sale prefixes share a stem.
#
# Verified closed against the full downloaded history: every one of the 2,314
# Chequing and Savings rows matches exactly one of these, none match two.
CHANNEL_PREFIXES: tuple[tuple[str, str], ...] = (
    ("Point of Sale - Visa Debit", "visa_debit_pos"),
    ("Point of Sale - Interac", "interac_pos"),
    ("Automated Banking Machine", "abm"),
    ("Electronic Funds Transfer", "eft"),
    ("Internet Banking", "online_banking"),
    ("Branch Transaction", "branch"),
)

CHANNELS = frozenset(channel for _, channel in CHANNEL_PREFIXES)

# Channels that require the physical card at a physical terminal. Visa Debit
# is excluded on purpose: the same prefix covers a tap at a shop and a card
# number typed into a website, and the export does not distinguish them.
CARD_PRESENT_CHANNELS = frozenset({"interac_pos", "abm"})


def channel_of(description: str) -> str | None:
    """Which channel a description names, or None if it names none.

    None means unknown, not 'no channel': VISA rows carry a bare merchant
    string with no prefix at all, so nothing can be concluded from them.
    """
    for prefix, channel in CHANNEL_PREFIXES:
        if description.startswith(prefix):
            return channel
    return None


class ParseError(ValueError):
    pass


@dataclass(frozen=True)
class ParsedTx:
    """One row. amount_cents is negative for money out, positive for money in."""

    posted_on: str  # ISO 'YYYY-MM-DD'
    description: str
    amount_cents: int
    card_last4: str | None
    channel: str | None = None  # None = the export does not say


def _money_to_cents(raw: str) -> int:
    """'12.34' -> 1234. Decimal, never float: 12.34 * 100 == 1233.9999... .

    Thousands separators are stripped: large amounts arrive quoted as
    "1,234.56", and Decimal rejects the comma.
    """
    cleaned = raw.strip().replace(",", "").replace("$", "")
    try:
        return int((Decimal(cleaned) * 100).to_integral_value())
    except (InvalidOperation, ArithmeticError) as exc:
        raise ParseError(f"unparseable amount {raw!r}") from exc


def _repair_unescaped_quotes(line: str) -> str:
    r'''Fix rows whose description contains an unescaped double quote.

    CIBC emits merchant names verbatim, so a name containing a quote produces
    a field like `"TOYS "R" US #1234 TORONTO, ON"`. The inner quotes should be
    doubled and are not, so a CSV reader ends the field at the second quote and
    every later column shifts left -- the amount is then read as `" ON"`.

    Three such rows exist in the current history. Left alone they do not fail
    loudly, they produce a wrong amount, so they are repaired rather than
    skipped: re-quote the inner quotes and let the normal reader handle it.
    '''
    if line.count('"') <= 2:
        return line

    first, last = line.index('"'), line.rindex('"')
    inner = line[first + 1:last].replace('"', '""')
    return f"{line[:first]}\"{inner}\"{line[last + 1:]}"


def parse_csv(text: str) -> list[ParsedTx]:
    """Parse CIBC CSV text. Raises ParseError on anything unexpected."""
    rows: list[ParsedTx] = []

    for lineno, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip():
            continue

        line = _repair_unescaped_quotes(raw_line)
        fields = next(csv.reader(io.StringIO(line)))

        if len(fields) == 4:
            posted_on, description, debit, credit = fields
            card = None
        elif len(fields) == 5:
            posted_on, description, debit, credit, card = fields
        else:
            raise ParseError(
                f"line {lineno}: expected 4 or 5 columns, got {len(fields)}: {fields!r}"
            )

        posted_on = posted_on.strip()
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", posted_on):
            raise ParseError(f"line {lineno}: bad date {posted_on!r}")

        debit, credit = debit.strip(), credit.strip()
        if bool(debit) == bool(credit):
            raise ParseError(
                f"line {lineno}: expected exactly one of debit/credit, "
                f"got debit={debit!r} credit={credit!r}"
            )

        # Debit is money out. Store the sign so later maths never has to guess.
        amount_cents = -_money_to_cents(debit) if debit else _money_to_cents(credit)

        # CIBC pads descriptions with runs of spaces.
        description = WHITESPACE_RUN.sub(" ", description).strip()

        rows.append(ParsedTx(
            posted_on=posted_on,
            # Stored verbatim: the description is part of a transaction's
            # fingerprint, so stripping the channel prefix out of it here
            # would change every existing row's identity and re-import the
            # entire history as new.
            description=description,
            amount_cents=amount_cents,
            card_last4=(card or "").strip()[-4:] or None,
            channel=channel_of(description),
        ))

    return rows
