resource "random_password" "master_key" {
  length      = 48
  special     = false
  min_lower   = 4
  min_upper   = 4
  min_numeric = 4
}

# LITELLM_MASTER_KEY (sk-…) lives in Secret Manager. The Cloud Run service
# account gets accessor permission on it (see iam.tf).
resource "google_secret_manager_secret" "master_key" {
  secret_id = "${var.name}-master-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "master_key" {
  secret      = google_secret_manager_secret.master_key.id
  secret_data = "sk-${random_password.master_key.result}"
}
