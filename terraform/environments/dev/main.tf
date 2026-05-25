# Ambiente Dev-Dev - Business Financiero
# Ref CAF: Standard 04 - Resource Organization, Standard 05 - Naming Conventions
#
# Ambiente paralelo al dev actual para validar el pipeline CI/CD end-to-end.
# Una vez validado, reemplazará al ambiente dev original.
#
# Recursos que NO se gestionan aquí (ya existen o son compartidos):
#   - DNS zone: ya existe, compartida con dev
#   - Artifact Registry: repos compartidos con dev
#   - IAM/SA: el SA dev se crea via bootstrap manual (no gestionado por TF)
#   - WIF pool: existente, compartido con dev
#
# Todos los parámetros se leen de /environments/dev.yaml.

terraform {
  required_version = ">= 1.14"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }

  backend "gcs" {
    bucket = "bkt-sie-fin-iac-state-prj-sie-fin-financiero-dev"
    prefix = "terraform/environments/dev"
  }
}

locals {
  config = yamldecode(file("${path.module}/../../../environments/dev.yaml"))

  project_id  = local.config.gcp.project_id
  project_num = local.config.gcp.project_number
  region      = local.config.gcp.region
  environment = local.config.naming.environment
  suite       = local.config.naming.product_suite

  labels = {
    business-unit = local.config.naming.business_unit
    product-suite = local.config.naming.product_suite
    environment   = local.config.naming.environment
    managed-by    = "terraform"
  }
}

provider "google" {
  project = local.project_id
  region  = local.region
}

provider "google-beta" {
  project = local.project_id
  region  = local.region
}

# Credenciales del cliente GCP (token de corta duración para el kubernetes provider)
data "google_client_config" "default" {}

# Kubernetes provider usa las credenciales del cluster GKE dev
# El cluster se crea en el primer pass (terraform apply -target=module.gke),
# y los recursos kubernetes (namespaces/gateway) se aplican en el segundo pass.
provider "kubernetes" {
  host                   = "https://${module.gke.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
}

# --- SA dev como data source (creado via bootstrap, no por TF) ---
data "google_service_account" "sandbox_deploy" {
  account_id = local.config.deploy.sa_name
  project    = local.project_id
}

# --- GKE Autopilot ---
module "gke" {
  source = "../../modules/gke-autopilot"

  project_id                    = local.project_id
  region                        = local.region
  cluster_name                  = local.config.gke.cluster_name
  network                       = local.config.gke.network
  subnetwork                    = local.config.gke.subnetwork
  release_channel               = local.config.gke.release_channel
  master_cidr                   = local.config.gke.master_cidr
  cluster_secondary_range_name  = try(local.config.gke.cluster_secondary_range_name, null)
  services_secondary_range_name = try(local.config.gke.services_secondary_range_name, null)
  labels                        = local.labels
}

# Import: GKE Autopilot cluster — existe en GCP, no estaba en state.
# Idempotente: si ya está en state, Terraform ignora silenciosamente el import block.
import {
  to = module.gke.google_container_cluster.autopilot
  id = "projects/${local.project_id}/locations/${local.region}/clusters/${local.config.gke.cluster_name}"
}

# --- Cloud SQL ---
# ipv4_enabled = true: necesario para Cloud SQL Auth Proxy.
# Los pods GKE Autopilot no pueden alcanzar la IP privada de Cloud SQL via PSA
# (ip-masq-agent nonMasqueradeCIDRs + PSA no propaga routes de pod alias IPs).
# El Auth Proxy conecta via IP pública. La org policy sql.restrictPublicIp fue
# exemptada a nivel de proyecto para prj-sie-fin-financiero-dev.
module "cloud_sql" {
  source = "../../modules/cloud-sql"

  project_id       = local.project_id
  region           = local.region
  instance_name    = local.config.database.instance_name
  database_name    = local.config.database.database_name
  database_version = local.config.database.version
  tier             = local.config.database.tier
  availability     = local.config.database.availability
  edition          = local.config.database.edition
  private_network  = try(local.config.database.private_network, null)
  ipv4_enabled     = true
  labels           = local.labels
}

# Import: Cloud SQL instance — existe en GCP, no estaba en state.
import {
  to = module.cloud_sql.google_sql_database_instance.postgres
  id = "projects/${local.project_id}/instances/${local.config.database.instance_name}"
}

