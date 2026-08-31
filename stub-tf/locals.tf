locals {
  name = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "awuca"
  }

  # Blue and green are ROLES, not environments -- they alternate on every
  # release (docs/release-process.md section 1). Nothing in this module may
  # assume blue is the live one; the target groups are deliberately symmetric
  # and only the listener knows which is which at any moment.
  pools = ["blue", "green"]

  # The paths CloudFront must send to the ALB rather than S3. Everything else
  # falls through to the static bundle.
  api_path_patterns = ["/v1/*", "/healthz"]

  # The rewrite table. Single source of truth, read by the local edge shim and
  # seeded into the real store by kvs.tf -- see README section 2E.
  rewrites = { for r in yamldecode(file("${path.module}/../edge/kvs/routing.yaml")) : r.from => r.to }

  # Cache behaviours are selected from the INCOMING URI, before the
  # viewer-request function runs. So a vanity URL like /pay is matched against
  # the S3 default behaviour and never reaches the ALB, even though the
  # function is about to rewrite it to /v1/payments/methods. Each rewrite whose
  # source does not already match an api_path_pattern therefore needs its own
  # behaviour pointing at the ALB.
  vanity_api_paths = [
    for from, to in local.rewrites : from
    if startswith(to, "/v1/") && !startswith(from, "/v1/")
  ]
}
