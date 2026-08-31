# One distribution serves both the static bundle and the API.
#
# That is what makes the frontend origin-agnostic: every browser request is
# same-origin, so there is no CORS preflight and no API base URL baked into the
# bundle. The artifact built once in CI is the artifact promoted to every
# stage. See vue-frontend/README.md.

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${local.name}-site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = local.name
  default_root_object = "index.html"
  price_class         = var.environment == "production" ? "PriceClass_All" : "PriceClass_100"
  aliases             = var.domain_name == "" ? [] : [var.domain_name]

  origin {
    origin_id                = "s3-site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  origin {
    origin_id   = "alb-api"
    domain_name = aws_lb.this.dns_name

    custom_origin_config {
      http_port  = 80
      https_port = 443
      # Match whatever the production listener speaks. With no certificate the
      # listener is plain HTTP, and asking CloudFront for HTTPS would fail on
      # every request.
      origin_protocol_policy = var.acm_certificate_arn == "" ? "http-only" : "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ------------------------------------------------------------------ static
  default_cache_behavior {
    target_origin_id       = "s3-site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = data.aws_cloudfront_cache_policy.optimized.id

    # SPA fallback, not the rewrite function. The vanity URLs each have their
    # own behaviour below, so they never reach here -- and CloudFront allows
    # only one function per event type per behaviour anyway.
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa.arn
    }
  }

  # --------------------------------------------------------------------- API
  #
  # Behaviours are matched on the INCOMING URI, before the viewer-request
  # function runs. So the vanity URLs need their own behaviours pointing at the
  # ALB: /pay is matched here, and only then rewritten to
  # /v1/payments/methods. Route it to S3 and the rewrite happens on a request
  # that is already heading for the wrong origin.
  dynamic "ordered_cache_behavior" {
    for_each = toset(concat(local.api_path_patterns, local.vanity_api_paths))

    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "alb-api"
      viewer_protocol_policy = "https-only"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      # No caching. Every one of these responses is per-customer and keyed on a
      # bearer token; a shared cache in front of them is a data leak, not a
      # performance win.
      cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

      function_association {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.rewrite.arn
      }
    }
  }

  # NO `custom_error_response` BLOCK. It is tempting -- mapping 403/404 to
  # /index.html is the usual SPA recipe -- but it is configured per
  # DISTRIBUTION, not per behaviour, so it would also catch the API origin.
  # Every documented 404 from /v1/loyalty and /v1/accounts/{id}/closure would
  # return the HTML app shell with a 200, and the contract suite would go red
  # for a reason that has nothing to do with the backend.
  #
  # edge/functions/spa.js does the fallback on the S3 behaviour alone instead.

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.domain_name == ""
    acm_certificate_arn            = var.domain_name == "" ? null : var.acm_certificate_arn
    ssl_support_method             = var.domain_name == "" ? null : "sni-only"
    minimum_protocol_version       = var.domain_name == "" ? null : "TLSv1.2_2021"
  }
}

# Managed policies. Referencing them by name rather than hardcoding the well
# known UUIDs, which are not documented as stable.
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  # Forwards the Authorization header, without which every API call is a 401.
  name = "Managed-AllViewer"
}
