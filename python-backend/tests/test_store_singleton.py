"""The store must be ONE object per process.

Not a style point. YamlStore serialises its whole-file read-modify-write with
an RLock it owns, so two YamlStore instances over the same path have two locks
and therefore no mutual exclusion at all: each reads the file, adds its own
customer, and writes the whole thing back over the other's work.

`get_store()` used to be a bare `if _store is None: _store = build_store()`.
FastAPI runs sync handlers in a threadpool, so the burst of requests at the
start of a Playwright run put several threads in that initialiser at once and
a freshly seeded customer would simply vanish. The visible symptom was a
one-in-twenty-four 401 from GET /v1/accounts on a token that had just been
minted successfully -- deps.current_customer rejecting a validly signed token
whose customer was no longer in the store.
"""

from __future__ import annotations

import threading
from pathlib import Path

# `awuca` is imported inside the test bodies, not here -- the same rule the
# other modules and conftest follow, so that the local_store fixture has
# already pointed the environment at a temp YAML file before anything in the
# app reads its settings.

THREADS = 16


def _race(work) -> list:
    """Run `work(i)` on THREADS threads released as close to simultaneously as
    the GIL allows. A barrier, not a plain start, because the bug only shows
    while several threads are inside the initialiser together."""
    barrier = threading.Barrier(THREADS)
    results: list = [None] * THREADS

    def runner(index: int) -> None:
        barrier.wait()
        results[index] = work(index)

    threads = [threading.Thread(target=runner, args=(i,)) for i in range(THREADS)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    return results


def test_racing_threads_all_get_the_same_store(local_store: Path) -> None:
    from awuca.store import get_store, reset_store_cache

    reset_store_cache()

    stores = _race(lambda _: get_store())

    assert len({id(store) for store in stores}) == 1, (
        "get_store() built more than one store; each carries its own lock, so "
        "their writes to the same file cannot exclude each other"
    )


def test_concurrent_first_writes_are_not_lost(local_store: Path) -> None:
    """The consequence, end to end: every write survives.

    This is the shape of what the backend actually does on a token mint --
    fetch the store, then put a newly seeded customer into it.
    """
    from awuca.store import get_store, reset_store_cache

    reset_store_cache()

    def seed(index: int) -> str:
        customer_id = f"cust-race-{index}"
        get_store().put(customer_id, {"customerId": customer_id, "accountCount": 3})
        return customer_id

    written = _race(seed)

    store = get_store()
    missing = [customer_id for customer_id in written if store.get(customer_id) is None]

    assert missing == [], f"{len(missing)} of {THREADS} concurrent writes were lost: {missing}"
