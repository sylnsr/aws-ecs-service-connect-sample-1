"""ECS entrypoint. Serves every route except loyalty.

    uvicorn main_ecs:app --host 0.0.0.0 --port 8080

APP_MODE defaults to `all` so that a bare local run gives the whole API in one
process, which is what the Playwright suite expects. The ECS task definition
sets APP_MODE=ecs explicitly, so the deployed container carries only the
workload it is supposed to.
"""

from __future__ import annotations

import os

from awuca.app import create_app

app = create_app(os.environ.get("APP_MODE", "all"))  # type: ignore[arg-type]


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8080")),
        # One worker on purpose. The YAML store locks within a process only, so
        # a second worker would silently lose writes. See the note in
        # awuca/store/yaml_store.py.
        workers=1,
    )
