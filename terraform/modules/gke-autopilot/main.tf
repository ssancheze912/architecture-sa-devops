# Módulo: GKE Autopilot
# Ref CAF: Standard 03 - Preferred Services (GKE Autopilot para workloads complejos)

variable "project_id" { type = string }
variable "region" { type = string }
variable "cluster_name" { type = string }
variable "network" { type = string }
variable "subnetwork" { type = string }
variable "release_channel" {
  type    = string
  default = "REGULAR"
}
variable "master_cidr" {
  type    = string
  default = "172.16.0.0/28"
}
variable "cluster_secondary_range_name" {
  type        = string
  description = "Nombre del rango secundario de la subred para pods (requerido en Shared VPC)"
  default     = null
}
variable "services_secondary_range_name" {
  type        = string
  description = "Nombre del rango secundario de la subred para services (requerido en Shared VPC)"
  default     = null
}
variable "labels" { type = map(string) }

resource "google_container_cluster" "autopilot" {
  provider = google-beta

  name     = var.cluster_name
  location = var.region
  project  = var.project_id

  enable_autopilot = true

  network    = var.network
  subnetwork = var.subnetwork

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {
    # En Shared VPC se requieren los nombres de rangos secundarios existentes en la subred.
    # En redes propias, GKE Autopilot los gestiona automáticamente.
    cluster_secondary_range_name  = var.cluster_secondary_range_name
    services_secondary_range_name = var.services_secondary_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  resource_labels = var.labels

  deletion_protection = true
}

output "cluster_name" {
  value = google_container_cluster.autopilot.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.autopilot.endpoint
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.autopilot.master_auth[0].cluster_ca_certificate
  sensitive = true
}
