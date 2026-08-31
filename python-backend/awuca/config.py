"""Runtime configuration, all via environment variables.

Everything that differs between "on my laptop" and "in ECS" is here, so the
same image runs in both places. Nothing in this module reads a file at import
time, because an ECS task must be able to start without one.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def _int_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer, got {raw!r}") from exc


@dataclass(frozen=True)
class Settings:
    # Which storage adapter to use. See awuca/store/__init__.py for why the
    # choice matters more than it looks: blue and green run at the same time,
    # so a per-container file gives each pool its own divergent world.
    store: str
    yaml_path: str
    dynamodb_table: str
    aws_region: str

    # Signing key for the demo bearer token. Not a secret worth protecting --
    # this is a mock auth service -- but it must be stable across both pools or
    # a token minted by blue stops working the instant traffic swaps to green.
    token_secret: str
    token_ttl_seconds: int

    # Blue/green identity, surfaced by /v1/whoami. Without this the harness
    # cannot show that an atomic listener swap actually moved traffic.
    pool: str
    pool_role: str
    workload: str
    version: str

    # Only needed when the frontend is served from a different origin. The
    # intended deployment puts Vue and the API behind one CloudFront
    # distribution, where this stays empty and no preflight ever happens.
    cors_origins: tuple[str, ...]

    max_account_count: int = 10

    @classmethod
    def from_env(cls) -> "Settings":
        raw_origins = os.environ.get("CORS_ORIGINS", "").strip()
        return cls(
            store=os.environ.get("STORE", "yaml").lower(),
            yaml_path=os.environ.get("YAML_STORE_PATH", "./data/awuca-store.yaml"),
            dynamodb_table=os.environ.get("DYNAMODB_TABLE", "awuca-demo"),
            aws_region=os.environ.get("AWS_REGION", "eu-west-2"),
            token_secret=os.environ.get("TOKEN_SECRET", "lorem-ipsum-demo-secret"),
            token_ttl_seconds=_int_env("TOKEN_TTL_SECONDS", 3600),
            pool=os.environ.get("POOL", "blue").lower(),
            pool_role=os.environ.get("POOL_ROLE", "active").lower(),
            workload=os.environ.get("WORKLOAD", "ecs").lower(),
            version=os.environ.get("APP_VERSION", "0.1.0"),
            cors_origins=tuple(o.strip() for o in raw_origins.split(",") if o.strip()),
            max_account_count=_int_env("MAX_ACCOUNT_COUNT", 10),
        )


_settings: Settings | None = None


def get_settings() -> Settings:
    """Cached settings. Read once so a mid-flight env change cannot make two
    requests in the same process disagree about which pool they are."""
    global _settings
    if _settings is None:
        _settings = Settings.from_env()
    return _settings


def reset_settings_cache() -> None:
    """Test hook. Production code should never call this."""
    global _settings
    _settings = None
