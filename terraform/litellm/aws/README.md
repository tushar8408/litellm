# LiteLLM on AWS (ECS Fargate)

Deploys the componentized LiteLLM proxy on AWS:

- **VPC** with public + private subnets across the AZs you pass in, one NAT gateway
- **Aurora Postgres** cluster — one writer instance + one reader instance, **IAM database authentication enabled**
- **ElastiCache Redis** (private) for caching + rate limiting
- **S3 bucket** (private, versioned, SSE-S3) — exposed to gateway + backend as `S3_BUCKET_NAME` / `S3_REGION_NAME` for cache backend, request log archival, and `/v1/files` storage
- **Secrets Manager** entries for `LITELLM_MASTER_KEY` (auto-generated, `sk-…`) and the Aurora master password (bootstrap-only)
- **ECS Fargate cluster** running three services — `gateway`, `backend`, `ui`
- **Application Load Balancer** (public, HTTP/80) with path-based routing:
  - LLM data-plane prefixes (`/v1/chat/*`, `/v1/embeddings`, …) → `gateway`
  - UI assets (`/`, `/_next/*`, `/litellm-asset-prefix/*`, …) → `ui`
  - Everything else (management API: `/key/*`, `/user/*`, …) → `backend`
- **One-off migration task** (`litellm-migrations`) that runs `python litellm/proxy/prisma_migration.py`

## Aurora + IAM auth (read this before the first apply)

The cluster is created with `iam_database_authentication_enabled = true`, but
**enabling IAM auth does not by itself give any user the ability to log in
with an IAM token**. After `terraform apply`, you have to bootstrap the app
user once:

1. Fetch the master password:
   ```bash
   aws secretsmanager get-secret-value \
     --secret-id "$(terraform output -raw db_master_password_secret_arn)" \
     --query SecretString --output text | jq .
   ```

2. From inside the VPC (bastion / SSM session / VPN), connect to the writer
   endpoint as the master user (default `postgres`) and run the bootstrap SQL
   printed in `db_bootstrap_sql`:
   ```bash
   terraform output -raw db_bootstrap_sql | psql "$(WRITER_ENDPOINT)"
   ```
   The SQL is idempotent-ish — re-running `CREATE USER` after the first apply
   will throw "role already exists", which is harmless. Either swap to
   `CREATE USER … IF NOT EXISTS` style or just ignore that one error.

3. Run the one-off migration task:
   ```bash
   eval "$(terraform output -raw migration_run_command)"
   ```

4. The gateway/backend services pick up the new schema at next pull (or
   trigger a forced redeploy with `aws ecs update-service --force-new-deployment …`).

The proxy assembles `DATABASE_URL` from `DATABASE_HOST/PORT/USER/NAME` plus a
short-lived IAM token at startup — see `litellm/proxy/auth/rds_iam_token.py`.
The task role created here has `rds-db:connect` scoped to the IAM-authed user
on the Aurora cluster resource ID.

## Configuring the proxy

### `proxy_config` (preferred)

Mirrors the helm chart's `gateway.config.proxy_config`. The map is YAML-encoded
and base64-passed to gateway, backend, and the migration task; each container
decodes it to `/tmp/litellm-config.yaml` at startup and sets `CONFIG_FILE_PATH`
to match.

```hcl
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
    master_key   = "os.environ/LITELLM_MASTER_KEY"
    database_url = "os.environ/DATABASE_URL"
  }
}
```

LiteLLM resolves `os.environ/<NAME>` references in the YAML against the
container's environment. That means provider API keys belong in
`*_extra_secrets` (next section), and your YAML just references them by name.

### Extra env vars

Non-sensitive plaintext (feature flags, observability hosts, etc.):

```hcl
gateway_extra_env = {
  LANGFUSE_HOST = "https://us.cloud.langfuse.com"
}
backend_extra_env = {
  STORE_MODEL_IN_DB = "True"
}
```

### Extra secrets (API keys)

