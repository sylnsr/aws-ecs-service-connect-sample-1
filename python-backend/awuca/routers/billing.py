"""Purpose 2 and 7: the billing statement.

PATH IS PINNED. edge/kvs/routing.yaml rewrites /bill to /v1/billing/statement.
Renaming this route means editing the rewrite table in the same change.
"""

from __future__ import annotations

from fastapi import APIRouter, Query

from ..deps import CurrentCustomer

router = APIRouter(tags=["billing"])


@router.get("/v1/billing/statement")
def get_statement(customer: CurrentCustomer, accountId: str = Query(...)) -> dict:
    customer.require_account(accountId)

    transactions = customer.document["transactions"][accountId]
    balance = customer.document["balances"][accountId]

    debits = [t for t in transactions if t["type"] == "debit"]
    credits = sum(t["amount"] for t in transactions if t["type"] == "credit")

    return {
        "accountId": accountId,
        "statementId": "stm-2026-08",
        "periodStart": "2026-07-01",
        "periodEnd": "2026-09-30",
        "currency": balance["currency"],
        "openingBalance": round(credits, 2),
        "closingBalance": balance["balance"],
        "lines": [
            {"description": t["description"], "amount": t["amount"]} for t in debits
        ],
    }
