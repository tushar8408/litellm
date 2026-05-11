# Aurora Postgres cluster with one writer + one reader instance, IAM
# database authentication enabled.
#
# Important: enabling IAM auth on the cluster does not by itself grant any
# Postgres user the ability to log in with an IAM token. After the first
# apply, connect as the master user (password lives in Secrets Manager —
# see `master_user_secret_arn` in outputs) and run, once:
#
#   CREATE USER {var.db_username};
#   GRANT rds_iam TO {var.db_username};
#   GRANT ALL PRIVILEGES ON DATABASE {var.db_name} TO {var.db_username};
#   GRANT ALL ON SCHEMA public TO {var.db_username};
#
# After that, the gateway/backend/migration tasks (which authenticate as
# `{var.db_username}` via IAM-signed tokens) can connect. The master user
# itself is a superuser and Postgres refuses to grant `rds_iam` to
# superusers — keep it for break-glass only.

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_rds_cluster_parameter_group" "this" {
  name        = "${var.name}-cluster-pg"
  family      = "aurora-postgresql${split(".", var.db_engine_version)[0]}"
  description = "LiteLLM Aurora Postgres cluster parameters."
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = var.name
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = var.db_engine_version
  database_name                   = var.db_name
  master_username                 = var.db_master_username
  master_password                 = random_password.db_master_password.result
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.rds.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  iam_database_authentication_enabled = true
  storage_encrypted                   = true
  skip_final_snapshot                 = true
  apply_immediately                   = true

  backup_retention_period = 7
  preferred_backup_window = "07:00-09:00"
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.name}-writer"
  cluster_identifier = aws_rds_cluster.this.id
  instance_class     = var.db_instance_class
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version

  publicly_accessible          = false
  performance_insights_enabled = true

  # Promotion tier 0 — first in line during failover, so this instance stays
  # the writer unless it goes unhealthy.
  promotion_tier = 0
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.name}-reader"
  cluster_identifier = aws_rds_cluster.this.id
  instance_class     = var.db_instance_class
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version

  publicly_accessible          = false
  performance_insights_enabled = true

  # Higher promotion tier — won't be picked as writer during a failover
  # unless the writer instance itself is gone.
  promotion_tier = 15
}
