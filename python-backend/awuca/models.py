"""Request models.

Only *requests* are modelled. Responses are returned as plain dicts built from
the stored document, because that document is already shaped to match the
saved examples in the Postman collection. Restating those shapes as response
models would create a second source of truth that can drift from the first,
and the contract suite would then be checking the app against itself.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class StrictModel(BaseModel):
    # Reject unknown fields. A typo in a client payload should be a 422, not a
    # silently ignored field that leaves the caller believing it took effect.
    model_config = ConfigDict(extra="forbid")


class Address(StrictModel):
    line1: str = Field(min_length=1, max_length=200)
    line2: str | None = None
    city: str = Field(min_length=1, max_length=100)
    region: str | None = None
    postalCode: str = Field(min_length=1, max_length=20)
    country: str = Field(min_length=2, max_length=2)


class TokenRequest(StrictModel):
    customerId: str = Field(min_length=1, max_length=100)
    password: str = Field(min_length=1, max_length=200)


class PaymentMethodRequest(StrictModel):
    type: Literal["card", "direct_debit"]
    label: str = Field(min_length=1, max_length=100)
    default: bool = False
    billingAddress: Address


class LoyaltySignupRequest(StrictModel):
    accountId: str = Field(min_length=1, max_length=50)
    optIn: bool = True


class ClosureRequest(StrictModel):
    reason: str = Field(min_length=1, max_length=500)
    effectiveDate: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
