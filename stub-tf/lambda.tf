# Loyalty is the serverless half of the mock estate -- README section 2A. It is
# fronted by ALB Lambda target groups and promoted through the same two
# listeners as the ECS service, so the ALB stays the single deployment control
# point and there is no second mechanism for serverless routes.

resource "aws_cloudwatch_log_group" "loyalty" {
  name              = "/aws/lambda/${local.name}-loyalty"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "loyalty" {
  function_name = "${local.name}-loyalty"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.lambda_image
  timeout       = 15
  memory_size   = 512

  # Publish a version on every update so the aliases below have something
  # immutable to point at. Without this, "swap the alias" has no meaning --
  # both aliases would resolve to $LATEST and the promotion would be a no-op.
  publish = true

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.tasks.id]
  }

  environment {
    variables = {
      WORKLOAD       = "lambda"
      STORE          = "dynamodb"
      DYNAMODB_TABLE = aws_dynamodb_table.customers.name
      APP_VERSION    = var.app_version
      # TOKEN_SECRET is NOT here. A Lambda environment variable is visible to
      # anyone with lambda:GetFunctionConfiguration; the function reads it from
      # Secrets Manager at cold start instead. It must resolve to the same
      # value the ECS tasks use, or a token minted by one workload is rejected
      # by the other.
      TOKEN_SECRET_ARN = var.token_secret_arn
    }
  }

  lifecycle {
    # Same boundary as the ECS task definition: the release pipeline ships new
    # images, Terraform owns the function's shape.
    ignore_changes = [image_uri]
  }
}

# ---------------------------------------------------------------------------
# Aliases: one per POOL, not one named "production" and one named "test".
#
# Naming them by role would hard-code the thing that alternates. Blue and green
# swap roles on every release (docs/release-process.md section 1), so the alias
# that is production today is the test target tomorrow. Keeping the aliases
# pool-named means the ONLY place the current role is recorded is the listener
# rule -- exactly as it is for ECS, and exactly one place to look.
#
# `routing_config` is deliberately absent. README section 2C rules out
# percentage canaries entirely: traffic moves in one step or not at all, and a
# weighted alias would reintroduce the ramp the design excludes.
# ---------------------------------------------------------------------------

resource "aws_lambda_alias" "pool" {
  for_each = toset(local.pools)

  name             = each.value
  function_name    = aws_lambda_function.loyalty.function_name
  function_version = aws_lambda_function.loyalty.version

  lifecycle {
    # The release pipeline points the standby pool's alias at the new version.
    # Terraform declaring it would revert that on the next apply -- the same
    # failure mode as the listener default_action.
    ignore_changes = [function_version]
  }
}

# ---------------------------------------------------------------------------
# ALB target groups fronting the aliases
# ---------------------------------------------------------------------------

resource "aws_lambda_permission" "alb" {
  for_each = aws_lambda_alias.pool

  statement_id  = "AllowALB-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.loyalty.function_name
  qualifier     = each.value.name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.loyalty[each.key].arn
}

resource "aws_lb_target_group" "loyalty" {
  for_each = toset(local.pools)

  name        = "${local.name}-loy-${each.value}"
  target_type = "lambda"

  # Lambda target groups do not health check by default, and enabling it would
  # invoke the function on a schedule for no benefit -- the ALB has no way to
  # drain a Lambda anyway.
  health_check {
    enabled = false
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group_attachment" "loyalty" {
  for_each = aws_lambda_alias.pool

  target_group_arn = aws_lb_target_group.loyalty[each.key].arn
  target_id        = each.value.arn
  depends_on       = [aws_lambda_permission.alb]
}
