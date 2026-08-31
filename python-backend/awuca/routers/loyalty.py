"""Purpose 6: loyalty programme enrolment.

WORKLOAD: this is the AWS LAMBDA half of the app. Per README section 2A every
route except loyalty is a mock ECS task; loyalty is the function. It is mounted
into the ECS app only for local single-process convenience -- see app.py.

PATHS ARE PINNED. edge/kvs/routing.yaml rewrites /join to /v1/loyalty/signup
and the legacy /v1/loyalty-program-11 to /v1/loyalty.

Enrolment is keyed by accountId, not by customer. That is load bearing: the
collection documents both an enrolled (200) and a not-enrolled (404) example
for GET /v1/loyalty, and two examples of one endpoint have to differ in their
REQUEST or no single backend state can satisfy both. Keying on accountId makes
them ?accountId=acc-0001 and ?accountId=acc-0002. See "Satisfiability" in
playwright-tests/README.md.
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Query, status

from ..deps import CurrentCustomer
from ..errors import not_found
from ..models import LoyaltySignupRequest
from ..seed import loyalty_id_for

router = APIRouter(tags=["loyalty"])


@router.post("/v1/loyalty/signup", status_code=status.HTTP_201_CREATED)
def signup(body: LoyaltySignupRequest, customer: CurrentCustomer) -> dict:
    """Set the loyalty ID.

    IDEMPOTENT: an already-enrolled account returns 201 with the existing
    enrolment rather than a 409. This is what keeps the collection's 201
    example satisfiable against seeded data where acc-0001 is already enrolled,
    and it makes the request safe to retry.
    """
    customer.require_account(body.accountId)

    existing = customer.document["loyalty"].get(body.accountId)
    if existing is not None:
        return existing

    enrolment = {
        "loyaltyId": loyalty_id_for(customer.customer_id, body.accountId),
        "accountId": body.accountId,
        "status": "active",
        "points": 0,
        "enrolledAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    customer.document["loyalty"][body.accountId] = enrolment
    customer.save()

    return enrolment


@router.get("/v1/loyalty")
def get_loyalty(customer: CurrentCustomer, accountId: str = Query(...)) -> dict:
    """Get the loyalty ID for one of the customer's accounts."""
    customer.require_account(accountId)

    enrolment = customer.document["loyalty"].get(accountId)
    if enrolment is None:
        raise not_found("This account is not enrolled in the loyalty programme")
    return enrolment
