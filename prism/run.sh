#!/usr/bin/env bash
#
# Launch the Prism mock in a container, serving the Postman collection.
#
# A CONTAINER, NOT `npx`. Prism is a Node application, but nothing on the host
# should have to know that. Debian and Mac both get the same pinned image, and
# neither needs a Node install -- which also means the mock cannot drift with
# whatever Node version happens to be on a given laptop.
#
#   ./prism/start.sh              foreground; Ctrl-C to stop
#   ./prism/start.sh -d           detached, waits until it is actually serving
#   ./prism/start.sh --stop       stop a detached instance
#   PRISM_PORT=4011 ./prism/start.sh
#
# Prism reads Postman Collection v2.1 natively. There is no OpenAPI conversion
# step and no config file -- the collection in postman/ is the only input.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTION_DIR="${REPO_ROOT}/postman"
COLLECTION_FILE="awuca.postman_collection.json"

PRISM_PORT="${PRISM_PORT:-4010}"
PRISM_IMAGE="${PRISM_IMAGE:-docker.io/stoplight/prism:5}"
CONTAINER_NAME="awuca-prism"
NETWORK="${AWUCA_NETWORK:-awuca}"

DETACH=0
STOP=0

for arg in "$@"; do
  case "$arg" in
    -d|--detach) DETACH=1 ;;
    # Acted on after the runtime is detected, below -- stopping with the wrong
    # CLI silently succeeds and leaves the container running.
    --stop) STOP=1 ;;
    -h|--help)
      sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Container runtime. Podman first -- README section 2A specifies rootless
# Podman -- but Docker works identically for this and is common on Mac.
# ---------------------------------------------------------------------------

if [ -n "${CONTAINER_CLI:-}" ]; then
  :
elif command -v podman >/dev/null 2>&1; then
  CONTAINER_CLI=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CLI=docker
else
  cat >&2 <<'EOF'
No container runtime found. Install one:

  Debian   sudo apt install podman
  Mac      brew install podman && podman machine init && podman machine start

(Docker works too, if you already have it.)
EOF
  exit 1
fi

if [ "$STOP" -eq 1 ]; then
  "$CONTAINER_CLI" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "Stopped ${CONTAINER_NAME}."
  exit 0
fi

if [ ! -f "${COLLECTION_DIR}/${COLLECTION_FILE}" ]; then
  echo "Collection not found: ${COLLECTION_DIR}/${COLLECTION_FILE}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# SELinux relabelling.
#
# `:ro,Z` is required on an SELinux host (Fedora, RHEL) or the container cannot
# read the mount. It is meaningless elsewhere, and asking for a relabel of a
# virtiofs share -- which is what a Mac podman machine gives you -- can fail
# outright. So ask the host rather than hardcoding either answer.
# ---------------------------------------------------------------------------

MOUNT_OPTS="ro"
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  MOUNT_OPTS="ro,Z"
fi

# A stale container from a previous run holds the port and the name.
"$CONTAINER_CLI" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# A user-defined network gives containers DNS names. The Playwright container
# reaches this one as http://awuca-prism:4010 -- which is the only mechanism
# that works the same on Debian and Mac. `--network=host` is Linux-only, and on
# a Mac `host` is the podman VM, not the laptop.
"$CONTAINER_CLI" network create "$NETWORK" >/dev/null 2>&1 || true

# -h 0.0.0.0 is not optional. Prism defaults to binding its own loopback, which
# inside a container means nothing outside it can connect -- not the host, and
# not another container on the same network.
#
# -m false is not optional either, and is far less obvious. Prism defaults to
# multiprocess, which crashes on startup in this image:
#
#   TypeError: Cannot read properties of undefined (reading 'isPrimary')
#       at createMultiProcessPrism (.../util/createServer.js)
#
# `cluster` is undefined where Prism expects it, so the fork never happens. It
# exits immediately, before binding a port, and prints the yargs usage block
# above the stack trace -- which makes it read like an argument error rather
# than the runtime bug it is. Single-process is fine here: one developer's
# mock does not need forked log processing.
#
# The published port is still bound to 127.0.0.1: it is there for curl and the
# Vue dev server on the host, and there is no reason for a mock holding
# lorem-ipsum data to be reachable from the rest of the network.
run_args=(
  --name "$CONTAINER_NAME"
  --network "$NETWORK"
  -p "127.0.0.1:${PRISM_PORT}:4010"
  -v "${COLLECTION_DIR}:/collection:${MOUNT_OPTS}"
  "$PRISM_IMAGE"
  mock -h 0.0.0.0 -p 4010 -m false "/collection/${COLLECTION_FILE}"
)

if [ "$DETACH" -eq 0 ]; then
  echo "Prism -> http://localhost:${PRISM_PORT}  (Ctrl-C to stop)"
  exec "$CONTAINER_CLI" run --rm "${run_args[@]}"
fi

# NO --rm WHEN DETACHED. With --rm, a container that exits one second after
# starting is deleted immediately, and the diagnostic becomes "no such
# container" -- which describes the cleanup, not the failure. Keeping the
# stopped container means its logs survive to be read. The `rm -f` above is
# what clears it on the next run.
"$CONTAINER_CLI" run -d "${run_args[@]}" >/dev/null

# Poll rather than sleep. Pulling the image on a first run takes far longer
# than starting it does, and a fixed sleep is either wasteful or flaky.
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://localhost:${PRISM_PORT}/v1/public/landing" 2>/dev/null; then
    echo "Prism -> http://localhost:${PRISM_PORT}"
    echo "Stop it with: ./prism/start.sh --stop"
    exit 0
  fi

  # Fail fast rather than waiting out the full 30s: if the container is no
  # longer running, it is never going to answer.
  state="$("$CONTAINER_CLI" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
  if [ "$state" != "running" ] && [ "$state" != "created" ]; then
    echo "Prism exited (${state}) instead of serving. Logs:" >&2
    "$CONTAINER_CLI" logs "$CONTAINER_NAME" >&2 2>&1 || true
    exit 1
  fi

  sleep 0.5
done

echo "Prism did not become ready in 30s. Logs:" >&2
"$CONTAINER_CLI" logs "$CONTAINER_NAME" >&2 2>&1 || true
exit 1
