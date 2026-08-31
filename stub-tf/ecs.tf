resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = var.environment == "production" ? "enabled" : "disabled"
  }

  # Service Connect needs a namespace. Creating it here rather than by name
  # keeps it in this module's lifecycle -- README section 2F asks for Service
  # Connect specifically, over the older Service Discovery integration.
  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.this.arn
  }
}

resource "aws_service_discovery_http_namespace" "this" {
  name = local.name
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/aws/ecs/${local.name}"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# Task definition
#
# Terraform declares the family, the roles and the base container shape. The
# release pipeline registers new revisions carrying new image tags. Both halves
# of that split are in docs/release-process.md section 5; the `ignore_changes`
# on the service below is the other half.
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.ecs_image
      essential = true

      portMappings = [
        {
          # Named, because Service Connect addresses ports by name.
          name          = "http"
          containerPort = 8080
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      environment = [
        { name = "APP_MODE", value = "ecs" },
        { name = "WORKLOAD", value = "ecs" },
        { name = "STORE", value = "dynamodb" },
        { name = "DYNAMODB_TABLE", value = aws_dynamodb_table.customers.name },
        { name = "AWS_REGION", value = var.region },
        { name = "APP_VERSION", value = var.app_version },
        # POOL and POOL_ROLE are deliberately NOT set here.
        #
        # A task definition revision is created once and used by whichever pool
        # CodeDeploy places it in, and the pool a task set belongs to changes
        # meaning on every release. Baking a pool name into the revision would
        # make /v1/whoami lie the first time the roles alternate. The release
        # pipeline injects them as an override when it registers the revision.
        { name = "CORS_ORIGINS", value = "" },
      ]

      secrets = [
        {
          name      = "TOKEN_SECRET"
          valueFrom = var.token_secret_arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])

  lifecycle {
    # The release pipeline registers revisions; Terraform owns the family and
    # the roles. Without this, every apply after a release would produce a
    # revision reverting the image tag.
    ignore_changes = [container_definitions]
  }
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    # Initial association only. CodeDeploy repoints this on every promotion,
    # which is why it is ignored below.
    target_group_arn = aws_lb_target_group.app["blue"].arn
    container_name   = "app"
    container_port   = 8080
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn

    service {
      port_name      = "http"
      discovery_name = "app"

      client_alias {
        port     = 8080
        dns_name = "app"
      }
    }
  }

  # THE OWNERSHIP BOUNDARY, service half. docs/release-process.md section 5.
  #   task_definition -- CodeDeploy points the service at the new revision
  #   load_balancer   -- CodeDeploy moves the service between target groups
  #   desired_count   -- application autoscaling owns it after first apply
  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  depends_on = [aws_lb_listener.production, aws_lb_listener.test]
}

# ---------------------------------------------------------------------------
# CodeDeploy
# ---------------------------------------------------------------------------

resource "aws_codedeploy_app" "this" {
  name             = local.name
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = local.name
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      # STOP_DEPLOYMENT, not CONTINUE_DEPLOYMENT. The candidate sits on the
      # test listener until a human approves -- stage 3 in
      # docs/release-process.md. An automatic promotion would remove the only
      # stage where a tester can look at it.
      action_on_timeout    = "STOP_DEPLOYMENT"
      wait_time_in_minutes = 60
    }

    terminate_blue_instances_on_deployment_success {
      action = "TERMINATE"
      # THE ROLLBACK WINDOW. Until this elapses the original task set is still
      # running and still healthy, so rollback is another atomic listener shift
      # rather than a redeploy. Section 6.
      termination_wait_time_in_minutes = var.termination_wait_minutes
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.this.name
    service_name = aws_ecs_service.app.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.production.arn]
      }

      test_traffic_route {
        listener_arns = [aws_lb_listener.test.arn]
      }

      # Order is not significance. CodeDeploy alternates between the two on
      # each deployment, which is exactly the alternating-roles model.
      target_group {
        name = aws_lb_target_group.app["blue"].name
      }

      target_group {
        name = aws_lb_target_group.app["green"].name
      }
    }
  }
}
