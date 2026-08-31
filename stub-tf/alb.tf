# The ALB is the single deployment control point. ECS tasks and Lambda-backed
# routes are promoted through the same listener swap -- README section 2D --
# so there is no separate mechanism for the serverless half of the estate.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "AWUCA load balancer"
  vpc_id      = var.vpc_id

  egress {
    description = "To targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_production" {
  security_group_id = aws_security_group.alb.id
  description       = "Customers, production listener"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# The test listener is restricted to testers and CI. This is what makes
# "canary means testers, not a percentage of customers" a network fact rather
# than a convention -- README section 2C.
resource "aws_vpc_security_group_ingress_rule" "alb_test" {
  for_each = toset(var.test_listener_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Testers and CI, test listener"
  cidr_ipv4         = each.value
  from_port         = 8443
  to_port           = 8443
  ip_protocol       = "tcp"
}

resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "AWUCA ECS tasks"
  vpc_id      = var.vpc_id

  egress {
    description = "To DynamoDB, ECR, Secrets Manager, CloudWatch"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Only the ALB reaches the tasks"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_lb" "this" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true
  enable_deletion_protection = var.environment == "production"
}

# ---------------------------------------------------------------------------
# Target groups: one per POOL, not one per environment.
#
# Symmetric by construction. Which of these is live is a property of the
# production listener at a given moment, and it alternates on every release.
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "app" {
  for_each = toset(local.pools)

  name        = "${local.name}-${each.value}"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  # Shorter than the default so a replacement task set becomes healthy quickly
  # and the validation stage is not mostly waiting.
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Listeners
# ---------------------------------------------------------------------------

resource "aws_lb_listener" "production" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = var.acm_certificate_arn == "" ? "HTTP" : "HTTPS"
  certificate_arn   = var.acm_certificate_arn == "" ? null : var.acm_certificate_arn
  ssl_policy        = var.acm_certificate_arn == "" ? null : "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["blue"].arn
  }

  # THE OWNERSHIP BOUNDARY. CodeDeploy repoints this listener on every
  # promotion. If Terraform also declares the target, the next apply either
  # reverts a promotion or reports permanent drift forever.
  #
  # `blue` above is the INITIAL value only -- true exactly once, on first
  # apply. Do not read it as "blue is the live pool".
  #
  # docs/release-process.md section 5.
  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8443
  protocol          = var.acm_certificate_arn == "" ? "HTTP" : "HTTPS"
  certificate_arn   = var.acm_certificate_arn == "" ? null : var.acm_certificate_arn
  ssl_policy        = var.acm_certificate_arn == "" ? null : "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["green"].arn
  }

  # Swapped by CodeDeploy at the same moment as the production listener: the
  # pool that just went live becomes the next release's test target.
  lifecycle {
    ignore_changes = [default_action]
  }
}

# ---------------------------------------------------------------------------
# Loyalty is a Lambda (README section 2A). It is reached through the SAME two
# listeners, as a higher-priority rule, so the serverless route promotes by the
# same atomic swap as everything else.
# ---------------------------------------------------------------------------

resource "aws_lb_listener_rule" "loyalty_production" {
  listener_arn = aws_lb_listener.production.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.loyalty["blue"].arn
  }

  condition {
    path_pattern {
      values = ["/v1/loyalty", "/v1/loyalty/*"]
    }
  }

  lifecycle {
    ignore_changes = [action]
  }
}

resource "aws_lb_listener_rule" "loyalty_test" {
  listener_arn = aws_lb_listener.test.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.loyalty["green"].arn
  }

  condition {
    path_pattern {
      values = ["/v1/loyalty", "/v1/loyalty/*"]
    }
  }

  lifecycle {
    ignore_changes = [action]
  }
}
