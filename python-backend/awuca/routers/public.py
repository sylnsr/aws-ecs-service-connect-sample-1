"""Purpose 1: unauthenticated landing content."""

from __future__ import annotations

from fastapi import APIRouter

router = APIRouter(tags=["public"])

# Marketing copy only. This payload once carried a `links` list pointing at the
# vanity URLs in edge/kvs/routing.yaml, on the theory that the landing page
# doubled as a live demonstration of the CloudFront Function rewrites. It did
# not: all three targets are authenticated (/v1/loyalty/signup is POST-only), so
# a signed-out visitor clicking them gets 401 or 405, never a rewrite worth
# seeing. The rewrite table belongs to the edge tier and should be exercised
# there, against rewrite.js, not inferred from an anchor tag on this page.
_LANDING = {
    "title": "ACME Water Utility",
    "hero": "Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
    "sections": [
        {
            "heading": "Lorem ipsum",
            "body": "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
        },
        {
            "heading": "Duis aute",
            "body": "Irure dolor in reprehenderit in voluptate velit esse cillum dolore.",
        },
    ],
}


@router.get("/v1/public/landing")
def get_landing() -> dict:
    return _LANDING
