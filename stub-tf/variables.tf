# Every environment-specific value is a variable. README section 2F requires
# dev / staging / production to differ by tfvars alone, with no hardcoded
# strings in the resource bodies.

variable "project" {
  description = "Short name prefixed to every resource. Keep it DNS-safe."
  type        = string
  default     = "awuca"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 2-21 characters."
  }
}

variable "environment" {
  description = "Deployment stage."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be one of: dev, staging, production."
  }
}

variable "region" {
  description = "AWS region for everything except the CloudFront certificate."
  type        = string
  default     = "eu-west-2"
}

# ---------------------------------------------------------------- networking

variable "vpc_id" {
  description = "Existing VPC. This module does not create one -- see README."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets for the ALB. At least two AZs."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB requires subnets in at least two availability zones."
  }
}

variable "private_subnet_ids" {
  description = "Subnets for the ECS tasks and the Lambda ENIs."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Provide at least two subnets so tasks survive an AZ loss."
  }
}

variable "test_listener_cidrs" {
  description = <<-EOT
    Source ranges allowed to reach the CodeDeploy test listener.

    Testers and CI only. This is the security control that makes "canary means
    testers, not a percentage of customers" true at the network layer rather
    than by convention -- see README section 2C. Leaving it open to the world
    would mean the standby pool is quietly serving the public.
  EOT
  type        = list(string)

  validation {
    condition     = !contains(var.test_listener_cidrs, "0.0.0.0/0")
    error_message = "The test listener must not be open to the internet."
  }
}

# ------------------------------------------------------------------ compute

variable "ecs_image" {
  description = <<-EOT
    Container image for the ECS task. Terraform declares the family and the
    base container shape; the release pipeline registers new revisions carrying
    new tags. See the ownership boundary in docs/release-process.md section 5.
  EOT
  type        = string
}

variable "lambda_image" {
  description = "Container image for the loyalty Lambda."
  type        = string
}

variable "ecs_task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 512
}

variable "ecs_task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "ecs_desired_count" {
  description = <<-EOT
    Initial task count. Terraform ignores subsequent changes -- CodeDeploy and
    autoscaling own it after the first apply.
  EOT
  type        = number
  default     = 2
}

variable "app_version" {
  description = "Reported by /v1/whoami. Lets a tester see which build answered."
  type        = string
  default     = "0.1.0"
}

# --------------------------------------------------------------- deployment

variable "termination_wait_minutes" {
  description = <<-EOT
    How long the original task set stays alive after a promotion. THIS WINDOW
    IS THE ROLLBACK WINDOW (docs/release-process.md section 6): until it
    elapses, rollback is another atomic listener shift rather than a redeploy.

    Too short and there is no recovery path for a fault that only appears under
    real customer load; too long and two full pools are running and the next
    release cannot start.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.termination_wait_minutes >= 5 && var.termination_wait_minutes <= 2880
    error_message = "CodeDeploy allows up to 2880 minutes (2 days); below 5 leaves no usable rollback window."
  }
}

# ------------------------------------------------------------------- secret

variable "token_secret_arn" {
  description = <<-EOT
    Secrets Manager ARN holding TOKEN_SECRET.

    MUST resolve to the same value for both pools. A token minted by the active
    pool is presented to the standby pool the instant the listener swaps; a
    per-pool signing key would log every customer out on every promotion.
  EOT
  type        = string
}

# ------------------------------------------------------------------- edge

variable "domain_name" {
  description = "Custom domain for the distribution. Empty uses the default *.cloudfront.net name."
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "us-east-1 certificate for domain_name. Required when domain_name is set."
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || var.acm_certificate_arn != ""
    error_message = "acm_certificate_arn is required when domain_name is set."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 30
}
