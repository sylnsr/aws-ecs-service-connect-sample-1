data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# ECS: two roles, and the split matters.
#
#   execution role -- used by the ECS AGENT before the container starts: pull
#                     the image, fetch secrets, create log streams.
#   task role      -- assumed by the APPLICATION once it is running.
#
# Collapsing them into one would give the running container permission to pull
# any image and read the secret directly, neither of which it needs.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The managed policy above covers ECR and logs but not Secrets Manager.
resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.read_token_secret.json
}

data "aws_iam_policy_document" "read_token_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.token_secret_arn]
  }
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "task_dynamodb" {
  name   = "dynamodb"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.customer_table.json
}

data "aws_iam_policy_document" "customer_table" {
  statement {
    # The app does exactly two things to this table: GetItem and PutItem. No
    # Scan, no Query, no DeleteItem -- there is no code path that needs them,
    # and a Scan on a table with no pagination is how a demo becomes a bill.
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.customers.arn]
  }
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-loyalty"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role = aws_iam_role.lambda.name
  # The function runs in the VPC to reach DynamoDB over a VPC endpoint. This
  # managed policy covers the ENI management that requires, and CloudWatch
  # Logs, which the basic execution policy would otherwise duplicate.
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name   = "dynamodb"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.customer_table.json
}

# Unlike the ECS task, the function reads the secret itself at cold start --
# there is no agent to inject it. Hence the task role equivalent needs it here.
resource "aws_iam_role_policy" "lambda_secrets" {
  name   = "secrets"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.read_token_secret.json
}

# ---------------------------------------------------------------------------
# CodeDeploy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "codedeploy_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "${local.name}-codedeploy"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume.json
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}
