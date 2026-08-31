output "site_url" {
  description = "Where a customer reaches the app."
  value       = var.domain_name == "" ? "https://${aws_cloudfront_distribution.this.domain_name}" : "https://${var.domain_name}"
}

output "site_bucket" {
  description = "Upload the built Vue bundle here (vue-frontend/dist)."
  value       = aws_s3_bucket.site.bucket
}

output "distribution_id" {
  description = "Needed to invalidate the cache after a frontend deploy."
  value       = aws_cloudfront_distribution.this.id
}

output "production_url" {
  description = <<-EOT
    The ALB production listener. Customers reach this via CloudFront; this
    address is for diagnosing whether a problem is at the edge or the origin.
  EOT
  value       = "${var.acm_certificate_arn == "" ? "http" : "https"}://${aws_lb.this.dns_name}"
}

output "test_url" {
  description = <<-EOT
    The CodeDeploy test listener -- where the standby pool is validated before
    promotion.

    Point the Playwright suite here:
      AWUCA_AWS_URL=<this> npx playwright test --project=python-aws

    Reachable only from test_listener_cidrs. That restriction is what makes
    "canary means testers, not customers" true at the network layer.
  EOT
  value       = "${var.acm_certificate_arn == "" ? "http" : "https"}://${aws_lb.this.dns_name}:8443"
}

output "customer_table" {
  description = "DynamoDB table holding customer documents."
  value       = aws_dynamodb_table.customers.name
}

output "codedeploy_application" {
  description = "For the release pipeline: aws deploy create-deployment --application-name ..."
  value       = aws_codedeploy_app.this.name
}

output "codedeploy_deployment_group" {
  description = "For the release pipeline."
  value       = aws_codedeploy_deployment_group.this.deployment_group_name
}

output "target_group_names" {
  description = <<-EOT
    Both pools, by name. Which one is live is NOT recorded here on purpose --
    the roles alternate on every release and the listener is the only honest
    source of that. Ask the listener:

      aws elbv2 describe-listeners --listener-arns <production_listener_arn>
  EOT
  value       = { for pool, tg in aws_lb_target_group.app : pool => tg.name }
}

output "production_listener_arn" {
  value       = aws_lb_listener.production.arn
  description = "Ask this which pool is currently live."
}

output "test_listener_arn" {
  value       = aws_lb_listener.test.arn
  description = "Ask this which pool is currently the validation target."
}

output "key_value_store_id" {
  description = "Substituted into edge/functions/rewrite.js at upload time."
  value       = aws_cloudfront_key_value_store.routing.id
}

output "rewrite_table" {
  description = "The vanity URLs and legacy paths seeded into the store."
  value       = local.rewrites
}
