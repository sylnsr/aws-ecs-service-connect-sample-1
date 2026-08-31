"""Round-trips that the contract tests cannot express.

A saved Postman example is one request and one response. It cannot say "after
you POST this, the GET changes" -- so anything the collection documents as a
transition is unprovable from the collection alone. The Playwright @stateful
suite covers the same ground over real HTTP; these exist because they need no
Node and no running server, so a broken transition fails the build rather than
the deployment.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

Headers = dict[str, str]
NewCustomer = Callable[..., Headers]


@pytest.mark.parametrize("account_count", [1, 3, 5])
def test_account_count_header_decides_list_length(
    client: TestClient, new_customer: NewCustomer, account_count: int
) -> None:
    body = client.get("/v1/accounts", headers=new_customer(account_count)).json()

    assert len(body["accounts"]) == account_count
    assert body["count"] == account_count


def test_last_account_is_closed_once_there_are_three(
    client: TestClient, new_customer: NewCustomer
) -> None:
    """The collection's account list example shows a mix of open and closed.
    Purpose 3 is "list accounts with open/closed status", so a seed that made
    every account open would satisfy the shape check and still miss the point.
    """
    accounts = client.get("/v1/accounts", headers=new_customer(3)).json()["accounts"]
    assert [a["status"] for a in accounts] == ["open", "open", "closed"]

    single = client.get("/v1/accounts", headers=new_customer(1)).json()["accounts"]
    assert [a["status"] for a in single] == ["open"]


def test_account_count_out_of_range_is_a_flat_400(client: TestClient) -> None:
    for value in ["0", "11", "not-a-number"]:
        response = client.post(
            "/v1/auth/token",
            headers={"x-account-count": value},
            json={"customerId": f"cust-{uuid.uuid4()}", "password": "lorem-ipsum"},
        )
        assert response.status_code == 400, value
        # The collection documents {error, message} everywhere. FastAPI's own
        # validation error is {detail: [...]} with a 422, which would be a
        # second error shape in the API.
        assert set(response.json()) == {"error", "message"}


def test_loyalty_signup_then_get_returns_the_same_id(
    client: TestClient, auth_headers: Headers
) -> None:
    # acc-0002, because the seed already enrols acc-0001 and so cannot show the
    # not-enrolled -> enrolled transition. See "Satisfiability" in the README.
    assert (
        client.get("/v1/loyalty", headers=auth_headers, params={"accountId": "acc-0002"}).status_code
        == 404
    )

    created = client.post(
        "/v1/loyalty/signup", headers=auth_headers, json={"accountId": "acc-0002", "optIn": True}
    )
    assert created.status_code == 201
    loyalty_id = created.json()["loyaltyId"]

    fetched = client.get("/v1/loyalty", headers=auth_headers, params={"accountId": "acc-0002"})
    assert fetched.status_code == 200
    assert fetched.json()["loyaltyId"] == loyalty_id


def test_loyalty_signup_is_idempotent(client: TestClient, auth_headers: Headers) -> None:
    existing = client.get(
        "/v1/loyalty", headers=auth_headers, params={"accountId": "acc-0001"}
    ).json()

    again = client.post(
        "/v1/loyalty/signup", headers=auth_headers, json={"accountId": "acc-0001", "optIn": True}
    )
    assert again.status_code == 201
    assert again.json()["loyaltyId"] == existing["loyaltyId"], "must not mint a second id"


def test_loyalty_is_scoped_to_the_customer(client: TestClient, new_customer: NewCustomer) -> None:
    """Two customers both have an acc-0001. They must not share an enrolment."""
    one = client.get("/v1/loyalty", headers=new_customer(), params={"accountId": "acc-0001"}).json()
    two = client.get("/v1/loyalty", headers=new_customer(), params={"accountId": "acc-0001"}).json()

    assert one["loyaltyId"] != two["loyaltyId"]


def test_closure_moves_from_absent_to_pending(client: TestClient, auth_headers: Headers) -> None:
    assert client.get("/v1/accounts/acc-0002/closure", headers=auth_headers).status_code == 404

    created = client.post(
        "/v1/accounts/acc-0002/closure",
        headers=auth_headers,
        json={"reason": "Lorem ipsum relocation", "effectiveDate": "2026-09-30"},
    )
    assert created.status_code == 202
    assert created.json()["status"] == "Pending"

    after = client.get("/v1/accounts/acc-0002/closure", headers=auth_headers)
    assert after.status_code == 200
    assert after.json()["closureRequestId"] == created.json()["closureRequestId"]
    assert after.json()["status"] == "Pending"


def test_payment_method_create_update_delete(client: TestClient, auth_headers: Headers) -> None:
    payload = {
        "type": "card",
        "label": "Sit amet card ending 5454",
        "default": False,
        "billingAddress": {
            "line1": "9 Dolor Way",
            "line2": None,
            "city": "Doloropolis",
            "region": "Ametshire",
            "postalCode": "LI3 4TX",
            "country": "GB",
        },
    }

    created = client.post("/v1/payments/methods", headers=auth_headers, json=payload)
    assert created.status_code == 201
    method_id = created.json()["methodId"]

    listed = client.get("/v1/payments/methods", headers=auth_headers).json()
    assert method_id in [m["methodId"] for m in listed["methods"]]
    assert listed["count"] == len(listed["methods"])

    payload["default"] = True
    payload["billingAddress"]["line1"] = "77 Consectetur Close"
    assert (
        client.put(f"/v1/payments/methods/{method_id}", headers=auth_headers, json=payload).status_code
        == 200
    )

    reread = client.get(f"/v1/payments/methods/{method_id}", headers=auth_headers).json()
    assert reread["billingAddress"]["line1"] == "77 Consectetur Close"
    assert reread["default"] is True

    # Exactly one default. Promoting this method must have demoted pm-0001.
    methods = client.get("/v1/payments/methods", headers=auth_headers).json()["methods"]
    assert sum(1 for m in methods if m["default"]) == 1

    assert client.delete(f"/v1/payments/methods/{method_id}", headers=auth_headers).status_code == 204
    assert client.get(f"/v1/payments/methods/{method_id}", headers=auth_headers).status_code == 404


def test_protected_routes_reject_missing_and_bogus_tokens(client: TestClient) -> None:
    for path in ["/v1/accounts", "/v1/payments/methods", "/v1/loyalty"]:
        assert client.get(path).status_code == 401, path
        assert client.get(path, headers={"Authorization": "Bearer nope"}).status_code == 401, path


def test_a_tampered_token_is_rejected(client: TestClient, auth_headers: Headers) -> None:
    """Flipping the payload without re-signing must not be accepted -- otherwise
    the HMAC is decoration."""
    token = auth_headers["Authorization"].removeprefix("Bearer ")
    header, payload, signature = token.split(".")
    forged = f"{header}.{payload}.{signature[:-1]}{'A' if signature[-1] != 'A' else 'B'}"

    assert client.get("/v1/accounts", headers={"Authorization": f"Bearer {forged}"}).status_code == 401


def test_address_is_read_only(client: TestClient, auth_headers: Headers) -> None:
    for method in ["PUT", "POST", "PATCH", "DELETE"]:
        response = client.request(
            method, "/v1/accounts/acc-0001/address", headers=auth_headers, json={"line1": "nope"}
        )
        assert response.status_code in (404, 405), f"{method} should not be routed"


def test_payment_history_has_both_debits_and_credits(
    client: TestClient, auth_headers: Headers
) -> None:
    """Purpose 7 asks for a debit AND credit list, so an empty or one-sided
    history would pass the shape check and miss the requirement."""
    body = client.get("/v1/accounts/acc-0001/payments", headers=auth_headers).json()

    assert {t["type"] for t in body["transactions"]} == {"debit", "credit"}
    assert body["count"] == len(body["transactions"])


def test_whoami_reports_pool_and_workload(client: TestClient) -> None:
    body = client.get("/v1/whoami").json()
    assert body["pool"] in ("blue", "green")
    assert body["workload"] in ("ecs", "lambda")
    assert body["store"] == "yaml"
    assert body["version"]


def test_writes_survive_a_new_store_instance(
    client: TestClient, auth_headers: Headers, local_store: Path
) -> None:
    """The YAML store must actually persist.

    Every round-trip above would still pass against a store that held state in
    a process-local dict and dropped its writes on the floor. Reopening the
    file from scratch is what distinguishes the two.
    """
    from awuca.store.yaml_store import YamlStore

    client.post(
        "/v1/loyalty/signup", headers=auth_headers, json={"accountId": "acc-0002", "optIn": True}
    )

    documents = YamlStore(str(local_store))._read_all()
    assert any("acc-0002" in doc.get("loyalty", {}) for doc in documents.values())
