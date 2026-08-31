"""Shared FastAPI dependencies."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import Depends, Header

from .errors import not_found, unauthorized
from .security import TokenError, decode_token
from .store import Store, get_store


@dataclass
class Customer:
    """The authenticated customer and their stored document.

    The document is loaded once per request and written back explicitly by any
    handler that changes it. There is no dirty tracking -- a handler that
    forgets to call `save()` silently loses the write, which the @stateful
    round-trip tests are there to catch.
    """

    customer_id: str
    document: dict[str, Any]
    store: Store

    def save(self) -> None:
        self.store.put(self.customer_id, self.document)

    def require_account(self, account_id: str) -> dict[str, Any]:
        for account in self.document["accounts"]:
            if account["accountId"] == account_id:
                return account
        raise not_found("No such account for this customer")


def current_customer(
    authorization: Annotated[str | None, Header()] = None,
) -> Customer:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise unauthorized()

    token = authorization.split(" ", 1)[1].strip()
    try:
        claims = decode_token(token)
    except TokenError:
        # Deliberately flat: the client learns the token is unusable, not why.
        raise unauthorized() from None

    store = get_store()
    document = store.get(claims.customer_id)
    if document is None:
        # The token is validly signed but the customer is gone -- possible if
        # the store was wiped between requests. Treat as unauthenticated rather
        # than reseeding, so the situation is visible instead of papered over.
        raise unauthorized()

    return Customer(customer_id=claims.customer_id, document=document, store=store)


CurrentCustomer = Annotated[Customer, Depends(current_customer)]
