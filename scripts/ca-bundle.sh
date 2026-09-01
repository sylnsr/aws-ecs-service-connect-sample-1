#!/usr/bin/env bash
#
# Shared: make a TLS-intercepting proxy work inside the containers.
#
# Not executable on its own. Source it, then splice CA_ARGS into a container
# run:
#
#   source "${HERE}/../scripts/ca-bundle.sh"
#   podman run "${CA_ARGS[@]}" ... "$IMAGE"
#
# WHY THIS EXISTS
#
# On a network that re-signs TLS, the HOST trusts the proxy's CA but a
# container does not -- it carries its base image's trust store and nothing
# else. Every package fetch then fails with a message that looks nothing like
# a proxy problem, which is what makes this worth a file of its own:
#
#   Go / Terraform  x509: certificate signed by unknown authority
#   Node / npm      UNABLE_TO_GET_ISSUER_CERT_LOCALLY
#   Python / pip    CERTIFICATE_VERIFY_FAILED
#
# Image pulls can succeed while all three of those fail. The registry client
# is the container runtime, running on the host, using the host's trust store.
#
# WHICH BUNDLE
#
#   AWUCA_CA_BUNDLE=/path/to/bundle.pem   explicit, wins over everything
#   AWUCA_CA_BUNDLE=none                  disable entirely
#   unset                                 the host's own system bundle
#
# The default is deliberate: a host configured for the proxy already has the
# proxy CA in its system bundle, alongside the public roots. So the common
# case needs no configuration at all, and the uncommon case is one variable.
#
# IT MUST BE A COMPLETE BUNDLE, NOT A LONE CORPORATE CERT. pip's PIP_CERT and
# REQUESTS_CA_BUNDLE REPLACE the trust store rather than adding to it, so a
# single-cert file there would break every connection that is not intercepted.
# The host system bundle satisfies this; a cert exported from a browser does
# not, unless you concatenate it onto one.
#
# HOW IT IS APPLIED
#
#   Node    NODE_EXTRA_CA_CERTS -- appended to the built-in roots by design.
#   Python  REQUESTS_CA_BUNDLE and PIP_CERT -- replacing, hence the rule above.
#   Go      NOT SSL_CERT_FILE. The bundle is mounted INTO the image's cert
#           directory instead, because Go reads the first cert file it finds
#           AND every entry of the cert directory. Mounting an extra file
#           therefore ADDS to the public roots, where SSL_CERT_FILE would
#           replace them outright.
#
# The mount is read-only and deliberately carries no :Z. Relabelling is the
# right thing for a repo checkout and the wrong thing for a host system file --
# an SELinux relabel of /etc/ssl/certs/ca-certificates.crt would be a change to
# the host, made by a test script, outside the repo. If SELinux denies the read
# instead, copy the bundle into the repo and point AWUCA_CA_BUNDLE at the copy.

# The in-container path. Inside /etc/ssl/certs on purpose -- that is the
# default cert directory for both the Debian and Alpine base images here, which
# is what buys the additive Go behaviour described above.
CA_TARGET="/etc/ssl/certs/awuca-proxy-ca.pem"

_ca_bundle="${AWUCA_CA_BUNDLE:-}"

if [ -z "$_ca_bundle" ]; then
  for _candidate in \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/pki/tls/certs/ca-bundle.crt \
    /etc/ssl/ca-bundle.pem; do
    if [ -r "$_candidate" ]; then
      _ca_bundle="$_candidate"
      break
    fi
  done
  # Nothing found is normal on a Mac, where the trust store is the Keychain
  # rather than a file. Set AWUCA_CA_BUNDLE if that host is behind a proxy.
fi

if [ "$_ca_bundle" = "none" ]; then
  _ca_bundle=""
elif [ -n "$_ca_bundle" ] && [ ! -r "$_ca_bundle" ]; then
  echo "    CA bundle '${_ca_bundle}' is not readable; continuing without it." >&2
  _ca_bundle=""
fi

# Always non-empty. An empty array expanded as "${CA_ARGS[@]}" under `set -u`
# is an unbound-variable error in bash 3.2, which is still what a Mac ships, so
# the disabled case carries a harmless marker rather than nothing. The marker
# is also readable from inside the container when something looks wrong.
if [ -n "$_ca_bundle" ]; then
  CA_ARGS=(
    -v "${_ca_bundle}:${CA_TARGET}:ro"
    -e "NODE_EXTRA_CA_CERTS=${CA_TARGET}"
    -e "REQUESTS_CA_BUNDLE=${CA_TARGET}"
    -e "PIP_CERT=${CA_TARGET}"
    -e "SSL_CERT_DIR=/etc/ssl/certs"
    -e "AWUCA_CA_BUNDLE_APPLIED=${_ca_bundle}"
  )
  echo "==> trusting CA bundle ${_ca_bundle} inside the container" >&2
else
  CA_ARGS=(-e "AWUCA_CA_BUNDLE_APPLIED=no")
fi

unset _ca_bundle _candidate