# Import: postgres user — se crea automáticamente por Cloud SQL, no estaba en state.
# Formato PostgreSQL: {project}/{instance}/{name}
import {
  to = module.cloud_sql.google_sql_user.postgres
  id = "${local.project_id}/${local.config.database.instance_name}/postgres"
}

# finance-dev ya existe en Cloud SQL (creado en el paso de migración).
# Lo importamos al módulo y sacamos el recurso standalone del state sin destruirlo.
import {
  to = module.cloud_sql.google_sql_database.db
  id = "projects/${local.project_id}/instances/${local.config.database.instance_name}/databases/finance-dev"
}

removed {
  from = google_sql_database.finance_dev
  lifecycle {
    destroy = false
  }
}

# --- Namespaces K8s ---
module "namespaces" {
  source     = "../../modules/namespaces"
  depends_on = [module.gke]

  namespaces = local.config.namespaces
  labels = {
    "app.kubernetes.io/part-of" = "${local.config.naming.business_unit}-platform"
  }
}

# --- Gateway API ---
module "gateway" {
  source     = "../../modules/gateway"
  depends_on = [module.namespaces]

  gateway_name  = local.config.gateway.name
  namespace     = local.config.gateway.namespace
  cert_map      = local.config.gateway.cert_map
  gateway_class = local.config.gateway.class
}

# --- Certificate Manager ---
# Gestiona el certificado TLS para finance-dev.siesacloud.dev.
# REGLA: Todo recurso GCP debe gestionarse via Terraform (no crear manualmente).
# El cert map es referenciado por el Gateway via la anotación networking.gke.io/certmap.
# El certificado se valida via DNS (CNAME record creado aquí automáticamente).
module "certificate_manager" {
  source = "../../modules/certificate-manager"

  project_id    = local.project_id
  domain        = local.config.dns.domain
  dns_zone_name = local.config.dns.zone_name
  cert_name     = local.config.certificate.name
  cert_map_name = local.config.gateway.cert_map
  labels        = local.labels
}

# --- Pub/Sub: topics y suscripciones (Dapr disableEntityManagement=true) ---
# Convención: un topic por servicio, formato {servicio}-events.
# Nombres de suscripciones: {dapr-app-id}-{topic} (convención Dapr GCP Pub/Sub).

resource "google_pubsub_topic" "access_manager_events" {
  name    = "access-manager-events"
  project = local.project_id
  labels  = local.labels
}

resource "google_pubsub_topic" "segments_events" {
  name    = "segments-events"
  project = local.project_id
  labels  = local.labels
}

# Topics de servicios futuros (stubs TD-COMP-004): LiquidTax, ThirdParty, Treasury.
# Deben existir antes de que los servicios productores se desplieguen.
resource "google_pubsub_topic" "base_config_events" {
  name    = "base-config-events"
  project = local.project_id
  labels  = local.labels
}

resource "google_pubsub_topic" "liquid_tax_events" {
  name    = "liquid-tax-events"
  project = local.project_id
  labels  = local.labels
}

resource "google_pubsub_topic" "third_party_events" {
  name    = "third-party-events"
  project = local.project_id
  labels  = local.labels
}

# stub: topic para el futuro servicio Treasury (payment conditions).
# Third Party se suscribe a este topic para sincronizar PaymentConditionPrj.
resource "google_pubsub_topic" "treasury_events" {
  name    = "treasury-events"
  project = local.project_id
  labels  = local.labels
}


