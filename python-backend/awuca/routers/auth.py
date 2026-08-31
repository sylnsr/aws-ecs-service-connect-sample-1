"""Purpose 2: authenticate and authorise for N accounts.

The x-account-count header is the interesting part. It is read here, at token
issue, and baked into both the token and the seeded customer document -- not
consulted per request. Two reasons:

  * A caller could otherwise change how many accounts they can see by editing
    a header on any request, which is not authorisation.
  * The seed has to be written exactly once. Re-seeding on every request would
    discard every write the customer had made.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Header

from ..config import get_settings
from ..errors import bad_request
from ..models import TokenRequest
from ..security import issue_token
from ..seed import build_customer
from ..store import get_store

router = APIRouter(tags=["auth"])


@router.post("/v1/auth/token")
def create_token(
    body: TokenRequest,
    x_account_count: Annotated[str | None, Header()] = None,
) -> dict:
    settings = get_settings()
    maximum = settings.max_account_count

    # Parsed by hand rather than typed as `int` on the signature: FastAPI would
    # turn a bad value into a 422 with pydantic's list body, and the collection
    # documents a flat 400 here.
    if x_account_count is None or x_account_count.strip() == "":
        account_count = 3
    else:
        try:
            account_count = int(x_account_count)
        except ValueError:
            raise bad_request(f"x-account-count must be an integer between 1 and {maximum}") from None

    if not 1 <= account_count <= maximum:
        raise bad_request(f"x-account-count must be an integer between 1 and {maximum}")

    store = get_store()
    document = store.get(body.customerId)

    if document is None:
        document = build_customer(body.customerId, account_count)
        store.put(body.customerId, document)
    elif document["accountCount"] != account_count:
        # An existing customer asking for a different account count. Reseeding
        # would destroy their data; ignoring it silently would make the
        # x-account-count contract a lie. Refuse and say why.
        raise bad_request(
            f"Customer {body.customerId} already exists with "
            f"{document['accountCount']} accounts; use a new customerId to change the count"
        )

    token, expires_in = issue_token(body.customerId, account_count)

    return {
        "accessToken": token,
        "tokenType": "Bearer",
        "expiresIn": expires_in,
        "accountCount": account_count,
        "scope": "billing:read balance:read payments:write loyalty:write",
    }
