"""Demo bearer tokens.

A deliberately small HMAC-signed token rather than PyJWT: one less dependency
for a token that authenticates nobody real. The shape is JWT-like (three
base64url segments) so the collection's example value looks plausible, but no
claim is made that this is a JWT implementation and nothing here should be
reused outside the harness.

What it does need to be is *stable across pools*. Blue and green run
simultaneously and a customer's token is minted by whichever pool served the
token request; if the signing key differed per pool, every promotion would
silently log everyone out. Hence TOKEN_SECRET comes from configuration, not
from a per-process random value.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from dataclasses import dataclass

from .config import get_settings


class TokenError(Exception):
    """Raised for any invalid token. The caller turns this into a flat 401 --
    the reason is deliberately not reported to the client."""


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64url_decode(segment: str) -> bytes:
    padding = "=" * (-len(segment) % 4)
    return base64.urlsafe_b64decode(segment + padding)


@dataclass(frozen=True)
class TokenClaims:
    customer_id: str
    account_count: int
    expires_at: int


def _sign(payload: str, secret: str) -> str:
    digest = hmac.new(secret.encode("utf-8"), payload.encode("ascii"), hashlib.sha256).digest()
    return _b64url_encode(digest)


def issue_token(customer_id: str, account_count: int) -> tuple[str, int]:
    """Returns (token, expires_in_seconds)."""
    settings = get_settings()
    ttl = settings.token_ttl_seconds
    header = _b64url_encode(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    claims = {
        "sub": customer_id,
        "accountCount": account_count,
        "exp": int(time.time()) + ttl,
    }
    body = _b64url_encode(json.dumps(claims, separators=(",", ":")).encode())
    payload = f"{header}.{body}"
    return f"{payload}.{_sign(payload, settings.token_secret)}", ttl


def decode_token(token: str) -> TokenClaims:
    settings = get_settings()
    parts = token.split(".")
    if len(parts) != 3:
        raise TokenError("malformed token")

    header, body, signature = parts
    expected = _sign(f"{header}.{body}", settings.token_secret)
    # compare_digest, not ==, so the comparison does not leak the signature
    # one byte at a time through timing.
    if not hmac.compare_digest(signature, expected):
        raise TokenError("bad signature")

    try:
        claims = json.loads(_b64url_decode(body))
    except (ValueError, json.JSONDecodeError) as exc:
        raise TokenError("undecodable claims") from exc

    customer_id = claims.get("sub")
    account_count = claims.get("accountCount")
    expires_at = claims.get("exp")

    if not isinstance(customer_id, str) or not customer_id:
        raise TokenError("missing subject")
    if not isinstance(account_count, int):
        raise TokenError("missing account count")
    if not isinstance(expires_at, int) or expires_at < int(time.time()):
        raise TokenError("expired")

    return TokenClaims(customer_id=customer_id, account_count=account_count, expires_at=expires_at)
