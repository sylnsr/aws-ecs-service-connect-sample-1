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
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

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

RO="ro"
RW="rw"
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  RO="ro,Z"
  RW="rw,Z"
fi

# `init` is the only step here that reaches the network, and it is the step
# that breaks behind a TLS-intercepting proxy. See scripts/ca-bundle.sh.
# shellcheck source=../scripts/ca-bundle.sh
source "${HERE}/../scripts/ca-bundle.sh"

# THE WHOLE REPO, not just stub-tf/. The configuration reaches upwards --
# kvs.tf and locals.tf call file() on "${path.module}/../edge/..." to inline
# the CloudFront Function source and the KVS routing table. Mount stub-tf/
# alone and those paths land outside the container, and `validate` reports
# three "no file exists" errors that look like a broken configuration but are
# really a missing mount.
#
# Read-only for the repo, read-write for stub-tf/ nested inside it, because
# init writes .terraform/ and the lock file and nothing else here should be
# writable. Both are gitignored; the lock file would be committed in a real
# deployment repo, but this configuration is never applied.
tf() {
  "$CONTAINER_CLI" run --rm \
    -v "${REPO_ROOT}:/work:${RO}" \
    -v "${HERE}:/work/stub-tf:${RW}" \
    "${CA_ARGS[@]}" \
    -w /work/stub-tf \
    "$IMAGE" "$@"
}

status=0

echo "==> terraform fmt -check -recursive"
tf fmt -check -recursive -diff || status=1

echo "==> terraform init -backend=false"
if ! tf init -backend=false -input=false; then
  {
    echo
    echo "init failed; cannot validate."
    echo "If the error mentions x509 or 'certificate signed by unknown authority',"
    echo "the proxy's CA is missing inside the container rather than anything being"
    echo "wrong with the configuration. Point AWUCA_CA_BUNDLE at a complete PEM"
    echo "bundle and re-run; see scripts/ca-bundle.sh."
  } >&2
  exit 1
fi

echo "==> terraform validate"
tf validate || status=1

exit "$status"
