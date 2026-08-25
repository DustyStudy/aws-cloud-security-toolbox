# Reference deployment of the Claude apps gateway on AWS. Mirrors
# https://code.claude.com/docs/en/claude-apps-gateway-on-aws as Terraform.
# A working example for customer-managed infrastructure, not a supported
# production deployment - review and adapt before relying on it.
#
# Two-phase apply, same reason the CloudFormation version is split into
# two stacks: the ECS service needs a real image in ECR before it can
# start, so:
#
#   terraform apply -target=aws_ecr_repository.gateway
#   # build and push your image using the printed repository_url
#   terraform apply
#
# The second apply is a no-op for the repository and creates everything
# else, including the ECS service.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------
# Security groups - chain the traffic path: corporate CIDR -> ALB:443 ->
# gateway:8080 -> Postgres:5432. Nothing else is reachable.
# ---------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb-"
  description = "Claude apps gateway ALB - HTTPS from the corporate network only."
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from corporate network"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.corporate_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "gateway" {
  name_prefix = "${var.name_prefix}-svc-"
  description = "Claude apps gateway ECS service - reachable from the ALB only."
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "gateway_from_alb" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.gateway.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name_prefix}-db-"
  description = "Claude apps gateway RDS for PostgreSQL - reachable from the gateway service only."
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "db_from_gateway" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.gateway.id
}

resource "aws_security_group" "bedrock_endpoint" {
  count = var.create_bedrock_vpc_endpoint ? 1 : 0

  name_prefix = "${var.name_prefix}-bedrock-endpoint-"
  description = "Claude apps gateway Bedrock VPC endpoint - reachable from the gateway service only."
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "bedrock_endpoint_from_gateway" {
  count = var.create_bedrock_vpc_endpoint ? 1 : 0

  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.bedrock_endpoint[0].id
  source_security_group_id = aws_security_group.gateway.id
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  count = var.create_bedrock_vpc_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.bedrock_endpoint[0].id]
  private_dns_enabled = true
}

# ---------------------------------------------------------------------
# IAM - two distinct roles. The task role is what the gateway's AWS SDK
# uses at runtime to call Bedrock; the execution role is what the ECS
# agent itself uses to pull the image and inject secrets.
# ---------------------------------------------------------------------
resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_invoke" {
  name = "${var.name_prefix}-bedrock-invoke"
  role = aws_iam_role.task.id

  # Both ARN families are required: the built-in model catalog resolves
  # every Claude model to a cross-region inference profile, which itself
  # invokes the underlying foundation model.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = [
        "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.*",
        "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/anthropic.*",
      ]
    }]
  })
}

resource "aws_iam_role" "execution" {
  name = "${var.name_prefix}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "read_gateway_secrets" {
  # Named by exact ARN, not a "gateway-*" wildcard - in a shared account
  # a prefix glob would also match unrelated secrets.
  name = "${var.name_prefix}-read-secrets"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        aws_secretsmanager_secret.jwt.arn,
        aws_secretsmanager_secret.oidc_client_secret.arn,
        aws_secretsmanager_secret.postgres_url.arn,
      ]
    }]
  })
}

# ---------------------------------------------------------------------
# Secrets Manager - three secrets the gateway resolves at boot via
# ${VAR} expansion in gateway.yaml. None of their values ever appear in
# Terraform state in plaintext at rest (state encryption aside) beyond
# what aws_secretsmanager_secret_version normally requires.
# ---------------------------------------------------------------------
resource "random_password" "db_master" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db_master_password" {
  name        = "${var.name_prefix}-db-master-password"
  description = "Auto-generated master password for the gateway's RDS instance."
}

resource "aws_secretsmanager_secret_version" "db_master_password" {
  secret_id     = aws_secretsmanager_secret.db_master_password.id
  secret_string = random_password.db_master.result
}

resource "random_password" "jwt_secret" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "jwt" {
  name        = "${var.name_prefix}-jwt-secret"
  description = "Signing key for gateway session JWTs (session.jwt_secret in gateway.yaml)."
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id     = aws_secretsmanager_secret.jwt.id
  secret_string = random_password.jwt_secret.result
}

resource "aws_secretsmanager_secret" "oidc_client_secret" {
  name        = "${var.name_prefix}-oidc-client-secret"
  description = "OAuth client secret from the IdP's gateway app registration (oidc.client_secret in gateway.yaml)."
}

