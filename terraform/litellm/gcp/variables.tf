variable "project" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region for VPC, Cloud SQL, Memorystore, Cloud Run, and the LB IP."
  type        = string
  default     = "us-central1"
}

variable "name" {
  description = "Name prefix used for every GCP resource the stack creates."
  type        = string
  default     = "litellm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be 2-31 chars, lower-kebab-case, starting with a letter."
  }
}

variable "labels" {
  description = "Resource labels merged into every label-supporting resource."
  type        = map(string)
  default = {
    "managed-by" = "terraform"
  }
}

# ---------- Networking ----------

variable "subnet_cidr" {
  description = "Primary CIDR block for the LiteLLM subnet."
  type        = string
  default     = "10.40.0.0/16"
}

variable "vpc_connector_cidr" {
  description = "CIDR for the Serverless VPC Access connector. /28 required."
  type        = string
  default     = "10.41.0.0/28"
}

# ---------- Component images ----------
#
# Cloud Run can pull from Artifact Registry, gcr.io, or any public registry
# that doesn't require authentication. The defaults below use the public
# GHCR images. For private images hosted elsewhere, mirror to Artifact
# Registry first and point these vars at the AR URIs.

variable "gateway_image" {
  description = "Container image for the gateway. Public images or Artifact Registry only — Cloud Run won't authenticate against arbitrary private registries."
  type        = string
  default     = "ghcr.io/berriai/litellm-gateway:main-stable"
}

variable "backend_image" {
  description = "Container image for the backend."
  type        = string
  default     = "ghcr.io/berriai/litellm-backend:main-stable"
}

variable "ui_image" {
  description = "Container image for the UI."
  type        = string
  default     = "ghcr.io/berriai/litellm-ui:main-stable"
}

# ---------- Service sizing ----------

variable "gateway_cpu" {
  description = "Cloud Run CPU per gateway instance."
  type        = string
  default     = "1000m"
}

variable "gateway_memory" {
  description = "Cloud Run memory per gateway instance."
  type        = string
  default     = "2Gi"
}

variable "gateway_min_instances" {
  type    = number
  default = 1
}

variable "gateway_max_instances" {
  type    = number
  default = 10
}

variable "backend_cpu" {
  type    = string
  default = "500m"
}

variable "backend_memory" {
  type    = string
  default = "1Gi"
}

variable "backend_min_instances" {
  type    = number
  default = 1
}

variable "backend_max_instances" {
  type    = number
  default = 4
}

variable "ui_cpu" {
  type    = string
  default = "250m"
}

variable "ui_memory" {
  type    = string
  default = "256Mi"
}

variable "ui_min_instances" {
  type    = number
  default = 1
}

variable "ui_max_instances" {
  type    = number
  default = 3
}

# ---------- Cloud SQL ----------

variable "db_tier" {
  description = "Cloud SQL tier (machine type) for the writer instance."
  type        = string
  default     = "db-custom-2-7680"
}

variable "db_version" {
  description = "Cloud SQL Postgres version."
  type        = string
  default     = "POSTGRES_16"
}

variable "db_name" {
  description = "Initial database created on the Cloud SQL instance."
  type        = string
  default     = "litellm"
}

variable "db_username" {
  description = "Application Postgres user (password-auth). Password is auto-generated and stored in Secret Manager."
  type        = string
  default     = "litellm_app"
}

# ---------- Memorystore (Redis) ----------

variable "redis_tier" {
  description = "Memorystore tier — STANDARD_HA for production, BASIC for dev."
  type        = string
  default     = "STANDARD_HA"
}

variable "redis_memory_size_gb" {
  type    = number
  default = 1
}

# ---------- Extras / proxy_config ----------

variable "gateway_extra_env" {
  description = "Plain-text env vars layered onto the gateway."
  type        = map(string)
  default     = {}
}

variable "backend_extra_env" {
  description = "Plain-text env vars layered onto the backend."
  type        = map(string)
  default     = {}
}

variable "gateway_extra_secrets" {
  description = <<-EOT
    Extra env vars sourced from Google Secret Manager, applied to the gateway.
    Map of env-var name to the Secret Manager resource ID
    (`projects/<project>/secrets/<name>` — version defaults to `latest`,
    append `/versions/<n>` to pin).

    Example:
      gateway_extra_secrets = {
        OPENAI_API_KEY = "projects/my-proj/secrets/openai-api-key"
      }

    The Cloud Run service account auto-gains roles/secretmanager.secretAccessor
    on each secret listed here.
  EOT
  type        = map(string)
  default     = {}
}

variable "backend_extra_secrets" {
  description = "Same shape as gateway_extra_secrets, layered onto the backend."
  type        = map(string)
  default     = {}
}

variable "proxy_config" {
  description = <<-EOT
    LiteLLM proxy config (contents of config.yaml). Mirrors the helm chart's
    `gateway.config.proxy_config`. Passed to gateway, backend, and the
    migration job as a base64-encoded env var and decoded to
    /tmp/litellm-config.yaml at container start; CONFIG_FILE_PATH is set
    automatically. Reference env-injected secrets from the YAML via
    `os.environ/<NAME>`. Leave empty ({}) to skip.
  EOT
  type        = any
  default     = {}
}
