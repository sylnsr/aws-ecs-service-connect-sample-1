"""Application factory.

One codebase, two deployables, because README section 2A splits the workloads:
loyalty is a mock Lambda, everything else is a mock ECS task. README section 2E
then requires the two to be indistinguishable to the caller -- same ALB
listeners, same atomic promotion, no separate mechanism for the serverless
route.

    create_app("ecs")      every router except loyalty
    create_app("lambda")   loyalty only
    create_app("all")      everything, for local development

`all` exists so a developer can run one process and have the whole API, and so
the Playwright suite has a single base URL to point at. It is NOT how the app
is deployed: in AWS the two halves are genuinely separate compute, joined by
the ALB. Local convenience must not quietly become the production topology,
which is why the mode is explicit rather than inferred.
"""

from __future__ import annotations

from typing import Literal

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .errors import register_error_handlers
from .routers import accounts, auth, billing, loyalty, ops, payments, public

Mode = Literal["ecs", "lambda", "all"]

# Routers that make up the ECS workload.
_ECS_ROUTERS = (public.router, auth.router, accounts.router, billing.router, payments.router)


def create_app(mode: Mode = "all") -> FastAPI:
    settings = get_settings()

    app = FastAPI(
        title="ACME Water Utility Customer App",
        version=settings.version,
        description=(
            "Implements postman/awuca.postman_collection.json. That collection, "
            "not this code, is the source of truth."
        ),
    )

    register_error_handlers(app)

    # Only needed when the SPA is served from a different origin. The intended
    # deployment puts Vue and the API behind one CloudFront distribution, where
    # /api/* is same-origin and no preflight ever happens -- so this list is
    # empty by default and the middleware is not installed at all.
    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(settings.cors_origins),
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    # Ops routes go on both deployables: the ALB health checks each target
    # group independently, and /v1/whoami has to be able to report `lambda`
    # as well as `blue`/`green`.
    app.include_router(ops.router)

    if mode in ("ecs", "all"):
        for router in _ECS_ROUTERS:
            app.include_router(router)

    if mode in ("lambda", "all"):
        app.include_router(loyalty.router)

    return app
