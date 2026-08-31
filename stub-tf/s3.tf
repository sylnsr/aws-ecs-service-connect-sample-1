# Origin bucket for the built Vue bundle.
#
# The bucket is PRIVATE and reached only through CloudFront using Origin Access
# Control. Website hosting is deliberately not enabled: an S3 website endpoint
# is HTTP-only and public, which would let anyone bypass the distribution --
# and with it the edge rewrites, the WAF and the cache.

resource "aws_s3_bucket" "site" {
  bucket        = "${local.name}-site"
  force_destroy = var.environment != "production"
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  # Versioning is the frontend's rollback story. There is no blue/green for a
  # static bundle -- a bad deploy is fixed by re-uploading the previous
  # objects, which requires them to still exist.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json

  # The public access block must exist before the policy, or the policy write
  # can race it and be rejected.
  depends_on = [aws_s3_bucket_public_access_block.site]
}

data "aws_iam_policy_document" "site" {
  statement {
    sid       = "AllowCloudFrontOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # Scoped to THIS distribution. Without the condition, any CloudFront
    # distribution in any account could read the bucket.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}
