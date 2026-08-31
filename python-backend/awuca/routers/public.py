"""Purpose 1: unauthenticated landing content."""

from __future__ import annotations

from fastapi import APIRouter

router = APIRouter(tags=["public"])

# The links point at the vanity URLs in edge/kvs/routing.yaml, so the landing
# page is also a live demonstration of the CloudFront Function rewrites.
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
    "links": [
        {"label": "Pay a bill", "href": "/pay"},
        {"label": "View statement", "href": "/bill"},
        {"label": "Join loyalty", "href": "/join"},
    ],
}


@router.get("/v1/public/landing")
def get_landing() -> dict:
    return _LANDING
