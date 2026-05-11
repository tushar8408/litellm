# Runtime SA used by all three Cloud Run services + the migration job.
resource "google_service_account" "runtime" {
  account_id   = "${var.name}-runtime"
  display_name = "LiteLLM Cloud Run runtime"
}

# Cloud SQL client — lets the Cloud Run services connect to the instance
# over private IP via the VPC connector.
resource "google_project_iam_member" "runtime_cloudsql" {
  project = var.project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# Secret Manager accessor — managed secrets first (split out as separate
# resources because their IDs are computed-at-apply and can't drive a
# for_each).
resource "google_secret_manager_secret_iam_member" "master_key" {
  secret_id = google_secret_manager_secret.master_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "db_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

# User-supplied extras. Dedupe on the secret resource ID — two different
# env-var names could reference the same secret, and we want exactly one
# IAM binding per (secret, role, member) tuple in state.
resource "google_secret_manager_secret_iam_member" "extras" {
  for_each = toset(values(merge(var.gateway_extra_secrets, var.backend_extra_secrets)))

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}
