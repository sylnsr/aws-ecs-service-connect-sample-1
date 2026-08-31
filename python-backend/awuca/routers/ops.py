"""Operational endpoints. Not a customer purpose.

These exist so the harness can demonstrate its central claim. Without
/v1/whoami there is no way to observe that an atomic listener swap actually
moved traffic from one pool to the other -- both pools serve identical
customer responses by design, which is the whole point of a zero-downtime
deployment.
"""

from __future__ import annotations

from fastapi import APIRouter

from ..config import get_settings
from ..store import get_store

router = APIRouter(tags=["ops"])


@router.get("/healthz")
def healthz() -> dict:
    """ALB target group health check target.

    Deliberately does NOT touch the store. A health check that fails when
    DynamoDB is briefly unreachable will drain every task in the pool and turn
    a partial dependency outage into a total one.
    """
    return {"status": "ok"}


@router.get("/v1/whoami")
def whoami() -> dict:
    settings = get_settings()
    return {
        "pool": settings.pool,
        "role": settings.pool_role,
        "workload": settings.workload,
        "version": settings.version,
        "store": get_store().describe(),
    }
