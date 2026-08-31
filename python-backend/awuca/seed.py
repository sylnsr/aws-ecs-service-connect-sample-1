"""Deterministic seed data for a new customer.

THIS MODULE IS PART OF THE CONTRACT. The generated Playwright @contract suite
drives the saved examples from postman/awuca.postman_collection.json against a
freshly minted customer, so the starting state has to be exactly what those
examples describe:

  * accounts acc-0001 .. acc-000N for x-account-count N; the last is `closed`
    when N >= 3 so the open/closed distinction in purpose 3 is observable
  * payment methods pm-0001 (card, default) and pm-0002 (direct debit)
  * loyalty: acc-0001 ENROLLED, acc-0002 NOT
  * closure: acc-0001 Pending, acc-0002 none

The asymmetry between acc-0001 and acc-0002 is not arbitrary. Each endpoint
that documents both a success and a not-found example needs two accounts in
different states, or one of the two examples could never be satisfied. See
"Satisfiability" in playwright-tests/README.md.

Changing this seed breaks the contract suite. That is intended: the seed and
the collection are two halves of one statement.
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timezone
from typing import Any

ENROLLED_ACCOUNT = "acc-0001"
UNENROLLED_ACCOUNT = "acc-0002"

_CITY = "Doloropolis"
_REGION = "Ametshire"


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def account_id(index: int) -> str:
    return f"acc-{index:04d}"


def loyalty_id_for(customer_id: str, account: str) -> str:
    """Stable per (customer, account) so a restart does not reissue a new id.

    A random id would make the YAML store and the DynamoDB store disagree after
    a redeploy, which is exactly the kind of thing the blue/green rehearsal is
    supposed to surface rather than manufacture.
    """
    digest = hashlib.sha256(f"{customer_id}:{account}".encode()).hexdigest()
    return f"LOY-{digest[:6].upper()}"


def _address(line1: str, line2: str | None, postcode: str) -> dict[str, Any]:
    return {
        "line1": line1,
        "line2": line2,
        "city": _CITY,
        "region": _REGION,
        "postalCode": postcode,
        "country": "GB",
    }


_LABELS = [
    "Lorem Ipsum Residence",
    "Dolor Sit Workshop",
    "Amet Consectetur Annex",
    "Adipiscing Elit Depot",
    "Sed Eiusmod Cottage",
    "Tempor Incididunt Mill",
    "Labore Dolore Barn",
    "Magna Aliqua Lodge",
    "Enim Minim Yard",
    "Veniam Quis Store",
]


def build_customer(customer_id: str, account_count: int) -> dict[str, Any]:
    now = _now_iso()

    accounts = []
    addresses: dict[str, Any] = {}
    balances: dict[str, Any] = {}
    transactions: dict[str, Any] = {}

    for index in range(1, account_count + 1):
        acct = account_id(index)
        # Purpose 3 needs both statuses to be visible. With fewer than three
        # accounts every account stays open rather than closing the only one
        # the caller has.
        status = "closed" if (account_count >= 3 and index == account_count) else "open"

        accounts.append(
            {
                "accountId": acct,
                "label": _LABELS[(index - 1) % len(_LABELS)],
                "status": status,
                "serviceType": "water",
            }
        )
        addresses[acct] = _address(f"{index * 12} Lorem Street", "Ipsum Quarter", f"LI{index} 2PS")
        balances[acct] = {
            "accountId": acct,
            "currency": "GBP",
            "balance": round(42.5 + index, 2),
            "status": "due",
            "dueDate": "2026-09-30",
        }
        transactions[acct] = [
            {
                "transactionId": f"txn-{index:04d}-3",
                "date": "2026-08-01",
                "type": "debit",
                "amount": 32.5,
                "description": "Lorem ipsum water supply",
            },
            {
                "transactionId": f"txn-{index:04d}-2",
                "date": "2026-07-15",
                "type": "credit",
                "amount": 20.0,
                "description": "Dolor sit amet payment received",
            },
            {
                "transactionId": f"txn-{index:04d}-1",
                "date": "2026-07-01",
                "type": "debit",
                "amount": 30.0,
                "description": "Consectetur adipiscing wastewater",
            },
        ]

    payment_methods = [
        {
            "methodId": "pm-0001",
            "type": "card",
            "label": "Lorem card ending 4242",
            "default": True,
            "billingAddress": _address("12 Lorem Street", "Ipsum Quarter", "LI1 2PS"),
        },
        {
            "methodId": "pm-0002",
            "type": "direct_debit",
            "label": "Ipsum Bank ending 1234",
            "default": False,
            "billingAddress": _address("9 Dolor Way", None, "LI3 4TX"),
        },
    ]

    loyalty: dict[str, Any] = {}
    closures: dict[str, Any] = {}

    # Only seed the acc-0001 states if that account actually exists, which it
    # always does for account_count >= 1.
    if account_count >= 1:
        loyalty[ENROLLED_ACCOUNT] = {
            "loyaltyId": loyalty_id_for(customer_id, ENROLLED_ACCOUNT),
            "accountId": ENROLLED_ACCOUNT,
            "status": "active",
            "points": 120,
            "enrolledAt": now,
        }
        closures[ENROLLED_ACCOUNT] = {
            "accountId": ENROLLED_ACCOUNT,
            "closureRequestId": "clo-0001",
            "status": "Pending",
            "reason": "Lorem ipsum relocation",
            "requestedAt": now,
            "effectiveDate": "2026-09-30",
        }

    return {
        "customerId": customer_id,
        "accountCount": account_count,
        "accounts": accounts,
        "addresses": addresses,
        "balances": balances,
        "transactions": transactions,
        "paymentMethods": payment_methods,
        "loyalty": loyalty,
        "closures": closures,
        "nextMethodSeq": 3,
        "nextClosureSeq": 2,
    }
