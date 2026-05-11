resource "random_password" "master_key" {
  length      = 48
  special     = false
  min_lower   = 4
  min_upper   = 4
  min_numeric = 4
}

# Master DB password — used once to bootstrap the IAM-authed application
# user (see rds.tf header). Runtime services authenticate via IAM tokens
# and never read this secret.
resource "random_password" "db_master_password" {
  length      = 32
  special     = false
  min_lower   = 4
  min_upper   = 4
  min_numeric = 4
}

# LITELLM_MASTER_KEY — must begin with `sk-` per the proxy's validator.
resource "aws_secretsmanager_secret" "master_key" {
  name                    = "${var.name}-master-key"
  description             = "LITELLM_MASTER_KEY for gateway + backend."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id     = aws_secretsmanager_secret.master_key.id
  secret_string = "sk-${random_password.master_key.result}"
}

resource "aws_secretsmanager_secret" "db_master_password" {
  name                    = "${var.name}-db-master-password"
  description             = "Aurora master-user password — bootstrap only. Runtime auth is IAM-token."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_master_password" {
  secret_id = aws_secretsmanager_secret.db_master_password.id
  secret_string = jsonencode({
    username = var.db_master_username
    password = random_password.db_master_password.result
    host     = aws_rds_cluster.this.endpoint
    port     = aws_rds_cluster.this.port
    dbname   = var.db_name
  })
}
