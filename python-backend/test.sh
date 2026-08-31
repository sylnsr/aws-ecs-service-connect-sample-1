#!/usr/bin/env bash
#
# Run the pytest suite in a container. No Python install on the host.
#
#   ./python-backend/test.sh                 the whole suite
#   ./python-backend/test.sh -k contract     pass anything through to pytest
#   ./python-backend/test.sh -x --tb=long
#
# This is the cheapest signal in the repo: no server, no Prism, no network.
# It uses FastAPI's TestClient, so a failure here is a defect in the app rather
# than in the harness around it.
#
# Not the runtime image. Dockerfile deliberately excludes tests/ and the dev
# dependencies, because pytest and httpx have no business in an ECS task. So
# this mounts the source into a plain python image instead of building one.
#
# Cleaning up:
#   podman rmi docker.io/python:3.12-slim
#   podman volume rm awuca-py-venv

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="${PYTHON_IMAGE:-docker.io/python:3.12-slim}"
VENV_VOLUME="${PYTHON_VENV_VOLUME:-awuca-py-venv}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

# Same runtime detection as prism/start.sh; see the comment there.
if [ -n "${CONTAINER_CLI:-}" ]; then
  :
elif command -v podman >/dev/null 2>&1; then
  CONTAINER_CLI=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CLI=docker
else
  echo "No container runtime found. Install podman (Debian: apt install podman; Mac: brew install podman)." >&2
  exit 1
fi

RO="ro"
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  RO="ro,Z"
fi

"$CONTAINER_CLI" volume create "$VENV_VOLUME" >/dev/null 2>&1 || true

TTY_FLAG=()
[ -t 1 ] && TTY_FLAG=(-t)

# The repo is mounted READ-ONLY. The suite writes nothing: tests use pytest's
# tmp_path for the YAML store, PYTHONDONTWRITEBYTECODE suppresses __pycache__,
# and -p no:cacheprovider suppresses .pytest_cache. The whole repo rather than
# just python-backend/, because the contract tests read postman/ to build their
# cases -- that coupling is the point of the design.
exec "$CONTAINER_CLI" run --rm "${TTY_FLAG[@]}" \
  --name awuca-pytest \
  -v "${REPO_ROOT}:/work:${RO}" \
  -v "${VENV_VOLUME}:/opt/venv" \
  -w /work/python-backend \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    if [ ! -x /opt/venv/bin/pytest ]; then
      echo "==> creating venv (first run for this volume)"
      python -m venv /opt/venv
      /opt/venv/bin/pip install --quiet --no-cache-dir -r requirements-dev.txt
    fi
    # `python -m pytest`, not the `pytest` console script. The -m form puts the
    # working directory on sys.path, which is the only reason `import awuca`
    # resolves: there is no pyproject/pytest.ini/pythonpath here, tests/ has no
    # __init__.py, so pytest prepend-mode contributes tests/ and nothing else.
    # With the console script the package is importable only from inside a
    # fixture body that happens to run late enough to be masked by -k.
    exec /opt/venv/bin/python -m pytest -p no:cacheprovider "$@"
  ' -- "$@"
