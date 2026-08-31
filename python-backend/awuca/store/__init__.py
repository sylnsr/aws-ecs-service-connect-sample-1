"""Storage adapters.

Two implementations behind one interface, chosen by the STORE environment
variable:

    STORE=yaml       a single YAML file      -- local development
    STORE=dynamodb   one item per customer   -- ECS and Lambda

Why the cloud side is DynamoDB and not "the same YAML file, in a volume":

  * Blue and green run AT THE SAME TIME. That is the premise of the whole
    harness. A file inside a task's own filesystem gives each pool a private,
    divergent world -- a payment method added while validating green vanishes
    at promotion, and rollback lands on stale data. A shared table makes
    promotion and rollback behave the way docs/release-process.md claims.
  * Loyalty is a Lambda and everything else is ECS (README section 2A). Both
    reach DynamoDB identically; neither can share a container filesystem.
  * ECS task filesystems are ephemeral and replaced on every CodeDeploy
    deployment, so a file in the container is lost once per release anyway.

The unit of storage is the whole customer document, read-modify-write. That is
wasteful and would not survive real traffic, but it keeps both adapters to
about thirty lines and the point here is the deployment paradigm, not the data
layer.
"""

from __future__ import annotations

import threading
from typing import Any, Protocol

from ..config import get_settings


class Store(Protocol):
    """Whole-document persistence, keyed by customer id."""

    def get(self, customer_id: str) -> dict[str, Any] | None: ...

    def put(self, customer_id: str, document: dict[str, Any]) -> None: ...

    def describe(self) -> str:
        """Short label for /v1/whoami, so an operator can see at a glance which
        adapter a running task actually picked up."""
        ...


def build_store() -> Store:
    settings = get_settings()

    if settings.store == "yaml":
        from .yaml_store import YamlStore

        return YamlStore(settings.yaml_path)

    if settings.store == "dynamodb":
        from .dynamodb_store import DynamoDbStore

        return DynamoDbStore(settings.dynamodb_table, settings.aws_region)

    raise RuntimeError(f"Unknown STORE={settings.store!r}; expected 'yaml' or 'dynamodb'")


_store: Store | None = None
_store_lock = threading.Lock()


def get_store() -> Store:
    """The one store for this process.

    Double-checked locking rather than a bare `if _store is None`, because the
    YamlStore's own RLock is the ONLY thing serialising its whole-file
    read-modify-write. FastAPI runs sync handlers in a threadpool, so a burst
    of requests at startup can put several threads in this initialiser at once.
    Each would build its own store with its own lock, and for the length of
    those requests the file is written by two mutually invisible critical
    sections: the loser's freshly seeded customer is dropped by the winner's
    next full-file write.

    The symptom is remote from the cause -- a token mints fine, then the very
    next request 401s at deps.current_customer, because the token is validly
    signed but its customer is no longer in the store.
    """
    global _store
    if _store is None:
        with _store_lock:
            # Re-checked under the lock: another thread may have built it
            # while this one was waiting.
            if _store is None:
                _store = build_store()
    return _store


def reset_store_cache() -> None:
    """Test hook."""
    global _store
    with _store_lock:
        _store = None
