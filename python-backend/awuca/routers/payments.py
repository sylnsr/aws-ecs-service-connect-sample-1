"""Purpose 5: list and update payment methods, including billing addresses.

PATH IS PINNED. edge/kvs/routing.yaml rewrites /pay to /v1/payments/methods,
and the legacy /v1/payment-old to the same place.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Response, status

from ..deps import Customer, CurrentCustomer
from ..errors import not_found
from ..models import PaymentMethodRequest

router = APIRouter(prefix="/v1/payments/methods", tags=["payments"])


def _find(customer: Customer, method_id: str) -> dict[str, Any]:
    for method in customer.document["paymentMethods"]:
        if method["methodId"] == method_id:
            return method
    raise not_found("No such payment method for this customer")


def _clear_other_defaults(customer: Customer, method_id: str) -> None:
    """Exactly one method is the default. Without this, setting a second
    default leaves two, and the UI has no basis for choosing between them."""
    for method in customer.document["paymentMethods"]:
        if method["methodId"] != method_id:
            method["default"] = False


@router.get("")
def list_methods(customer: CurrentCustomer) -> dict:
    methods = customer.document["paymentMethods"]
    return {"count": len(methods), "methods": methods}


@router.post("", status_code=status.HTTP_201_CREATED)
def create_method(body: PaymentMethodRequest, customer: CurrentCustomer, response: Response) -> dict:
    sequence = customer.document["nextMethodSeq"]
    method_id = f"pm-{sequence:04d}"

    method = {
        "methodId": method_id,
        "type": body.type,
        "label": body.label,
        "default": body.default,
        "billingAddress": body.billingAddress.model_dump(),
    }

    customer.document["paymentMethods"].append(method)
    customer.document["nextMethodSeq"] = sequence + 1
    if body.default:
        _clear_other_defaults(customer, method_id)
    customer.save()

    response.headers["Location"] = f"/v1/payments/methods/{method_id}"
    return method


@router.get("/{method_id}")
def get_method(method_id: str, customer: CurrentCustomer) -> dict:
    return _find(customer, method_id)


@router.put("/{method_id}")
def update_method(method_id: str, body: PaymentMethodRequest, customer: CurrentCustomer) -> dict:
    method = _find(customer, method_id)

    # Mutated in place: `method` is a reference into customer.document, so this
    # is what save() will persist.
    method["type"] = body.type
    method["label"] = body.label
    method["default"] = body.default
    method["billingAddress"] = body.billingAddress.model_dump()

    if body.default:
        _clear_other_defaults(customer, method_id)
    customer.save()

    return method


@router.delete("/{method_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_method(method_id: str, customer: CurrentCustomer) -> Response:
    _find(customer, method_id)
    customer.document["paymentMethods"] = [
        m for m in customer.document["paymentMethods"] if m["methodId"] != method_id
    ]
    customer.save()
    # Explicit empty response: returning None here would still emit a JSON
    # `null` body, and the collection documents 204 with no body at all.
    return Response(status_code=status.HTTP_204_NO_CONTENT)
