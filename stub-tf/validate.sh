#!/usr/bin/env bash
#
# fmt, init and validate the Terraform, in a container. No Terraform install
# on the host, and no AWS credentials.
#
#   ./stub-tf/validate.sh
#
# `init -backend=false` deliberately: it downloads the provider schema so that
# validate has something to check argument names against, but it configures no
# state backend and touches no remote state. There is no `plan` and no `apply`
# in this script -- those need credentials and a target account, which is a
# HITL+ conversation, not a local one.
#
# Cleaning up:
#   podman rmi docker.io/hashicorp/terraform:1.9
#   rm -rf stub-tf/.terraform

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${TERRAFORM_IMAGE:-docker.io/hashicorp/terraform:1.9}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# Read-write because init writes .terraform/ and the lock file. Both are
# gitignored; the lock file would be committed in a real deployment repo, but
# this configuration is never applied.
tf() {
  "$CONTAINER_CLI" run --rm \
    -v "${HERE}:/work:${RW}" \
    -w /work \
    "$IMAGE" "$@"
}

status=0

echo "==> terraform fmt -check -recursive"
tf fmt -check -recursive -diff || status=1

echo "==> terraform init -backend=false"
tf init -backend=false -input=false || { echo "init failed; cannot validate" >&2; exit 1; }

echo "==> terraform validate"
tf validate || status=1

exit "$status"