# Segments se suscribe a su propio topic para consumir eventos internos (fiscal period/year).
# Convención: un topic por servicio — los eventos internos también van por segments-events.
resource "google_pubsub_subscription" "segments_self_events" {
  name    = "segments-segments-events"
  topic   = google_pubsub_topic.segments_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 días
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

# Segments se suscribe al topic de Access Manager para sincronizar proyecciones de usuarios.
resource "google_pubsub_subscription" "segments_access_manager_events" {
  name    = "segments-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 días
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

# Suscripciones de Segments a topics de servicios futuros (stubs TD-COMP-004).
locals {
  segments_stub_subscriptions = {
    "segments-base-config-events" = google_pubsub_topic.base_config_events.name
    "segments-liquid-tax-events"  = google_pubsub_topic.liquid_tax_events.name
    "segments-third-party-events" = google_pubsub_topic.third_party_events.name
  }
}

resource "google_pubsub_subscription" "segments_stub_subscriptions" {
  for_each = local.segments_stub_subscriptions

  name    = each.key
  topic   = each.value
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 días
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

# IAM: SA de runtime de Segments puede consumir suscripciones Pub/Sub.
# sa-sie-fin-segments-sql-dev es el SA vinculado al K8s SA segments-api via Workload Identity.
resource "google_project_iam_member" "segments_pubsub_subscriber" {
  project = local.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:sa-sie-fin-segments-sql-dev@${local.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "segments_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:sa-sie-fin-segments-sql-dev@${local.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "access_manager_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:sa-sie-fin-accmgr-sql-dev@${local.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "access_manager_pubsub_subscriber" {
  project = local.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:sa-sie-fin-accmgr-sql-dev@${local.project_id}.iam.gserviceaccount.com"
}

# Access Manager se suscribe a su propio topic para invalidar caché de permisos en Redis
# entre réplicas (UserPermissionsChanged, RolePermissionsChanged).
# Convención Dapr GCP Pub/Sub: {app-id}-{topic} = accessmanager-access-manager-events.
resource "google_pubsub_subscription" "access_manager_self_events" {
  name    = "accessmanager-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 días
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

import {
  to = google_pubsub_subscription.access_manager_self_events
  id = "projects/${local.project_id}/subscriptions/accessmanager-access-manager-events"
}

# Base Config se suscribe a topics de Access Manager y Segments para sincronizar proyecciones.
resource "google_pubsub_subscription" "base_config_access_manager_events" {
  name    = "base-config-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 días
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "base_config_segments_events" {
  name    = "base-config-segments-events"
  topic   = google_pubsub_topic.segments_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 días
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

# SA de runtime de Base Config — vinculado al K8s SA base-config-api via Workload Identity.
# Equivalente a sa-sie-fin-segments-sql-dev / sa-sie-fin-accmgr-sql-dev de otros servicios.
resource "google_service_account" "base_config_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-baseconfig-sql-dev"
  display_name = "Base Config Cloud SQL - dev"
}

resource "google_project_iam_member" "base_config_pubsub_subscriber" {
  project = local.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.base_config_runtime.email}"
}

resource "google_project_iam_member" "base_config_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.base_config_runtime.email}"
}

# IAM: SA de runtime de Base Config — acceso a Cloud SQL (necesario para Auth Proxy sidecar).
resource "google_project_iam_member" "base_config_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.base_config_runtime.email}"
}

# IAM: SA de runtime de Base Config — acceso a Secret Manager (Dapr secretstore).
resource "google_project_iam_member" "base_config_secret_accessor" {
  project = local.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.base_config_runtime.email}"
}

# WIF: K8s SA base-config-api (namespace base-config) puede impersonar el GCP SA de runtime.
# Prerequisito: el K8s SA debe tener la anotación iam.gke.io/gcp-service-account en su deployment.
resource "google_service_account_iam_member" "base_config_runtime_wif" {
  service_account_id = google_service_account.base_config_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_id}.svc.id.goog[base-config/base-config-api]"
}

# Cloud SQL — usuario dedicado para base-config.
# BD única: finance-dev | Schema: base_config | Usuario: base_config
# Contraseña gestionada via Secret Manager (secret: baseconfig-dev-db-connection).
# Ver docs/bootstrap-guide.md § SVC.5 para crear el secret.
resource "google_sql_user" "base_config" {
  name     = "base_config"
  instance = local.config.database.instance_name
  project  = local.project_id
  password = "change-me-use-secret-manager"

  lifecycle {
    ignore_changes = [password]
  }
}

# ─── Third Party Service ─────────────────────────────────────────────────────
# SA de runtime — vinculado al K8s SA third-party-api (namespace third-party) via Workload Identity.
resource "google_service_account" "third_party_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-tprt-sql-dev"
  display_name = "Third Party Cloud SQL - dev"
}

resource "google_project_iam_member" "third_party_pubsub_subscriber" {
  project = local.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.third_party_runtime.email}"
}

resource "google_project_iam_member" "third_party_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.third_party_runtime.email}"
}

resource "google_project_iam_member" "third_party_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.third_party_runtime.email}"
}

resource "google_project_iam_member" "third_party_secret_accessor" {
  project = local.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.third_party_runtime.email}"
}