Sensitive values — provider API keys, third-party tokens — live in **existing
Secrets Manager secrets**. Reference them by ARN:

```hcl
gateway_extra_secrets = {
  OPENAI_API_KEY    = "arn:aws:secretsmanager:us-west-2:111122223333:secret:openai-api-key-AbCdEf"
  ANTHROPIC_API_KEY = "arn:aws:secretsmanager:us-west-2:111122223333:secret:anthropic-api-key-GhIjKl"
}
```

What happens under the hood:
- The execution role auto-gains `secretsmanager:GetSecretValue` on every ARN
  listed here.
- ECS resolves each secret at task launch and injects its value into the
  container as the env var named on the left.
- The `proxy_config` YAML references the resulting env var via
  `os.environ/OPENAI_API_KEY`.

To pluck a single field out of a JSON secret, use ECS's `:fieldName::` suffix:

```hcl
gateway_extra_secrets = {
  OPENAI_API_KEY = "arn:…:secret:provider-keys-AbCdEf:openai_api_key::"
}
```

To create the secret beforehand:

```bash
aws secretsmanager create-secret \
  --name openai-api-key \
  --secret-string "sk-proj-..."
```

## Quick start

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
# Edit: region, name, azs, *_image, proxy_config, gateway_extra_secrets.

terraform init
terraform apply

# 1. Bootstrap the IAM-authed Postgres user (see "Aurora + IAM auth" above).
# 2. Run the migration:
eval "$(terraform output -raw migration_run_command)"

# Open the ALB URL:
terraform output alb_url
```

## Image pulls

The defaults pull from `ghcr.io/berriai/litellm-<component>:main-stable`,
which is anonymous-readable. To pull from a private registry:

- **ECR (same account)**: the execution role already has
  `AmazonECSTaskExecutionRolePolicy`, which grants ECR pull for repos in
  the same account. No extra config needed.
- **ECR (cross-account)**: attach a policy to the execution role allowing
  `ecr:GetAuthorizationToken` + `ecr:BatchGetImage` on the foreign repo
  ARNs.
- **Other private registries** (GHCR with a PAT, Docker Hub, …): create a
  secret holding `{"auths":{"<registry>":{"auth":"<base64-user:token>"}}}`
  in Secrets Manager and set `repositoryCredentials.credentialsParameter`
  on the task def container — extend `ecs.tf` accordingly.

## Adding TLS

The ALB listens on plain HTTP/80 by default. To add HTTPS:

1. Create or import an ACM cert in `var.region`.
2. Add an `aws_lb_listener` for port 443 forwarding to the same default
   action and rules — or replace `aws_lb_listener.http` with a listener
   that redirects 80 → 443 plus a 443 listener carrying the existing rules.

## Files

| File              | What's in it                                                          |
| ----------------- | --------------------------------------------------------------------- |
| `versions.tf`     | Terraform + provider version constraints                              |
| `providers.tf`    | AWS provider (region + default tags)                                  |
| `variables.tf`    | All input variables                                                   |
| `locals.tf`       | Path-prefix lists for ALB routing (mirror of `helm/.../ingress.yaml`) |
| `network.tf`      | VPC, subnets, IGW, NAT, route tables, security groups                 |
| `secrets.tf`      | Secrets Manager entries + random passwords                            |
| `rds.tf`          | Aurora Postgres cluster + writer / reader instances                   |
| `redis.tf`        | ElastiCache Redis                                                     |
| `s3.tf`           | S3 bucket + task-role policy scoped to it                             |
| `iam.tf`          | Task execution + task roles, including `rds-db:connect`               |
| `ecs.tf`          | ECS cluster, task definitions, services for the three components     |
| `alb.tf`          | ALB, listener, target groups, path-routing rules                      |
| `migrations.tf`   | One-off migration task definition                                     |
| `outputs.tf`      | DNS name, secret ARN, bootstrap SQL, migration `run-task` command     |
