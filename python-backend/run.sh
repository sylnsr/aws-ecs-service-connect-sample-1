#!/usr/bin/env bash
#
# Run the backend container locally, with the YAML store.
#
#   ./python-backend/run.sh              foreground; Ctrl-C to stop
#   ./python-backend/run.sh -d           detached, waits until /healthz answers
#   ./python-backend/run.sh --stop
#   POOL=green ./python-backend/run.sh   run a second pool (see below)
#
# STORE=yaml here and STORE=dynamodb in the image default, because the two
# choices answer different questions. Locally there is one container and a bind
# mount, so a file is the simplest thing that survives a restart. In ECS blue
# and green run *at the same time*, and a per-container file would give each
# pool its own divergent copy of the world -- see python-backend/README.md.
#
# Running both pools locally:
#
#   ./python-backend/run.sh -d                            blue  on 8080
#   POOL=green PORT=8081 ./python-backend/run.sh -d       green on 8081
#
# They share the bind-mounted YAML file deliberately: that is the local stand-in
# for the shared DynamoDB table, and it is what makes an atomic swap between the
# two observable rather than a data reset.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE="${ECS_IMAGE:-awuca-backend}:${IMAGE_TAG:-dev}"
POOL="${POOL:-blue}"
PORT="${PORT:-8080}"
CONTAINER_NAME="awuca-backend-${POOL}"
NETWORK="${AWUCA_NETWORK:-awuca}"
DATA_DIR="${AWUCA_DATA_DIR:-$PWD/data}"

DETACH=0
STOP=0
for arg in "$@"; do
  case "$arg" in
    -d|--detach) DETACH=1 ;;
    # Acted on after the runtime is detected, below -- stopping with the wrong
    # CLI silently succeeds and leaves the container running.
    --stop) STOP=1 ;;
    -h|--help)
      sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

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

if [ "$STOP" -eq 1 ]; then
  "$CONTAINER_CLI" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "Stopped ${CONTAINER_NAME}."
  exit 0
fi

if ! "$CONTAINER_CLI" image exists "$IMAGE" 2>/dev/null \
  && ! "$CONTAINER_CLI" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Image ${IMAGE} not found. Build it first: ./python-backend/build.sh ecs" >&2
  exit 1
fi

mkdir -p "$DATA_DIR"

# Read-write, unlike the Prism collection mount -- this is the store.
MOUNT_OPTS="rw"
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  MOUNT_OPTS="rw,Z"
fi

"$CONTAINER_CLI" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
"$CONTAINER_CLI" network create "$NETWORK" >/dev/null 2>&1 || true

# The image runs as uid 10001. Under rootless podman that maps to a subuid on
# the host, which will not own $DATA_DIR -- :U tells podman to chown the mount
# to the container user. Docker has no equivalent and no need for one, since
# its bind mounts are not user-namespaced the same way.
[ "$CONTAINER_CLI" = "podman" ] && MOUNT_OPTS="${MOUNT_OPTS},U"

run_args=(
  --name "$CONTAINER_NAME"
  --network "$NETWORK"
  -p "127.0.0.1:${PORT}:8080"
  -v "${DATA_DIR}:/app/data:${MOUNT_OPTS}"
  -e STORE=yaml
  -e YAML_STORE_PATH=/app/data/awuca-store.yaml
  -e "POOL=${POOL}"
  -e "POOL_ROLE=${POOL_ROLE:-active}"
  -e APP_MODE=all
  -e "TOKEN_SECRET=${TOKEN_SECRET:-lorem-ipsum-demo-secret}"
  "$IMAGE"
)

# APP_MODE=all overrides the image's APP_MODE=ecs, so this one container serves
# the loyalty routes too. The split into an ECS app and a loyalty Lambda is an
# AWS packaging decision; the Playwright suite and the Vue dev server both
# expect a single base URL carrying the whole API.
#
# WORKLOAD is deliberately left at the image default of `ecs`. It is only the
# label /v1/whoami reports, and the stateful spec asserts it is `ecs` or
# `lambda` -- inventing a third value here would fail a test for no gain.

if [ "$DETACH" -eq 0 ]; then
  echo "Backend (${POOL}) -> http://localhost:${PORT}  (Ctrl-C to stop)"
  exec "$CONTAINER_CLI" run --rm "${run_args[@]}"
fi

# No --rm when detached -- see the note in prism/start.sh. A container that
# exits on startup would otherwise be deleted before its logs could be read.
"$CONTAINER_CLI" run -d "${run_args[@]}" >/dev/null

for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://localhost:${PORT}/healthz" 2>/dev/null; then
    echo "Backend (${POOL}) -> http://localhost:${PORT}"
    echo "Store: ${DATA_DIR}/awuca-store.yaml"
    echo "Stop it with: POOL=${POOL} ./python-backend/run.sh --stop"
    exit 0
  fi

  state="$("$CONTAINER_CLI" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
  if [ "$state" != "running" ] && [ "$state" != "created" ]; then
    echo "Backend exited (${state}) instead of serving. Logs:" >&2
    "$CONTAINER_CLI" logs "$CONTAINER_NAME" >&2 2>&1 || true
    exit 1
  fi

  sleep 0.5
done

echo "Backend did not become ready in 30s. Logs:" >&2
"$CONTAINER_CLI" logs "$CONTAINER_NAME" >&2 2>&1 || true
exit 1
