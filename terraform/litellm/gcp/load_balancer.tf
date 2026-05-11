# External global HTTP(S) load balancer fronting all three Cloud Run
# services. URL map mirrors the helm-chart ingress path routing:
#   - LLM data-plane paths → gateway
#   - UI asset paths → ui
#   - Everything else → backend (management API: /key/*, /user/*, …)
#
# The LB exposes plain HTTP on port 80 by default. Add an
# google_compute_managed_ssl_certificate + 443 forwarding rule to layer TLS.

resource "google_compute_global_address" "lb" {
  name = "${var.name}-lb-ip"
}

# Serverless NEGs — one per Cloud Run service.
resource "google_compute_region_network_endpoint_group" "gateway" {
  name                  = "${var.name}-gateway-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.gateway.name
  }
}

resource "google_compute_region_network_endpoint_group" "backend" {
  name                  = "${var.name}-backend-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.backend.name
  }
}

resource "google_compute_region_network_endpoint_group" "ui" {
  name                  = "${var.name}-ui-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.ui.name
  }
}

# Backend services wrap each NEG.
resource "google_compute_backend_service" "gateway" {
  name                  = "${var.name}-gateway-bs"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.gateway.id
  }
}

resource "google_compute_backend_service" "backend" {
  name                  = "${var.name}-backend-bs"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.backend.id
  }
}

resource "google_compute_backend_service" "ui" {
  name                  = "${var.name}-ui-bs"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.ui.id
  }
}

# URL map. Default → backend (management API). Path matchers route the
# gateway and UI prefixes elsewhere.
resource "google_compute_url_map" "this" {
  name            = var.name
  default_service = google_compute_backend_service.backend.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "main"
  }

  path_matcher {
    name            = "main"
    default_service = google_compute_backend_service.backend.id

    # UI paths (catch them before any /v1/* gateway rules so /favicon.ico
    # and / take precedence).
    path_rule {
      paths   = local.ui_path_prefixes
      service = google_compute_backend_service.ui.id
    }

    # Gateway path prefixes. GCP URL maps cap a path_rule at 10 path globs,
    # so chunk into rules of 10.
    dynamic "path_rule" {
      for_each = { for idx, chunk in chunklist(local.gateway_path_prefixes, 10) : idx => chunk }
      content {
        paths   = path_rule.value
        service = google_compute_backend_service.gateway.id
      }
    }
  }
}

resource "google_compute_target_http_proxy" "this" {
  name    = "${var.name}-http"
  url_map = google_compute_url_map.this.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name}-http"
  ip_protocol           = "TCP"
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb.address
  target                = google_compute_target_http_proxy.this.id
}
