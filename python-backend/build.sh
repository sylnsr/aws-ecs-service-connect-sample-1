#!/usr/bin/env bash
#
# Build the backend container images.
#
#   ./python-backend/build.sh           both images
#   ./python-backend/build.sh ecs       ECS image only   (Dockerfile)
#   ./python-backend/build.sh lambda    Lambda image only (Dockerfile.lambda)
#
# Two images, not one, because README section 2A splits the estate: loyalty is
# the mock Lambda workload, everything else is the mock ECS workload. They share
# the awuca/ package and diverge only in entrypoint and dependency set.
#
#   IMAGE_TAG=v2 ./python-backend/build.sh      tag something other than :dev
#   PLATFORM=linux/amd64 ./python-backend/build.sh
#
# PLATFORM matters on an Apple Silicon Mac: Fargate runs x86_64 unless the task
# definition says otherwise, so an image built natively on arm64 will build
# cleanly, run fine locally, and then fail to start as a task. Building for
# amd64 on arm is emulated and slow, which is why it is opt-in rather than the
# default -- local iteration should use the native arch.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE_TAG="${IMAGE_TAG:-dev}"
ECS_IMAGE="${ECS_IMAGE:-awuca-backend}"
LAMBDA_IMAGE="${LAMBDA_IMAGE:-awuca-loyalty}"

TARGET="${1:-all}"
case "$TARGET" in
  all|ecs|lambda) ;;
  -h|--help)
    sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Unknown target: ${TARGET} (expected: all, ecs, lambda)" >&2
    exit 2
    ;;
esac

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

build_args=()
[ -n "${PLATFORM:-}" ] && build_args+=(--platform "$PLATFORM")

if [ "$TARGET" = "all" ] || [ "$TARGET" = "ecs" ]; then
  echo "==> ${ECS_IMAGE}:${IMAGE_TAG}  (Dockerfile)"
  "$CONTAINER_CLI" build "${build_args[@]}" \
    -f Dockerfile -t "${ECS_IMAGE}:${IMAGE_TAG}" .
fi

if [ "$TARGET" = "all" ] || [ "$TARGET" = "lambda" ]; then
  echo "==> ${LAMBDA_IMAGE}:${IMAGE_TAG}  (Dockerfile.lambda)"
  # public.ecr.aws needs no credentials to pull, but it is a different registry
  # from Docker Hub -- a proxy allowlist that only covers docker.io will fail
  # here and nowhere else.
  "$CONTAINER_CLI" build "${build_args[@]}" \
    -f Dockerfile.lambda -t "${LAMBDA_IMAGE}:${IMAGE_TAG}" .
fi

echo
echo "Built:"
"$CONTAINER_CLI" images --filter "reference=${ECS_IMAGE}" --filter "reference=${LAMBDA_IMAGE}" \
  --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null || true
echo
echo "Run the ECS image locally with: ./python-backend/run.sh"
