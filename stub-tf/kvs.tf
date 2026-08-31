# CloudFront KeyValueStore: the URI rewrite table.
#
# Scope is rewrites only -- vanity URLs and legacy path migrations. It is NOT a
# deployment routing mechanism; blue/green is decided entirely at the ALB.
# README section 2E.
#
# edge/kvs/routing.yaml is the single source of truth. The local edge shim
# reads that file directly and this seeds the real store from the same bytes,
# so the two cannot disagree.

resource "aws_cloudfront_key_value_store" "routing" {
  name    = "${local.name}-routing"
  comment = "URI rewrites for ${local.name}. Seeded from edge/kvs/routing.yaml."
}

# The file is authored as a LIST of {from, to} pairs so each entry stays
# extensible -- a future `type` or `status` field needs no restructuring. The
# store requires a flat key -> string map, so project one into the other here
# rather than making a human maintain the flat form.
#
# Seeding through Terraform rather than the CLI is deliberate: the
# cloudfront-keyvaluestore API requires an ETag read-modify-write cycle on
# every write, which is a race as soon as two things write at once.
resource "aws_cloudfrontkeyvaluestore_key" "routing" {
  for_each = local.rewrites

  key_value_store_arn = aws_cloudfront_key_value_store.routing.arn
  key                 = each.key
  value               = each.value
}

# ---------------------------------------------------------------------------
# The viewer-request function that consults the store.
#
# CloudFront Functions have no environment variables, so the store ID has to be
# a literal in the source. The committed source keeps the placeholder and both
# load paths substitute it -- the local container with its own store ID, this
# with the real ARN. One substitution step for both, so they cannot diverge.
# README section 2E.
# ---------------------------------------------------------------------------

locals {
  rewrite_function_source = replace(
    file("${path.module}/../edge/functions/rewrite.js"),
    "KEY_VALUE_STORE_ID_PLACEHOLDER",
    aws_cloudfront_key_value_store.routing.id
  )
}

resource "aws_cloudfront_function" "rewrite" {
  name    = "${local.name}-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Vanity URL and legacy path rewrites"
  publish = true
  code    = local.rewrite_function_source

  key_value_store_associations = [aws_cloudfront_key_value_store.routing.arn]
}

# SPA history-mode fallback. No KVS association -- it consults nothing, which
# is why it is a separate function rather than a branch inside rewrite.js.
# See the comment in cloudfront.tf about why this is not a custom_error_response.
resource "aws_cloudfront_function" "spa" {
  name    = "${local.name}-spa"
  runtime = "cloudfront-js-2.0"
  comment = "Serve index.html for history-mode routes"
  publish = true
  code    = file("${path.module}/../edge/functions/spa.js")
}
