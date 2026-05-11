resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/ecs/${var.name}/gateway"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.name}/backend"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "ui" {
  name              = "/ecs/${var.name}/ui"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "migrations" {
  name              = "/ecs/${var.name}/migrations"
  retention_in_days = var.log_retention_days
}

# Shared env block fed to gateway, backend, and the migration task. Mirrors
# the helm chart's `litellm.serverEnv` helper on the IAM-auth branch:
# DATABASE_URL is assembled at runtime by
# litellm/proxy/auth/rds_iam_token.py::init_iam_db_url_from_env from
# HOST/PORT/USER/NAME plus an IAM-signed token, so no DB password is needed
# in the task definition.
locals {
  shared_env = [
    { name = "IAM_TOKEN_DB_AUTH", value = "true" },
    { name = "DATABASE_HOST", value = aws_rds_cluster.this.endpoint },
    { name = "DATABASE_PORT", value = tostring(aws_rds_cluster.this.port) },
    { name = "DATABASE_USER", value = var.db_username },
    { name = "DATABASE_NAME", value = var.db_name },
    { name = "DATABASE_HOST_READ_REPLICA", value = aws_rds_cluster.this.reader_endpoint },
    { name = "DATABASE_PORT_READ_REPLICA", value = tostring(aws_rds_cluster.this.port) },
    { name = "REDIS_HOST", value = aws_elasticache_cluster.this.cache_nodes[0].address },
    { name = "REDIS_PORT", value = tostring(aws_elasticache_cluster.this.cache_nodes[0].port) },
    # S3 bucket — referenced from proxy_config via os.environ/S3_BUCKET_NAME
    # (e.g. cache backend, request log archival, /files passthrough).
    { name = "S3_BUCKET_NAME", value = aws_s3_bucket.this.bucket },
    { name = "S3_REGION_NAME", value = var.region },
    # boto3 inside generate_iam_auth_token reads AWS_REGION_NAME first, then
    # AWS_REGION. Set both for compatibility.
    { name = "AWS_REGION", value = var.region },
    { name = "AWS_REGION_NAME", value = var.region },
  ]

  shared_secrets = [
    { name = "LITELLM_MASTER_KEY", valueFrom = aws_secretsmanager_secret.master_key.arn },
  ]

  gateway_extra_env_list = [
    for k, v in var.gateway_extra_env : { name = k, value = v }
  ]
  backend_extra_env_list = [
    for k, v in var.backend_extra_env : { name = k, value = v }
  ]
  gateway_extra_secrets_list = [
    for k, v in var.gateway_extra_secrets : { name = k, valueFrom = v }
  ]
  backend_extra_secrets_list = [
    for k, v in var.backend_extra_secrets : { name = k, valueFrom = v }
  ]

  # Mirrors the helm chart's gateway.config.create / configmap pattern.
  # ECS Fargate has no ConfigMap analogue, so we pass the YAML as a
  # base64-encoded env var and decode it at container start via a tiny
  # python shim that prepends the image's normal uvicorn entrypoint.
  proxy_config_enabled = length(keys(var.proxy_config)) > 0
  proxy_config_b64     = local.proxy_config_enabled ? base64encode(yamlencode(var.proxy_config)) : ""

  proxy_config_env = local.proxy_config_enabled ? [
    { name = "LITELLM_PROXY_CONFIG_B64", value = local.proxy_config_b64 },
    { name = "CONFIG_FILE_PATH", value = "/tmp/litellm-config.yaml" },
  ] : []

  # Container definition overrides — only emit entryPoint/command when
  # proxy_config is provided, so the image's defaults stay authoritative
  # in the no-config case.
  gateway_proxy_overrides = local.proxy_config_enabled ? {
    entryPoint = ["sh", "-c"]
    command = [
      "python -c \"import os, base64, pathlib; pathlib.Path(os.environ['CONFIG_FILE_PATH']).write_bytes(base64.b64decode(os.environ['LITELLM_PROXY_CONFIG_B64']))\" && exec uvicorn gateway.main:app --host 0.0.0.0 --port 4000"
    ]
  } : {}

  backend_proxy_overrides = local.proxy_config_enabled ? {
    entryPoint = ["sh", "-c"]
    command = [
      "python -c \"import os, base64, pathlib; pathlib.Path(os.environ['CONFIG_FILE_PATH']).write_bytes(base64.b64decode(os.environ['LITELLM_PROXY_CONFIG_B64']))\" && exec uvicorn backend.main:app --host 0.0.0.0 --port 4001"
    ]
  } : {}
}

# ---------- Gateway ----------
resource "aws_ecs_task_definition" "gateway" {
  family                   = "${var.name}-gateway"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.gateway_cpu
  memory                   = var.gateway_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    merge(
      {
        name      = "gateway"
        image     = var.gateway_image
        essential = true

        portMappings = [{ containerPort = 4000, protocol = "tcp" }]
        environment = concat(
          local.shared_env,
          local.gateway_extra_env_list,
          local.proxy_config_env,
        )
        secrets = concat(local.shared_secrets, local.gateway_extra_secrets_list)

        # Container-level healthCheck intentionally omitted — the wolfi
        # runtime image doesn't ship curl/wget. The ALB target group polls
        # /health/readiness.

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.gateway.name
            awslogs-region        = var.region
            awslogs-stream-prefix = "gateway"
          }
        }
      },
      local.gateway_proxy_overrides,
    )
  ])
}

resource "aws_ecs_service" "gateway" {
  name            = "${var.name}-gateway"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = var.gateway_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "gateway"
    container_port   = 4000
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [aws_lb_listener.http]
}

# ---------- Backend ----------
resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.name}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.backend_cpu
  memory                   = var.backend_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    merge(
      {
        name      = "backend"
        image     = var.backend_image
        essential = true

        portMappings = [{ containerPort = 4001, protocol = "tcp" }]
        environment = concat(
          local.shared_env,
          local.backend_extra_env_list,
          local.proxy_config_env,
        )
        secrets = concat(local.shared_secrets, local.backend_extra_secrets_list)

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.backend.name
            awslogs-region        = var.region
            awslogs-stream-prefix = "backend"
          }
        }
      },
      local.backend_proxy_overrides,
    )
  ])
}

resource "aws_ecs_service" "backend" {
  name            = "${var.name}-backend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.backend_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 4001
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [aws_lb_listener.http]
}

# ---------- UI ----------
resource "aws_ecs_task_definition" "ui" {
  family                   = "${var.name}-ui"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.ui_cpu
  memory                   = var.ui_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name         = "ui"
      image        = var.ui_image
      essential    = true
      portMappings = [{ containerPort = 3000, protocol = "tcp" }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ui.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ui"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "ui" {
  name            = "${var.name}-ui"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.ui.arn
  desired_count   = var.ui_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ui.arn
    container_name   = "ui"
    container_port   = 3000
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [aws_lb_listener.http]
}
