# One-off task definition that runs `python litellm/proxy/prisma_migration.py`
# against the writer DB using IAM auth. The chart's post-install Helm hook
# runs the same script.
#
# Bootstrap order on first apply:
#   1. terraform apply
#   2. Connect as the master DB user (password in `db_master_password_secret_arn`)
#      and run the bootstrap SQL printed in `db_bootstrap_sql`.
#   3. eval "$(terraform output -raw migration_run_command)"
resource "aws_ecs_task_definition" "migrations" {
  family                   = "${var.name}-migrations"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    merge(
      {
        name      = "migrations"
        image     = var.backend_image
        essential = true

        environment = concat(
          local.shared_env,
          local.proxy_config_env,
          [{ name = "DISABLE_SCHEMA_UPDATE", value = "false" }],
        )
        secrets = local.shared_secrets

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.migrations.name
            awslogs-region        = var.region
            awslogs-stream-prefix = "migrations"
          }
        }
      },
      # Override entrypoint to run prisma_migration.py instead of the
      # image's default uvicorn invocation. When proxy_config is provided,
      # also write the decoded YAML to /tmp before the migration runs (the
      # migration script imports proxy_server which reads CONFIG_FILE_PATH).
      local.proxy_config_enabled ? {
        entryPoint = ["sh", "-c"]
        command = [
          "python -c \"import os, base64, pathlib; pathlib.Path(os.environ['CONFIG_FILE_PATH']).write_bytes(base64.b64decode(os.environ['LITELLM_PROXY_CONFIG_B64']))\" && exec python litellm/proxy/prisma_migration.py"
        ]
        } : {
        entryPoint = ["python"]
        command    = ["litellm/proxy/prisma_migration.py"]
      },
    )
  ])
}