# WIF: K8s SA third-party-api (namespace third-party) puede impersonar el GCP SA de runtime.
resource "google_service_account_iam_member" "third_party_runtime_wif" {
  service_account_id = google_service_account.third_party_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_id}.svc.id.goog[third-party/third-party-api]"
}

# Cloud SQL — usuario dedicado para third-party.
# BD única: finance-dev | Schema: tprt | Usuario: third_party
# Contraseña gestionada via Secret Manager (secret: tprt-dev-db-connection).
resource "google_sql_user" "third_party" {
  name     = "third_party"
  instance = local.config.database.instance_name
  project  = local.project_id
  password = "change-me-use-secret-manager"

  lifecycle {
    ignore_changes = [password]
  }
}

# Suscripciones Pub/Sub — Third Party consume de 5 topics.
# Convención Dapr GCP Pub/Sub: {dapr-app-id}-{topic}.
resource "google_pubsub_subscription" "third_party_access_manager_events" {
  name    = "third-party-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 días
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "third_party_segments_events" {
  name    = "third-party-segments-events"
  topic   = google_pubsub_topic.segments_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "third_party_base_config_events" {
  name    = "third-party-base-config-events"
  topic   = google_pubsub_topic.base_config_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "third_party_liquid_tax_events" {
  name    = "third-party-liquid-tax-events"
  topic   = google_pubsub_topic.liquid_tax_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "liquid_tax_segments_events" {
  name    = "liquid-tax-segments-events"
  topic   = google_pubsub_topic.segments_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "liquid_tax_base_config_events" {
  name    = "liquid-tax-base-config-events"
  topic   = google_pubsub_topic.base_config_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "liquid_tax_access_manager_events" {
  name    = "liquid-tax-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "third_party_treasury_events" {
  name    = "third-party-treasury-events"
  topic   = google_pubsub_topic.treasury_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

# --- A record DNS (dominio → IP del Gateway) ---
# Se crea una vez que el Gateway tiene IP asignada.
# Para activar: agregar `gateway.external_ip: "<IP>"` en environments/dev.yaml
# y hacer push. La IP se obtiene con:
#   kubectl get gateway financiero-dev-gateway -n gateway-infra -o jsonpath='{.status.addresses[0].value}'
#
# NOTA: En la primera ejecución, el Gateway puede no tener IP aún (tarda ~2-5 min).
#       Cuando external_ip esté configurado, este recurso se crea automáticamente en el
#       siguiente terraform apply (sin necesidad de pasos manuales adicionales).
resource "google_dns_record_set" "domain_a_record" {
  count = try(local.config.gateway.external_ip, null) != null ? 1 : 0

  name         = "${local.config.dns.domain}."
  type         = "A"
  ttl          = 300
  managed_zone = local.config.dns.zone_name
  project      = local.project_id
  rrdatas      = [try(local.config.gateway.external_ip, "")]

  depends_on = [module.gateway]
}

# ─── Import blocks: recursos existentes en GCP/K8s no presentes en state ──────
# El state estaba vacío al inicio — todos los recursos deben importarse.
# En TF 1.7+, import blocks son idempotentes: si el recurso ya está en state,
# el bloque se ignora silenciosamente en runs posteriores.

# Pub/Sub Topics
import {
  to = google_pubsub_topic.access_manager_events
  id = "projects/${local.project_id}/topics/access-manager-events"
}
import {
  to = google_pubsub_topic.segments_events
  id = "projects/${local.project_id}/topics/segments-events"
}
import {
  to = google_pubsub_topic.base_config_events
  id = "projects/${local.project_id}/topics/base-config-events"
}
import {
  to = google_pubsub_topic.liquid_tax_events
  id = "projects/${local.project_id}/topics/liquid-tax-events"
}
import {
  to = google_pubsub_topic.third_party_events
  id = "projects/${local.project_id}/topics/third-party-events"
}

# Service Account — Base Config runtime (creado manualmente o por pipeline anterior)
import {
  to = google_service_account.base_config_runtime
  id = "projects/${local.project_id}/serviceAccounts/sa-sie-fin-baseconfig-sql-dev@${local.project_id}.iam.gserviceaccount.com"
}

# Certificate Manager (todos los recursos del módulo ya existen en GCP)
import {
  to = module.certificate_manager.google_certificate_manager_dns_authorization.this
  id = "projects/${local.project_id}/locations/global/dnsAuthorizations/${local.config.certificate.name}-dns-auth"
}
import {
  to = module.certificate_manager.google_certificate_manager_certificate_map.this
  id = "projects/${local.project_id}/locations/global/certificateMaps/${local.config.gateway.cert_map}"
}
import {
  to = module.certificate_manager.google_certificate_manager_certificate.this
  id = "projects/${local.project_id}/locations/global/certificates/${local.config.certificate.name}"
}
import {
  to = module.certificate_manager.google_certificate_manager_certificate_map_entry.this
  id = "projects/${local.project_id}/locations/global/certificateMaps/${local.config.gateway.cert_map}/certificateMapEntries/${local.config.gateway.cert_map}-entry"
}

# K8s Namespaces (los que ya existen — third-party es nuevo)
import {
  to = module.namespaces.kubernetes_namespace.ns["gateway-infra"]
  id = "gateway-infra"
}
import {
  to = module.namespaces.kubernetes_namespace.ns["app-shell"]
  id = "app-shell"
}
import {
  to = module.namespaces.kubernetes_namespace.ns["access-manager"]
  id = "access-manager"
}
import {
  to = module.namespaces.kubernetes_namespace.ns["segments"]
  id = "segments"
}
import {
  to = module.namespaces.kubernetes_namespace.ns["base-config"]
  id = "base-config"
}
import {
  to = module.namespaces.kubernetes_namespace.ns["observability"]
  id = "observability"
}

# K8s Gateway resources (ya existen en el cluster)
import {
  to = module.gateway.kubernetes_manifest.gateway
  id = "apiVersion=gateway.networking.k8s.io/v1,kind=Gateway,namespace=${local.config.gateway.namespace},name=${local.config.gateway.name}"
}
import {
  to = module.gateway.kubernetes_manifest.http_redirect
  id = "apiVersion=gateway.networking.k8s.io/v1,kind=HTTPRoute,namespace=${local.config.gateway.namespace},name=http-to-https-redirect"
}

# Pub/Sub Subscriptions (ya existen en GCP)
import {
  to = google_pubsub_subscription.segments_self_events
  id = "projects/${local.project_id}/subscriptions/segments-segments-events"
}
import {
  to = google_pubsub_subscription.segments_access_manager_events
  id = "projects/${local.project_id}/subscriptions/segments-access-manager-events"
}
import {
  to = google_pubsub_subscription.segments_stub_subscriptions["segments-base-config-events"]
  id = "projects/${local.project_id}/subscriptions/segments-base-config-events"
}
import {
  to = google_pubsub_subscription.segments_stub_subscriptions["segments-liquid-tax-events"]
  id = "projects/${local.project_id}/subscriptions/segments-liquid-tax-events"
}
import {
  to = google_pubsub_subscription.segments_stub_subscriptions["segments-third-party-events"]
  id = "projects/${local.project_id}/subscriptions/segments-third-party-events"
}
import {
  to = google_pubsub_subscription.base_config_access_manager_events
  id = "projects/${local.project_id}/subscriptions/base-config-access-manager-events"
}
import {
  to = google_pubsub_subscription.base_config_segments_events
  id = "projects/${local.project_id}/subscriptions/base-config-segments-events"
}

# DNS A record (creado manualmente antes de que TF lo gestionara)
import {
  to = google_dns_record_set.domain_a_record[0]
  id = "${local.project_id}/${local.config.dns.zone_name}/${local.config.dns.domain}./A"
}

# SQL users — base_config y third_party (existían en Cloud SQL, no estaban en state)
# Sin import block, Terraform los crea de nuevo y sobreescribe la contraseña con el placeholder.
import {
  to = google_sql_user.base_config
  id = "${local.project_id}/${local.config.database.instance_name}/base_config"
}
import {
  to = google_sql_user.third_party
  id = "${local.project_id}/${local.config.database.instance_name}/third_party"
}

# ─── Accounting Service ───────────────────────────────────────────────────────
resource "google_service_account" "accounting_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-acct-sql-dev"
  display_name = "Accounting Cloud SQL - dev"
}

resource "google_project_iam_member" "accounting_pubsub_subscriber" {
  project = local.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.accounting_runtime.email}"
}

resource "google_project_iam_member" "accounting_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.accounting_runtime.email}"
}

resource "google_project_iam_member" "accounting_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.accounting_runtime.email}"
}

resource "google_project_iam_member" "accounting_secret_accessor" {
  project = local.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.accounting_runtime.email}"
}

resource "google_service_account_iam_member" "accounting_runtime_wif" {
  service_account_id = google_service_account.accounting_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_id}.svc.id.goog[accounting/accounting-api]"
}

resource "google_sql_user" "accounting" {
  name     = "accounting"
  instance = local.config.database.instance_name
  project  = local.project_id
  password = "change-me-use-secret-manager"

  lifecycle {
    ignore_changes = [password]
  }
}

resource "google_pubsub_topic" "accounting_events" {
  name    = "accounting-events"
  project = local.project_id
  labels  = local.labels
}

resource "google_pubsub_subscription" "accounting_access_manager_events" {
  name    = "accounting-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s" # 7 días
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

# ─── Liquid Tax Service ───────────────────────────────────────────────────────
resource "google_service_account" "liquid_tax_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-liquid-tax-sql-dev"
  display_name = "Liquid Tax Cloud SQL - dev"
}

resource "google_project_iam_member" "liquid_tax_pubsub_subscriber" {
  project = local.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.liquid_tax_runtime.email}"
}