resource "aws_secretsmanager_secret_version" "oidc_client_secret" {
  secret_id     = aws_secretsmanager_secret.oidc_client_secret.id
  secret_string = var.oidc_client_secret_value
}

resource "aws_secretsmanager_secret" "postgres_url" {
  name        = "${var.name_prefix}-postgres-url"
  description = "Full connection string for the gateway's store (store.postgres_url in gateway.yaml)."
}

resource "aws_secretsmanager_secret_version" "postgres_url" {
  secret_id     = aws_secretsmanager_secret.postgres_url.id
  secret_string = "postgres://gateway:${random_password.db_master.result}@${aws_db_instance.gateway.address}:5432/claude_gateway?sslmode=verify-full"
}

# ---------------------------------------------------------------------
# RDS for PostgreSQL - private, encrypted, TLS-only.
# ---------------------------------------------------------------------
resource "aws_db_subnet_group" "gateway" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_parameter_group" "gateway" {
  name        = "${var.name_prefix}-db"
  family      = "postgres16"
  description = "${var.name_prefix} - require TLS on every connection"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_db_instance" "gateway" {
  identifier        = "${var.name_prefix}-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage_gb
  db_name           = "claude_gateway"
  username          = "gateway"
  password          = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.gateway.name
  parameter_group_name   = aws_db_parameter_group.gateway.name
  vpc_security_group_ids = [aws_security_group.db.id]

  storage_encrypted         = true
  publicly_accessible       = false
  backup_retention_period   = 7
  deletion_protection       = var.enable_deletion_protection
  skip_final_snapshot       = !var.enable_deletion_protection
  final_snapshot_identifier = var.enable_deletion_protection ? "${var.name_prefix}-db-final" : null
}

# ---------------------------------------------------------------------
# ECR - immutable tags so a deployed tag can't be silently re-pointed.
# This is the resource to `-target` on the first apply.
# ---------------------------------------------------------------------
resource "aws_ecr_repository" "gateway" {
  name                 = var.name_prefix
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---------------------------------------------------------------------
# ECS Fargate
# ---------------------------------------------------------------------
resource "aws_ecs_cluster" "gateway" {
  name = var.name_prefix
}

resource "aws_cloudwatch_log_group" "gateway" {
  # The gateway's stderr carries both its audit events and its
  # operational logs - align this retention with your audit policy.
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = 90
}

resource "aws_ecs_task_definition" "gateway" {
  family                   = var.name_prefix
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name  = "gateway"
    image = "${aws_ecr_repository.gateway.repository_url}:${var.container_image_tag}"
    portMappings = [{
      containerPort = 8080
    }]
    secrets = [
      { name = "GATEWAY_JWT_SECRET", valueFrom = aws_secretsmanager_secret.jwt.arn },
      { name = "OIDC_CLIENT_SECRET", valueFrom = aws_secretsmanager_secret.oidc_client_secret.arn },
      { name = "GATEWAY_POSTGRES_URL", valueFrom = aws_secretsmanager_secret.postgres_url.arn },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.gateway.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "gateway"
      }
    }
  }])
}

resource "aws_lb" "gateway" {
  name               = var.name_prefix
  internal           = true
  load_balancer_type = "application"
  ip_address_type    = "ipv4"
  # ipv4-only matters: a dual-stack internal ALB publishes public-range
  # AAAA records, which Claude Code's private-network check at /login
  # rejects even though the A record is private.
  subnets         = var.private_subnet_ids
  security_groups = [aws_security_group.alb.id]

  idle_timeout = 3600
  # A stream that goes quiet during long prompt processing or extended
  # thinking with no streamed output is cut mid-response at the ALB's
  # 60-second default.
}

resource "aws_lb_target_group" "gateway" {
  name        = var.name_prefix
  vpc_id      = var.vpc_id
  protocol    = "HTTP"
  port        = 8080
  target_type = "ip"

  health_check {
    path = "/readyz"
    # /readyz verifies the store is reachable, so a task that can't
    # reach Postgres never enters rotation.
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.gateway.arn
  protocol          = "HTTPS"
  port              = 443
  # Pinned explicitly - the default ELBSecurityPolicy-2016-08 still
  # accepts TLS 1.0/1.1.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

resource "aws_ecs_service" "gateway" {
  name            = var.name_prefix
  cluster         = aws_ecs_cluster.gateway.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
    # Rolls a deployment whose tasks keep failing (bad image, an
    # unbootable config) back to the last steady state instead of
    # relaunching failing tasks forever.
  }

  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.gateway.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "gateway"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.https]
}
