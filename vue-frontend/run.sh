#!/usr/bin/env bash
#
# Run the Vite dev server in a container. No Node install on the host.
#
#   ./vue-frontend/run.sh                    proxy /v1 to the local backend
#   AWUCA_API_URL=http://awuca-prism:4010 ./vue-frontend/run.sh
#
# Then open http://localhost:5173.
#
# Pointing it at Prism instead of the backend is worth knowing about: the whole
# UI can be driven off the collection's saved examples before a single route
# exists in Python. That is the same claim the Playwright baseline makes, seen
# from the frontend side.
#
# Cleaning up:
#   podman rmi docker.io/node:22-slim
#   podman volume rm awuca-vue-modules

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${NODE_IMAGE:-docker.io/node:22-slim}"
NETWORK="${AWUCA_NETWORK:-awuca}"
MODULES_VOLUME="${VUE_MODULES_VOLUME:-awuca-vue-modules}"
PORT="${PORT:-5173}"

# A container name, not localhost -- see the note in playwright-tests/run.sh.
API_URL="${AWUCA_API_URL:-http://awuca-backend-blue:8080}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

RW="rw"
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  RW="rw,Z"
fi

"$CONTAINER_CLI" network create "$NETWORK" >/dev/null 2>&1 || true
"$CONTAINER_CLI" volume create "$MODULES_VOLUME" >/dev/null 2>&1 || true
"$CONTAINER_CLI" rm -f awuca-vue >/dev/null 2>&1 || true

TTY_FLAG=()
[ -t 1 ] && TTY_FLAG=(-t)

echo "Vite -> http://localhost:${PORT}   (API proxied to ${API_URL})"

# --host 0.0.0.0 rather than editing vite.config.js: the config describes the
# app, and binding to every interface is a fact about running in a container.
exec "$CONTAINER_CLI" run --rm "${TTY_FLAG[@]}" \
  --name awuca-vue \
  --network "$NETWORK" \
  -p "127.0.0.1:${PORT}:5173" \
  -v "${HERE}:/app:${RW}" \
  -v "${MODULES_VOLUME}:/app/node_modules" \
  -w /app \
  -e "AWUCA_API_URL=${API_URL}" \
  -e npm_config_update_notifier=false \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    if [ ! -x node_modules/.bin/vite ]; then
      echo "==> installing dependencies (first run for this volume)"
      npm install --no-audit --no-fund --loglevel=error
    fi
    exec npx vite --host 0.0.0.0 --port 5173
  '
