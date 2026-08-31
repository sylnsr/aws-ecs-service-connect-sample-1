#!/usr/bin/env bash
#
# Run the Playwright suite in a container. No Node install on the host.
#
#   ./playwright-tests/run.sh                        every configured project
#   ./playwright-tests/run.sh --project=prism        the mock baseline
#   ./playwright-tests/run.sh --project=python-local the app
#   ./playwright-tests/run.sh --grep @contract
#   ./playwright-tests/run.sh cases                  list generated cases only
#
# Anything after the script name is passed straight to `playwright test`.
# `cases` is the exception: it lists what the collection generates and needs no
# server at all, which makes it the fastest way to see a collection edit land.
#
# Why a container: apps.md requires that clean-up be "removing a container
# image", and the whole point of the Prism baseline is that a developer can
# exercise the collection without installing a toolchain. `npm test` from this
# directory still works and is the documented fallback -- the specs and
# playwright.config.ts are identical either way, only the invocation differs.
#
# Cleaning up:
#   podman rmi mcr.microsoft.com/playwright:v1.49.0-noble
#   podman volume rm awuca-pw-modules

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

IMAGE="${PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v1.49.0-noble}"
NETWORK="${AWUCA_NETWORK:-awuca}"
MODULES_VOLUME="${PLAYWRIGHT_MODULES_VOLUME:-awuca-pw-modules}"

# Container-to-container DNS names on the shared network, not localhost.
# Inside a container `localhost` is that container -- pointing the suite at
# localhost:4010 is the single most common way this fails.
PRISM_URL="${AWUCA_PRISM_URL:-http://awuca-prism:4010}"
PYTHON_URL="${AWUCA_PYTHON_URL:-http://awuca-backend-blue:8080}"
AWS_URL="${AWUCA_AWS_URL:-}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

MODE=test
if [ "${1:-}" = "cases" ]; then
  MODE=cases
  shift
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
RW="rw"
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  RO="ro,Z"
  RW="rw,Z"
fi

"$CONTAINER_CLI" network create "$NETWORK" >/dev/null 2>&1 || true

# node_modules lives in a named volume rather than on the host, so the host
# stays free of a 300 MB install and `podman volume rm` is the whole clean-up.
# It also stops a host-side node_modules -- possibly built by a different Node
# version -- from shadowing the container's.
"$CONTAINER_CLI" volume create "$MODULES_VOLUME" >/dev/null 2>&1 || true

# The collection is mounted read-only at the path src/collection.ts computes
# (../../postman relative to playwright-tests/src). Only two mounts, not the
# whole repo: the suite has no business writing anywhere but its own directory.

# -t only when there is a terminal to attach to. Forcing it under CI makes the
# run fail outright ("the input device is not a TTY") rather than degrade.
TTY_FLAG=()
[ -t 1 ] && TTY_FLAG=(-t)

exec "$CONTAINER_CLI" run --rm "${TTY_FLAG[@]}" \
  --name awuca-playwright \
  --network "$NETWORK" \
  -v "${REPO_ROOT}/postman:/work/postman:${RO}" \
  -v "${HERE}:/work/playwright-tests:${RW}" \
  -v "${MODULES_VOLUME}:/work/playwright-tests/node_modules" \
  -w /work/playwright-tests \
  -e "AWUCA_PRISM_URL=${PRISM_URL}" \
  -e "AWUCA_PYTHON_URL=${PYTHON_URL}" \
  -e "AWUCA_AWS_URL=${AWS_URL}" \
  -e "CI=${CI:-}" \
  -e "AWUCA_MODE=${MODE}" \
  -e PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
  -e npm_config_update_notifier=false \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    # Install only when the volume is empty or stale. A warm volume turns a
    # 40-second npm install into an instant start, which is what makes the
    # edit-collection/rerun loop in apps.md tolerable.
    if [ ! -x node_modules/.bin/playwright ]; then
      echo "==> installing dependencies (first run for this volume)"
      npm install --no-audit --no-fund --loglevel=error
    fi
    if [ "$AWUCA_MODE" = "cases" ]; then
      exec npm run --silent cases
    fi
    exec npx playwright test "$@"
  ' -- "$@"