resource "google_project_iam_member" "liquid_tax_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.liquid_tax_runtime.email}"
}

resource "google_project_iam_member" "liquid_tax_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.liquid_tax_runtime.email}"
}

resource "google_project_iam_member" "liquid_tax_secret_accessor" {
  project = local.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.liquid_tax_runtime.email}"
}

resource "google_service_account_iam_member" "liquid_tax_runtime_wif" {
  service_account_id = google_service_account.liquid_tax_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_id}.svc.id.goog[liquid-tax/liquid-tax-api]"
}

resource "google_sql_user" "liquid_tax" {
  name     = "liquid_tax"
  instance = local.config.database.instance_name
  project  = local.project_id
  password = "change-me-use-secret-manager"

  lifecycle {
    ignore_changes = [password]
  }
}

# ─── IAM: Roles complementarios por grupo (nivel proyecto) ───────────────────
# Los grupos tienen roles base heredados de la carpeta (editor, secretmanager.admin, etc.).
# Aquí se agregan los roles que NO existen en la carpeta.
#
# admins (g-gcp-fld-sie-bus-financiero-dev-admins):
#   + roles/cloudsql.client          → Cloud SQL Auth Proxy (dev-connect.sh)
#   + roles/container.admin          → actualizar Master Authorized Networks (kubectl)
#   + roles/cloudfunctions.admin     → Cloud Functions
#   + roles/cloudfunctions.developer → Cloud Functions (desarrollo)
#   + roles/run.admin                → Cloud Run
#   + roles/iap.tunnelResourceAccessor → IAP-secured Tunnel
#   + roles/iam.serviceAccountUser   → impersonar SAs
#
# devs (g-gcp-fld-sie-bus-financiero-dev-devs):
#   + roles/cloudsql.client          → Cloud SQL Auth Proxy (dev-connect.sh)
#
# Membresía de grupos se gestiona en Google Workspace (fuera de Terraform).

locals {
  admins_extra_roles = [
    "roles/cloudsql.client",
    "roles/container.admin",
    "roles/cloudfunctions.admin",
    "roles/cloudfunctions.developer",
    "roles/run.admin",
    "roles/iap.tunnelResourceAccessor",
    "roles/iam.serviceAccountUser",
  ]
}

resource "google_project_iam_member" "admins_roles" {
  for_each = toset(local.admins_extra_roles)

  project = local.project_id
  role    = each.value
  member  = local.config.dev_access.admins_group
}

resource "google_project_iam_member" "devs_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = local.config.dev_access.devs_group
}

# ─── Monitoring — Alertas de base de datos ────────────────────────────────────
# Canal: email configurado en environments/dev.yaml (monitoring.alert_email)
# Alertas activas: backup diario sin completar, disco > 80%
module "monitoring" {
  source = "../../modules/monitoring"

  project_id               = local.project_id
  alert_email              = local.config.monitoring.alert_email
  cloudsql_instance_id     = local.config.database.instance_name
  cloudsql_max_connections = 50 # db-g1-small ≈ 50 conexiones
  labels                   = local.labels
}
