"""Purposes 3, 4, 7 and 8: accounts, address, payment history, closure."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, status

from ..deps import CurrentCustomer
from ..errors import not_found
from ..models import ClosureRequest

router = APIRouter(tags=["accounts"])


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@router.get("/v1/accounts")
def list_accounts(customer: CurrentCustomer) -> dict:
    """Purpose 3. The list is exactly as long as the x-account-count used at
    token issue."""
    accounts = customer.document["accounts"]
    return {"accounts": accounts, "count": len(accounts)}


@router.get("/v1/accounts/{account_id}/address")
def get_address(account_id: str, customer: CurrentCustomer) -> dict:
    """Purpose 4. Read-only: there is no write verb on this path, and the
    @stateful suite asserts that PUT/POST/PATCH/DELETE stay unrouted."""
    customer.require_account(account_id)
    return {
        "accountId": account_id,
        "readOnly": True,
        "address": customer.document["addresses"][account_id],
    }


@router.get("/v1/accounts/{account_id}/balance")
def get_balance(account_id: str, customer: CurrentCustomer) -> dict:
    customer.require_account(account_id)
    return customer.document["balances"][account_id]


@router.get("/v1/accounts/{account_id}/payments")
def get_payment_history(account_id: str, customer: CurrentCustomer) -> dict:
    """Purpose 7. Debits and credits in one list, newest first."""
    customer.require_account(account_id)
    transactions = customer.document["transactions"][account_id]
    return {
        "accountId": account_id,
        "currency": "GBP",
        "count": len(transactions),
        "transactions": transactions,
    }


@router.post("/v1/accounts/{account_id}/closure", status_code=status.HTTP_202_ACCEPTED)
def request_closure(account_id: str, body: ClosureRequest, customer: CurrentCustomer) -> dict:
    """Purpose 8, write half. 202 because closure is asynchronous in the story
    the collection tells -- the status is Pending and nothing completes it."""
    customer.require_account(account_id)

    existing = customer.document["closures"].get(account_id)
    if existing is not None:
        # Re-requesting is not an error; return the request already in flight
        # so a retry is safe.
        return existing

    sequence = customer.document["nextClosureSeq"]
    closure = {
        "accountId": account_id,
        "closureRequestId": f"clo-{sequence:04d}",
        "status": "Pending",
        "reason": body.reason,
        "requestedAt": _now_iso(),
        "effectiveDate": body.effectiveDate,
    }
    customer.document["closures"][account_id] = closure
    customer.document["nextClosureSeq"] = sequence + 1
    customer.save()

    return closure


@router.get("/v1/accounts/{account_id}/closure")
def get_closure_status(account_id: str, customer: CurrentCustomer) -> dict:
    """Purpose 8, read half. Always Pending -- nothing in this demo advances
    a closure past that."""
    customer.require_account(account_id)

    closure = customer.document["closures"].get(account_id)
    if closure is None:
        raise not_found("No closure request exists for this account")
    return closure
