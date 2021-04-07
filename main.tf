/*
  Terraform 12 module to create a Google Kubernetes Engine Cluster in Private mode using best practices for a secure GKE Environment
*/

// Create a random postfix for the cluster name
resource "random_id" "postfix" {
  byte_length = 4
}

resource "google_service_account" "service_account" {
  project      = var.project_id
  account_id   = "${var.prefix}-${var.name}-gke-${random_id.postfix.hex}"
  display_name = "${var.prefix}-${var.name}-gke-${random_id.postfix.hex}"
}

resource "google_container_registry" "registry" {
  project = var.project_id
}

resource "google_storage_bucket_iam_member" "viewer" {
  bucket = google_container_registry.registry.id
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "service_account_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "service_account_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "service_account_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

// Create the firewall rules to allow nodes to communicate with the master
resource "google_compute_firewall" "egress-allow-gke-node" {
  project = var.project_id
  network = var.vpc_network

  name = "${var.prefix}-gke-node-allow-egress-${random_id.postfix.hex}"

  priority  = "200"
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443", "9443", "10250", "15017", "6443"]
  }

  destination_ranges      = [var.master_ipv4_cidr_block]
  target_service_accounts = [google_service_account.service_account.email]
}

resource "google_compute_firewall" "ingress-allow-gke-node" {
  project = var.project_id
  network = var.vpc_network

  name = "${var.prefix}-gke-node-allow-ingress-${random_id.postfix.hex}"

  priority  = "200"
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443", "9443", "10250", "15017", "6443"]
  }

  source_ranges           = [var.master_ipv4_cidr_block]
  source_service_accounts = [google_service_account.service_account.email]
}

// Create firewall rules that allow the nodes access via port 80 and 443 to allow them to pull docker images
resource "google_compute_firewall" "egress-allow-gke-node-www" {
  project = var.project_id
  network = var.vpc_network

  name = "${var.prefix}-gke-node-allow-web-egress-${random_id.postfix.hex}"

  priority  = "200"
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443", "80", ]
  }

  destination_ranges = ["0.0.0.0/0"]
  target_tags        = ["egress-allow-gke-node-${random_id.postfix.hex}"]
}

// Create the GKE Cluster
resource "google_container_cluster" "gke" {
  provider = google-beta

  project  = var.project_id
  name     = "${var.prefix}-${var.name}-${random_id.postfix.hex}"
  location = var.location

  network    = var.vpc_network
  subnetwork = var.subnet

  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  min_master_version = var.gke_min_version

  remove_default_node_pool = true
  initial_node_count       = 1
  enable_shielded_nodes    = true
  enable_legacy_abac       = false

  master_auth {
    // Disable login auth to the cluster
    username = ""
    password = ""

    client_certificate_config {
      issue_client_certificate = false
    }
  }

  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }

  node_config {
    labels = {
      private-pool = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = "true"
      enable_integrity_monitoring = "true"
    }

    preemptible = false

    service_account = google_service_account.service_account.email
  }

  private_cluster_config {
    enable_private_endpoint = var.private_endpoint
    enable_private_nodes    = "true"
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.whitelist_ips
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = lookup(cidr_blocks.value, "display_name", null)
      }
    }
  }

  ip_allocation_policy {
  }

  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  addons_config {
    istio_config {
      disabled = var.istio_disabled
      auth     = "AUTH_MUTUAL_TLS"
    }

    network_policy_config {
      disabled = false
    }
  }

  lifecycle {
    ignore_changes = [master_auth]
  }

  timeouts {
    create = "30m"
    update = "40m"
    delete = "2h"
  }

  depends_on = [google_compute_firewall.egress-allow-gke-node, google_compute_firewall.ingress-allow-gke-node]
}

resource "google_container_node_pool" "nodepools" {
  project     = var.project_id
  count       = length(var.node_pools)
  name_prefix = "${var.prefix}-${var.node_pools[count.index]["name"]}-"
  location    = var.location
  cluster     = google_container_cluster.gke.name

  node_config {
    image_type   = lookup(var.node_pools[count.index], "image_type", "COS_CONTAINERD")
    machine_type = lookup(var.node_pools[count.index], "machine_type", "n1-standard-2")

    disk_size_gb = lookup(var.node_pools[count.index], "disk_size_gb", 100)
    disk_type    = lookup(var.node_pools[count.index], "disk_type", "pd-standard")

    preemptible = lookup(var.node_pools[count.index], "preemptible", false)

    guest_accelerator = [
      for guest_accelerator in lookup(var.node_pools[count.index], "accelerator_count", 0) > 0 ? [{
        type  = lookup(var.node_pools[count.index], "accelerator_type", "")
        count = lookup(var.node_pools[count.index], "accelerator_count", 0)
        }] : [] : {
        type  = guest_accelerator["type"]
        count = guest_accelerator["count"]
      }
    ]

    metadata = {
      disable-legacy-endpoints = "true"
    }

    labels = {
      private-pool = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = "true"
      enable_integrity_monitoring = "true"
    }

    service_account = google_service_account.service_account.email
  }

  initial_node_count = lookup(
    var.node_pools[count.index],
    "initial_node_count",
    lookup(var.node_pools[count.index], "min_count", 1),
  )

  node_count = lookup(var.node_pools[count.index], "autoscaling", true) ? null : lookup(var.node_pools[count.index], "min_count", 1)

  dynamic "autoscaling" {
    for_each = lookup(var.node_pools[count.index], "autoscaling", true) ? [var.node_pools[count.index]] : []
    content {
      min_node_count = lookup(autoscaling.value, "min_count", 1)
      max_node_count = lookup(autoscaling.value, "max_count", 100)
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  timeouts {
    create = "30m"
    update = "40m"
    delete = "2h"
  }

  provisioner "local-exec" {
    command = "sleep 10"
  }
  lifecycle {
    create_before_destroy = true
  }

}
