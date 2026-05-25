# Módulo: Cloud SQL for PostgreSQL
# Ref CAF: Standard 03 - Preferred Services (Cloud SQL como alternativa a AlloyDB)

variable "project_id" { type = string }
variable "region" { type = string }
variable "instance_name" { type = string }
variable "database_name" { type = string }
variable "database_version" {
  type    = string
  default = "POSTGRES_16"
}
variable "tier" { type = string }
variable "availability" {
  type    = string
  default = "ZONAL"
}
variable "edition" {
  type    = string
  default = "ENTERPRISE"
}
variable "labels" { type = map(string) }
variable "private_network" {
  type        = string
  description = "Self-link de la VPC para IP privada de Cloud SQL (ej. Shared VPC del host project)"
  default     = null
}

variable "ipv4_enabled" {
  type        = bool
  description = "Habilitar IP pública (necesario para Cloud SQL Auth Proxy cuando pod routing a PSA no funciona)"
  default     = false
}

variable "psc_enabled" {
  type        = bool
  description = "Habilitar Private Service Connect (PSC) para conectividad desde pods GKE Autopilot con pod CIDR no-RFC-1918"
  default     = false
}

variable "psc_allowed_consumer_projects" {
  type        = list(string)
  description = "Números de proyecto GCP autorizados para crear PSC forwarding rules hacia esta instancia"
  default     = []
}

resource "google_sql_database_instance" "postgres" {
  name             = var.instance_name
  project          = var.project_id
  region           = var.region
  database_version = var.database_version

  settings {
    tier              = var.tier
    availability_type = var.availability
    edition           = var.edition

    backup_configuration {
      enabled                        = true
      start_time                     = "04:00" # 11 PM COT (UTC-5)
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7    # Domingo
      hour         = 6    # 1 AM COT (UTC-5) = 06:00 UTC
      update_track = "stable"
    }

    ip_configuration {
      ipv4_enabled    = var.ipv4_enabled
      private_network = var.private_network != null ? var.private_network : "projects/${var.project_id}/global/networks/default"

      dynamic "psc_config" {
        for_each = var.psc_enabled ? [1] : []
        content {
          psc_enabled               = true
          allowed_consumer_projects = var.psc_allowed_consumer_projects
        }
      }
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }

    user_labels = var.labels
  }

  deletion_protection = true
}

resource "google_sql_database" "db" {
  name     = var.database_name
  instance = google_sql_database_instance.postgres.name
  project  = var.project_id
}

resource "google_sql_user" "postgres" {
  name     = "postgres"
  instance = google_sql_database_instance.postgres.name
  project  = var.project_id
  password = "change-me-use-secret-manager"

  lifecycle {
    ignore_changes = [password]
  }
}

output "instance_connection_name" {
  value = google_sql_database_instance.postgres.connection_name
}

output "psc_service_attachment_link" {
  value       = var.psc_enabled ? google_sql_database_instance.postgres.psc_service_attachment_link : null
  description = "Service attachment URI para crear el PSC forwarding rule en el host VPC project"
}
