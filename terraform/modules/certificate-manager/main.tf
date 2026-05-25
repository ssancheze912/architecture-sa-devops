# Módulo: Certificate Manager
# Ref CAF: Standard 15 - Security (HTTPS everywhere)
#
# REGLA: Todos los recursos GCP deben gestionarse via Terraform.
#        Este módulo NO debe usarse con recursos creados manualmente — importarlos primero.
#
# Crea:
#   1. DNS Authorization    — prueba de propiedad del dominio
#   2. CNAME record         — validación DNS (registro CNAME en la zona Cloud DNS)
#   3. Certificate          — certificado TLS gestionado por Google
#   4. Certificate Map      — referenciado por el Gateway via anotación networking.gke.io/certmap
#   5. Certificate Map Entry — asocia el certificado al dominio en el mapa
#
# El A record (dominio → IP del Gateway) NO es responsabilidad de este módulo.
# Se gestiona en el ambiente correspondiente (environments/*/main.tf) via
# google_dns_record_set una vez que el Gateway tiene IP asignada.
#
# Uso:
#   module "certificate_manager" {
#     source        = "../../modules/certificate-manager"
#     project_id    = "mi-proyecto"
#     domain        = "finance.siesacloud.dev"
#     dns_zone_name = "siesacloud-dev"
#     cert_name     = "finance-siesacloud-dev-cert"
#     cert_map_name = "finance-siesacloud-dev-map"
#     labels        = { environment = "dev" }
#   }

variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "domain" {
  type        = string
  description = "Dominio a certificar (ej: finance-sandbox.siesacloud.dev)"
}

variable "dns_zone_name" {
  type        = string
  description = "Nombre de la zona Cloud DNS donde se creará el CNAME de validación"
}

variable "cert_name" {
  type        = string
  description = "Nombre del recurso Certificate (ej: finance-sandbox-siesacloud-dev-cert)"
}

variable "cert_map_name" {
  type        = string
  description = "Nombre del Certificate Map (referenciado por la anotación networking.gke.io/certmap del Gateway)"
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Labels a aplicar a los recursos"
}

variable "dns_project_id" {
  type        = string
  description = "GCP project donde vive la zona DNS compartida (default: project_id)"
  default     = null
}

# --- 1. DNS Authorization ---
# Genera el CNAME record que Google usa para verificar que controlamos el dominio.
resource "google_certificate_manager_dns_authorization" "this" {
  name    = "${var.cert_name}-dns-auth"
  domain  = var.domain
  project = var.project_id
  labels  = var.labels
}

# --- 2. CNAME record de validación DNS ---
# Debe agregarse a la zona DNS para que Certificate Manager pruebe la propiedad del dominio.
resource "google_dns_record_set" "cert_validation_cname" {
  name         = google_certificate_manager_dns_authorization.this.dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.this.dns_resource_record[0].type
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = coalesce(var.dns_project_id, var.project_id)
  rrdatas      = [google_certificate_manager_dns_authorization.this.dns_resource_record[0].data]
}

# --- 3. Certificado TLS gestionado por Google ---
# Google provisionará y renovará el certificado automáticamente.
resource "google_certificate_manager_certificate" "this" {
  name    = var.cert_name
  project = var.project_id
  labels  = var.labels

  managed {
    domains            = [var.domain]
    dns_authorizations = [google_certificate_manager_dns_authorization.this.id]
  }
}

# --- 4. Certificate Map ---
# El Gateway referencia este mapa via la anotación networking.gke.io/certmap.
resource "google_certificate_manager_certificate_map" "this" {
  name    = var.cert_map_name
  project = var.project_id
  labels  = var.labels
}

# --- 5. Certificate Map Entry ---
# Asocia el certificado al dominio dentro del mapa.
resource "google_certificate_manager_certificate_map_entry" "this" {
  name         = "${var.cert_map_name}-entry"
  map          = google_certificate_manager_certificate_map.this.name
  project      = var.project_id
  labels       = var.labels
  certificates = [google_certificate_manager_certificate.this.id]
  hostname     = var.domain
}

output "certificate_map_name" {
  value       = google_certificate_manager_certificate_map.this.name
  description = "Nombre del Certificate Map para referenciar en la anotación del Gateway"
}

output "dns_authorization_name" {
  value       = google_certificate_manager_dns_authorization.this.name
  description = "Nombre del DNS Authorization (útil para imports y troubleshooting)"
}
