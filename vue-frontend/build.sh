#!/usr/bin/env bash
#
# Build the production bundle in a container. No Node install on the host.
#
#   ./vue-frontend/build.sh
#
# Output lands in vue-frontend/dist/ on the host, because that directory is the
# deployable artifact -- it is what Terraform's S3 bucket serves behind
# CloudFront. It is the one thing here that is deliberately not disposable.
#
# The bundle contains no environment configuration of any kind. src/api.js only
# ever calls relative paths, so the same dist/ works against a local backend, a
# Prism mock, or the ALB, and there is no per-environment build.
#
# Cleaning up:
#   podman rmi docker.io/node:22-slim
#   podman volume rm awuca-vue-modules

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${NODE_IMAGE:-docker.io/node:22-slim}"
MODULES_VOLUME="${VUE_MODULES_VOLUME:-awuca-vue-modules}"

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

"$CONTAINER_CLI" volume create "$MODULES_VOLUME" >/dev/null 2>&1 || true

"$CONTAINER_CLI" run --rm \
  --name awuca-vue-build \
  -v "${HERE}:/app:${RW}" \
  -v "${MODULES_VOLUME}:/app/node_modules" \
  -w /app \
  -e npm_config_update_notifier=false \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    if [ ! -x node_modules/.bin/vite ]; then
      echo "==> installing dependencies (first run for this volume)"
      npm install --no-audit --no-fund --loglevel=error
    fi
    exec npx vite build
  '

echo
echo "Bundle:"
ls -la "${HERE}/dist"
