# Módulo: Cloud DNS
# Ref CAF: Standard 04 - Resource Organization

variable "project_id" { type = string }
variable "zone_name" { type = string }
variable "dns_name" { type = string }

resource "google_dns_managed_zone" "zone" {
  name     = var.zone_name
  dns_name = var.dns_name
  project  = var.project_id

  visibility = "public"
}

output "name_servers" {
  value = google_dns_managed_zone.zone.name_servers
}
