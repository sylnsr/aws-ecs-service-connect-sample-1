would"""Shared fixtures.

The app is imported lazily inside the fixtures rather than at module top level.
That is deliberate: `awuca.config` caches its settings on first read, so the
environment has to be pointed at a temp YAML store BEFORE anything imports the
app. Import at the top and a developer with STORE=dynamodb in their shell would
watch the unit tests try to reach AWS.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import Callable
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


@pytest.fixture(scope="session", autouse=True)
def local_store(tmp_path_factory: pytest.TempPathFactory) -> Path:
    store_path = tmp_path_factory.mktemp("store") / "awuca-store.yaml"
    os.environ["STORE"] = "yaml"
    os.environ["YAML_STORE_PATH"] = str(store_path)
    os.environ["TOKEN_SECRET"] = "test-secret"

    from awuca.config import reset_settings_cache
    from awuca.store import reset_store_cache

    reset_settings_cache()
    reset_store_cache()

    return store_path


@pytest.fixture(scope="session")
def client(local_store: Path) -> TestClient:
    """One app serving every route.

    create_app("all"), not "ecs": in production loyalty is a separate Lambda
    behind the same CloudFront distribution, so from a client's point of view
    the surface is one API. Splitting it here would only mean the loyalty tests
    needed a second client for no gain.
    """
    from awuca.app import create_app

    return TestClient(create_app("all"))


@pytest.fixture
def new_customer(client: TestClient) -> Callable[..., dict[str, str]]:
    """Mint a brand-new customer and return its Authorization header.

    A factory rather than a plain fixture because some tests need several
    customers, or one with a specific x-account-count. Freshly seeded state per
    customer is what lets the mutating cases (DELETE pm-0002, PUT pm-0001,
    loyalty signup) run in any order without poisoning each other.
    """

    def factory(account_count: int = 3) -> dict[str, str]:
        response = client.post(
            "/v1/auth/token",
            headers={"x-account-count": str(account_count)},
            json={"customerId": f"cust-{uuid.uuid4()}", "password": "lorem-ipsum"},
        )
        assert response.status_code == 200, response.text
        return {"Authorization": f"Bearer {response.json()['accessToken']}"}

    return factory


@pytest.fixture
def auth_headers(new_customer: Callable[..., dict[str, str]]) -> dict[str, str]:
    return new_customer()
