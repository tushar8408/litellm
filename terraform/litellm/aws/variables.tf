variable "region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "name" {
  description = "Name prefix used for every AWS resource the stack creates."
  type        = string
  default     = "litellm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be 2-31 chars, lower-kebab-case, starting with a letter."
  }
}

variable "tags" {
  description = "Additional tags merged into the provider default_tags."
  type        = map(string)
  default     = {}
}

# ---------- Networking ----------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across. At least 2 required for RDS and ALB."
  type        = list(string)
  validation {
    condition     = length(var.azs) >= 2
    error_message = "Provide at least 2 availability zones."
  }
}

# ---------- Component images ----------
#
# Defaults point at the public `main-stable` tag on GHCR for a zero-config
# trial. Pin to a specific tag (e.g. a versioned release) for production
# so deploys are reproducible.

variable "gateway_image" {
  description = "Container image for the gateway (data plane, port 4000)."
  type        = string
  default     = "ghcr.io/berriai/litellm-gateway:main-stable"
}

variable "backend_image" {
  description = "Container image for the backend (management API, port 4001)."
  type        = string
  default     = "ghcr.io/berriai/litellm-backend:main-stable"
}

variable "ui_image" {
  description = "Container image for the UI (nginx static export, port 3000)."
  type        = string
  default     = "ghcr.io/berriai/litellm-ui:main-stable"
}

# ---------- Service sizing ----------

variable "gateway_cpu" {
  description = "Fargate CPU units for the gateway task (1024 = 1 vCPU)."
  type        = number
  default     = 1024
}

variable "gateway_memory" {
  description = "Fargate memory (MiB) for the gateway task."
  type        = number
  default     = 4096
}

variable "gateway_desired_count" {
  description = "Desired number of gateway tasks."
  type        = number
  default     = 2
}

variable "backend_cpu" {
  description = "Fargate CPU units for the backend task."
  type        = number
  default     = 512
}

variable "backend_memory" {
  description = "Fargate memory (MiB) for the backend task."
  type        = number
  default     = 1024
}

variable "backend_desired_count" {
  description = "Desired number of backend tasks."
  type        = number
  default     = 1
}

variable "ui_cpu" {
  description = "Fargate CPU units for the UI task."
  type        = number
  default     = 256
}

variable "ui_memory" {
  description = "Fargate memory (MiB) for the UI task."
  type        = number
  default     = 512
}

variable "ui_desired_count" {
  description = "Desired number of UI tasks."
  type        = number
  default     = 1
}

# ---------- RDS ----------

variable "db_instance_class" {
  description = "Aurora instance class for both writer and reader."
  type        = string
  default     = "db.r6g.large"
}

variable "db_engine_version" {
  description = "Aurora Postgres engine version. Major version drives the parameter-group family (aurora-postgresql<major>)."
  type        = string
  default     = "16.4"
}

variable "db_name" {
  description = "Initial database name created on the Aurora cluster."
  type        = string
  default     = "litellm"
}

variable "db_master_username" {
  description = "Aurora master (superuser) username — used only to bootstrap the IAM-authed application user."
  type        = string
  default     = "postgres"
}

variable "db_username" {
  description = "IAM-authed Postgres user the proxy connects as. Must be CREATEd in the cluster and granted the rds_iam role — see terraform/aws/README.md."
  type        = string
  default     = "litellm_app"
}

# ---------- Redis ----------

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t4g.small"
}

# ---------- Extra env ----------

variable "gateway_extra_env" {
  description = <<-EOT
    Additional plain-text env vars for the gateway container. Use this for
    non-sensitive config (LANGFUSE_HOST, custom feature flags, …). For API
    keys, use gateway_extra_secrets instead.
  EOT
  type        = map(string)
  default     = {}
}

variable "backend_extra_env" {
  description = "Additional plain-text env vars for the backend container."
  type        = map(string)
  default     = {}
}

variable "gateway_extra_secrets" {
  description = <<-EOT
    Extra env vars sourced from AWS Secrets Manager. Map of env-var name to
    Secrets Manager ARN. Pass the bare secret ARN to inject the whole secret
    string as the env var value, or append ":<jsonKey>::" to extract a single
    JSON field (ECS docs).

    Example for OPENAI_API_KEY:
      gateway_extra_secrets = {
        OPENAI_API_KEY = "arn:aws:secretsmanager:us-west-2:111122223333:secret:openai-api-key-AbCdEf"
      }

    The stack's task execution role automatically gains GetSecretValue on every
    ARN referenced here (suffix-stripped).
  EOT
  type    = map(string)
  default = {}
}

variable "backend_extra_secrets" {
  description = "Same shape as gateway_extra_secrets, but layered onto the backend container."
  type        = map(string)
  default     = {}
}

variable "proxy_config" {
  description = <<-EOT
    LiteLLM proxy config (the contents of config.yaml). Mirrors the helm
    chart's `gateway.config.proxy_config` value. Passed to gateway, backend,
    and the migration task as a base64-encoded env var and decoded to
    /tmp/litellm-config.yaml at container start; CONFIG_FILE_PATH is set
    automatically.

    Example:
      proxy_config = {
        model_list = [
          {
            model_name = "gpt-4o"
            litellm_params = {
              model   = "openai/gpt-4o"
              api_key = "os.environ/OPENAI_API_KEY"
            }
          },
        ]
        general_settings = {
          master_key       = "os.environ/LITELLM_MASTER_KEY"
          database_url     = "os.environ/DATABASE_URL"
          ui_username      = "admin"
        }
      }

    Leave empty ({}) to skip mounting a config — the proxy then runs with
    defaults. Use the "os.environ/<NAME>" syntax in the YAML to reference
    env vars provided by *_extra_env or *_extra_secrets.
  EOT
  type        = any
  default     = {}
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the three services."
  type        = number
  default     = 30
}
