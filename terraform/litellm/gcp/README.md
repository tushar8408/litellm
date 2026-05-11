# LiteLLM on GCP (Cloud Run)

Deploys the componentized LiteLLM proxy on GCP:

- **VPC** + Private Services Access range + a Serverless VPC Access connector
  so Cloud Run can reach private IPs
- **Cloud SQL for PostgreSQL** — primary instance + cross-zone read replica,
  password auth via Secret Manager
- **Memorystore (Redis)** for caching + rate limiting, private IP only
- **GCS bucket** — private, versioned, uniform IAM; exposed as `GCS_BUCKET_NAME`
- **Secret Manager** entries for `LITELLM_MASTER_KEY` and `DATABASE_PASSWORD`
- **Cloud Run v2** services for `gateway` (port 4000), `backend` (port 4001),
  and `ui` (port 3000), all using a shared runtime service account
- **Cloud Run Job** (`litellm-migrations`) that runs `python litellm/proxy/prisma_migration.py`
- **External global HTTP(S) load balancer** with serverless NEGs and a URL
  map mirroring the helm-chart ingress path routing:
  - LLM data-plane prefixes → `gateway`
  - UI asset paths → `ui`
  - Everything else → `backend`

## Image pulls

The defaults pull from `ghcr.io/berriai/litellm-<component>:main-stable`,
which is public. Cloud Run only authenticates against Artifact Registry
and `gcr.io`-style registries, so for private images hosted elsewhere
mirror them into Artifact Registry first:

```bash
for c in gateway backend ui; do
  docker pull <source-registry>/litellm-$c:<tag>
  docker tag  <source-registry>/litellm-$c:<tag> \
              us-central1-docker.pkg.dev/$PROJECT/litellm/$c:<tag>
  docker push us-central1-docker.pkg.dev/$PROJECT/litellm/$c:<tag>
done
```

Then point `gateway_image` / `backend_image` / `ui_image` in tfvars at the
Artifact Registry URIs.

## Database authentication

LiteLLM's `init_iam_db_url_from_env()` mints **AWS RDS** tokens via boto3 —
it doesn't speak GCP IAM. To IAM-auth against Cloud SQL from Cloud Run you'd
need the Cloud SQL Auth Proxy as a sidecar, which complicates the service
spec. This stack therefore uses **password authentication**:

- A random password is generated and stored in Secret Manager
  (`<name>-db-password`).
- Each Cloud Run service receives the password as `DATABASE_PASSWORD` via
  `value_source.secret_key_ref`.
- The container's entrypoint shim assembles `DATABASE_URL` (and
  `DATABASE_URL_READ_REPLICA`) from `DATABASE_HOST` / `DATABASE_PASSWORD`
  before exec'ing uvicorn — so the password never appears in the service
  spec or in logs.

If you need GCP-native IAM auth later, add `cloud-sql-proxy` as a sidecar
container under `template.template.containers` (Cloud Run v2 supports
multiple containers) and replace the password-based URL with the proxy's
Unix socket.

## Configuring the proxy

### `proxy_config`

Mirrors the helm chart's `gateway.config.proxy_config`. The map is
YAML-encoded and base64-passed to gateway, backend, and the migration job;
each container decodes it to `/tmp/litellm-config.yaml` at startup and sets
`CONFIG_FILE_PATH`.

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

LiteLLM resolves `os.environ/<NAME>` references against the container
environment. Provider API keys belong in `*_extra_secrets` and are
referenced from the YAML by env-var name.

### Extra env / secrets

Non-sensitive env vars:

```hcl
gateway_extra_env = {
  LANGFUSE_HOST = "https://us.cloud.langfuse.com"
}
```

Sensitive values — create the secret in Secret Manager first, then reference
its resource ID:

```bash
echo -n "sk-proj-..." | gcloud secrets create openai-api-key --data-file=-
```

```hcl
gateway_extra_secrets = {
  OPENAI_API_KEY = "projects/my-gcp-project/secrets/openai-api-key"
}
```

The Cloud Run runtime SA auto-gains `roles/secretmanager.secretAccessor` on
every secret referenced. To pin a specific version, change the value from
`projects/.../secrets/openai-api-key` to `projects/.../secrets/openai-api-key/versions/3`
— but note the var spec accepts the secret ID; the version always defaults
to `latest` (override by editing `local.gateway_extra_secret_kv` in
`cloudrun.tf` if you need otherwise).

## Quick start

```bash
cd terraform/gcp
cp terraform.tfvars.example terraform.tfvars
# Edit: project, region, name, *_image, proxy_config, gateway_extra_secrets.

terraform init
terraform apply

# Run the migration once before serving traffic:
eval "$(terraform output -raw migration_run_command)"

# Open the LB URL:
terraform output lb_url
```

## Adding TLS

Replace `google_compute_target_http_proxy` / `google_compute_global_forwarding_rule.http`
with the HTTPS variants and attach a `google_compute_managed_ssl_certificate`:

```hcl
resource "google_compute_managed_ssl_certificate" "this" {
  name = "litellm-cert"
  managed { domains = ["proxy.example.com"] }
}

resource "google_compute_target_https_proxy" "this" {
  name             = "litellm-https"
  url_map          = google_compute_url_map.this.id
  ssl_certificates = [google_compute_managed_ssl_certificate.this.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "litellm-https"
  ip_protocol           = "TCP"
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.address
  target                = google_compute_target_https_proxy.this.id
}
```

## Files

| File              | What's in it                                                         |
| ----------------- | -------------------------------------------------------------------- |
| `versions.tf`     | Terraform + provider version constraints                             |
| `providers.tf`    | Google + Google-Beta providers                                       |
| `variables.tf`    | All input variables                                                  |
| `locals.tf`       | Path-prefix lists (mirror of `helm/.../ingress.yaml`) + proxy_config helpers |
| `network.tf`      | VPC, subnet, PSA range, Serverless VPC connector                     |
| `secrets.tf`      | Secret Manager entries + random master_key                           |
| `cloudsql.tf`     | Cloud SQL writer + read replica + app user + password secret         |
| `redis.tf`        | Memorystore Redis (private IP)                                       |
| `gcs.tf`          | GCS bucket + objectAdmin binding                                     |
| `iam.tf`          | Runtime SA + Cloud SQL client + Secret Manager accessor              |
| `cloudrun.tf`     | 3 Cloud Run services + Cloud Run Job for migrations                  |
| `load_balancer.tf`| External HTTPS LB, serverless NEGs, URL map for path routing         |
| `outputs.tf`      | LB IP, service URLs, secret IDs, migration `execute` command         |
