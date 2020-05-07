output "endpoint" {
  value = google_container_cluster.gke.endpoint
}

output "client_certificate" {
  value = google_container_cluster.gke.master_auth.0.client_certificate
}

output "client_key" {
  value = google_container_cluster.gke.master_auth.0.client_key
}

output "ca_certificate" {
  value = google_container_cluster.gke.master_auth.0.cluster_ca_certificate
}

output "cluster_name" {
  value = google_container_cluster.gke.name
}

