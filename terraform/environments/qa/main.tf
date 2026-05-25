# Ambiente QA - Business Financiero
# Ref CAF: Standard 04 - Resource Organization, Standard 05 - Naming Conventions
#
# Todos los parámetros se leen de /environments/qa.yaml.
# SA runtime QA (sufijo -sql-qa): creados en este mismo plan (ambiente nuevo).

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
    prefix = "terraform/environments/qa"
  }
}

locals {
  config  = yamldecode(file("${path.module}/../../../environments/qa.yaml"))
  shared  = yamldecode(file("${path.module}/../../../environments/shared.yaml"))

  project_id      = local.config.gcp.project_id
  project_num     = local.config.gcp.project_number
  region          = local.config.gcp.region
  environment     = local.config.naming.environment
  suite           = local.config.naming.product_suite
  dev_project_id  = local.shared.gcp.project_id

  labels = {
    business-unit = local.config.naming.business_unit
    product-suite = local.config.naming.product_suite
    environment   = local.config.naming.environment
    managed-by    = "terraform"
  }
}

provider "google" {
  project               = local.project_id
  region                = local.region
  billing_project       = local.project_id
  user_project_override = true
}

provider "google-beta" {
  project               = local.project_id
  region                = local.region
  billing_project       = local.project_id
  user_project_override = true
}

# Provider para el host VPC project — necesario para gestionar el peering PSA
provider "google" {
  alias                 = "host_vpc"
  project               = "prj-sie-com-vpc-host-qa"
  region                = local.region
  billing_project       = local.project_id
  user_project_override = true
}

data "google_client_config" "default" {}

# Kubernetes provider apunta al cluster GKE QA (ke-sie-fin-financiero-qa)
provider "kubernetes" {
  host                   = "https://${module.gke.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
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

# --- PSA custom routes — mantenidas para que la ruta 192.168.160.0/24 exista en el VPC ---
# La conectividad pod→Cloud SQL se resuelve via PSC (ver bloque cloud_sql_psc más abajo).
# PSA routes se mantienen por si algún componente usa la IP privada 192.168.160.20 directamente.
# Prerequisito IAM (manual, una sola vez):
#   gcloud projects add-iam-policy-binding prj-sie-com-vpc-host-qa \
#     --member="serviceAccount:sa-sie-fin-qa-cicd@prj-sie-sb-fin-common.iam.gserviceaccount.com" \
#     --role="roles/compute.networkAdmin"
resource "google_compute_network_peering_routes_config" "psa_routes" {
  provider             = google.host_vpc
  project              = "prj-sie-com-vpc-host-qa"
  peering              = "servicenetworking-googleapis-com"
  network              = "vpc-sie-shared-qa"
  import_custom_routes = true
  export_custom_routes = true
}

# --- Cloud SQL ---
# ipv4_enabled = false: QA usa IP privada via Shared VPC (org policy restrictPublicIp).
# psc_enabled = true: GKE Autopilot bloquea kube-system (GKE Warden), ip-masq-agent no puede
#   modificarse via kubectl. PSC resuelve el routing: hace SNAT propio → pods (100.82.x.x)
#   se conectan al forwarding rule IP (10.20.32.x, RFC-1918) → PSC hace NAT hacia Cloud SQL
#   → reply regresa por el forwarding rule que vive en nuestro VPC con rutas al pod CIDR.
module "cloud_sql" {
  source = "../../modules/cloud-sql"

  project_id                    = local.project_id
  region                        = local.region
  instance_name                 = local.config.database.instance_name
  database_name                 = local.config.database.database_name
  database_version              = local.config.database.version
  tier                          = local.config.database.tier
  availability                  = local.config.database.availability
  edition                       = local.config.database.edition
  private_network               = try(local.config.database.private_network, null)
  ipv4_enabled                  = false
  psc_enabled                   = true
  psc_allowed_consumer_projects = ["238886086835", "763982348967"]
  labels                        = local.labels
}

# --- PSC endpoint para Cloud SQL ---
# IP fija 10.20.39.250 dentro de la subnet GKE (10.20.32.0/21) en el host VPC project.
# Los services actualizan su connection string de Host=192.168.160.20 → Host=10.20.39.250.
resource "google_compute_address" "cloud_sql_psc" {
  provider     = google.host_vpc
  project      = "prj-sie-com-vpc-host-qa"
  name         = "ip-sie-fin-psc-cloudsql-qa"
  region       = local.region
  subnetwork   = "projects/prj-sie-com-vpc-host-qa/regions/${local.region}/subnetworks/snt-sie-bus-fin-use1-qa"
  address_type = "INTERNAL"
  address      = "10.20.39.250"
  purpose      = "GCE_ENDPOINT"
}

resource "google_compute_forwarding_rule" "cloud_sql_psc" {
  provider              = google.host_vpc
  project               = "prj-sie-com-vpc-host-qa"
  name                  = "psc-sie-fin-cloudsql-qa"
  region                = local.region
  network               = "projects/prj-sie-com-vpc-host-qa/global/networks/vpc-sie-shared-qa"
  subnetwork            = "projects/prj-sie-com-vpc-host-qa/regions/${local.region}/subnetworks/snt-sie-bus-fin-use1-qa"
  ip_address            = google_compute_address.cloud_sql_psc.self_link
  target                = module.cloud_sql.psc_service_attachment_link
  load_balancing_scheme = ""
  depends_on            = [module.cloud_sql]
}

output "cloud_sql_psc_ip" {
  value       = google_compute_address.cloud_sql_psc.address
  description = "IP del PSC endpoint de Cloud SQL QA — usar en connection strings en lugar de 192.168.160.20"
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
module "certificate_manager" {
  source = "../../modules/certificate-manager"

  project_id     = local.project_id
  dns_project_id = local.dev_project_id
  domain         = local.config.dns.domain
  dns_zone_name  = local.config.dns.zone_name
  cert_name      = local.config.certificate.name
  cert_map_name  = local.config.gateway.cert_map
  labels         = local.labels
}

# --- Pub/Sub: topics y suscripciones ---
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

resource "google_pubsub_topic" "treasury_events" {
  name    = "treasury-events"
  project = local.project_id
  labels  = local.labels
}

resource "google_pubsub_topic" "accounting_events" {
  name    = "accounting-events"
  project = local.project_id
  labels  = local.labels
}

resource "google_pubsub_subscription" "segments_self_events" {
  name    = "segments-segments-events"
  topic   = google_pubsub_topic.segments_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "segments_access_manager_events" {
  name    = "segments-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

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
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "access_manager_self_events" {
  name    = "accessmanager-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "base_config_access_manager_events" {
  name    = "base-config-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "base_config_segments_events" {
  name    = "base-config-segments-events"
  topic   = google_pubsub_topic.segments_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "accounting_access_manager_events" {
  name    = "accounting-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
  retain_acked_messages      = false
  expiration_policy { ttl = "" }
}

resource "google_pubsub_subscription" "third_party_access_manager_events" {
  name    = "third-party-access-manager-events"
  topic   = google_pubsub_topic.access_manager_events.name
  project = local.project_id
  labels  = local.labels

  ack_deadline_seconds       = 60
  message_retention_duration = "604800s"
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

# --- Segments Service ---
resource "google_service_account" "segments_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-segments-sql-qa"
  display_name = "Segments Cloud SQL - qa"
}

resource "google_project_iam_member" "segments_pubsub_subscriber" {
  project = local.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.segments_runtime.email}"
}

resource "google_project_iam_member" "segments_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.segments_runtime.email}"
}

resource "google_project_iam_member" "segments_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.segments_runtime.email}"
}

resource "google_project_iam_member" "segments_secret_accessor" {
  project = local.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.segments_runtime.email}"
}

resource "google_service_account_iam_member" "segments_runtime_wif" {
  service_account_id = google_service_account.segments_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_id}.svc.id.goog[segments/segments-api]"
}

resource "google_sql_user" "segments" {
  name     = "segments"
  instance = local.config.database.instance_name
  project  = local.project_id
  password = "change-me-use-secret-manager"

  lifecycle {
    ignore_changes = [password]
  }
}

# --- Access Manager Service ---
resource "google_service_account" "access_manager_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-accmgr-sql-qa"
  display_name = "Access Manager Cloud SQL - qa"
}

resource "google_project_iam_member" "access_manager_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.access_manager_runtime.email}"
}

resource "google_project_iam_member" "access_manager_pubsub_subscriber" {
  project = local.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.access_manager_runtime.email}"
}

resource "google_project_iam_member" "access_manager_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.access_manager_runtime.email}"
}

resource "google_project_iam_member" "access_manager_secret_accessor" {
  project = local.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.access_manager_runtime.email}"
}

resource "google_service_account_iam_member" "access_manager_runtime_wif" {
  service_account_id = google_service_account.access_manager_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_id}.svc.id.goog[access-manager/access-manager-api]"
}

resource "google_sql_user" "accmgr" {
  name     = "accmgr"
  instance = local.config.database.instance_name
  project  = local.project_id
  password = "change-me-use-secret-manager"

  lifecycle {
    ignore_changes = [password]
  }
}

# --- Base Config Service ---
resource "google_service_account" "base_config_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-baseconfig-sql-qa"
  display_name = "Base Config Cloud SQL - qa"
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

resource "google_project_iam_member" "base_config_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.base_config_runtime.email}"
}

resource "google_project_iam_member" "base_config_secret_accessor" {
  project = local.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.base_config_runtime.email}"
}

resource "google_service_account_iam_member" "base_config_runtime_wif" {
  service_account_id = google_service_account.base_config_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_id}.svc.id.goog[base-config/base-config-api]"
}

resource "google_sql_user" "base_config" {
  name     = "base_config"
  instance = local.config.database.instance_name
  project  = local.project_id
  password = "change-me-use-secret-manager"

  lifecycle {
    ignore_changes = [password]
  }
}

# --- Third Party Service ---
resource "google_service_account" "third_party_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-tprt-sql-qa"
  display_name = "Third Party Cloud SQL - qa"
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

resource "google_service_account_iam_member" "third_party_runtime_wif" {
  service_account_id = google_service_account.third_party_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.project_id}.svc.id.goog[third-party/third-party-api]"
}

resource "google_sql_user" "third_party" {
  name     = "third_party"
  instance = local.config.database.instance_name
  project  = local.project_id
  password = "change-me-use-secret-manager"

  lifecycle {
    ignore_changes = [password]
  }
}

# --- Accounting Service ---
resource "google_service_account" "accounting_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-acct-sql-qa"
  display_name = "Accounting Cloud SQL - qa"
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

# --- Liquid Tax Service ---
resource "google_service_account" "liquid_tax_runtime" {
  project      = local.project_id
  account_id   = "sa-sie-fin-liquid-tax-sql-qa"
  display_name = "Liquid Tax Cloud SQL - qa"
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

# --- DNS A record ---
# La zona siesacloud-dev vive en el Spoke DEV (dev_project_id), no en QA.
resource "google_dns_record_set" "domain_a_record" {
  count = try(local.config.gateway.external_ip, null) != null ? 1 : 0

  name         = "${local.config.dns.domain}."
  type         = "A"
  ttl          = 300
  managed_zone = local.config.dns.zone_name
  project      = local.dev_project_id
  rrdatas      = [try(local.config.gateway.external_ip, "")]

  depends_on = [module.gateway]
}

# ─── Cloud Build Worker Pool ────────────────────────────────────────────────
# Permite a los service CI/CD SAs ejecutar deploys al cluster QA vía Cloud Build.
# Sin VPC peering — usa el patrón MAN whitelist con endpoint público del cluster.
resource "google_cloudbuild_worker_pool" "main" {
  name     = "financiero-pool"
  location = local.region
  project  = local.project_id

  worker_config {
    disk_size_gb   = 100
    machine_type   = "e2-medium"
    no_external_ip = false
  }
}

# ─── IAM: Service CI/CD SAs — roles sobre QA para deploy ───────────────────
# Los SAs viven en Hub (prj-sie-sb-fin-common) — los mismos que usa DEV.
# Se les otorga roles en QA para poder enviar builds y usar el worker pool.
locals {
  service_cicd_sa_emails = {
    for name, svc in local.shared.services :
    name => "${svc.sa_name}@${local.shared.hub.project_id}.iam.gserviceaccount.com"
  }
}

resource "google_project_iam_member" "cicd_sa_cloudbuild_editor" {
  for_each = local.service_cicd_sa_emails

  project = local.project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "cicd_sa_workerpool_user" {
  for_each = local.service_cicd_sa_emails

  project = local.project_id
  role    = "roles/cloudbuild.workerPoolUser"
  member  = "serviceAccount:${each.value}"
}

# Necesario para que el SA del servicio pueda impersonar al SA de Cloud Build
# al ejecutar `gcloud builds submit --project=QA`
resource "google_project_iam_member" "cicd_sa_sa_user" {
  for_each = local.service_cicd_sa_emails

  project = local.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${each.value}"
}

# gcloud builds submit sube el fuente al bucket {project}_cloudbuild antes de
# disparar el build. El SA necesita roles/storage.admin para crear/escribir en
# ese bucket (no incluido en cloudbuild.builds.editor).
resource "google_project_iam_member" "cicd_sa_storage_admin" {
  for_each = local.service_cicd_sa_emails

  project = local.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${each.value}"
}

# Cloud Build SA del proyecto QA — actualiza MAN del cluster y hace kubectl deploy
resource "google_project_iam_member" "cloudbuild_sa_container_admin" {
  project = local.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${local.project_num}@cloudbuild.gserviceaccount.com"
}

# Worker pool privado corre en VMs con el Compute Engine default SA del proyecto QA.
# Cuando gcloud autentica dentro del container (metadata server), usa este SA.
resource "google_project_iam_member" "compute_sa_container_admin" {
  project = local.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${local.project_num}-compute@developer.gserviceaccount.com"
}

# Permite al SA de Compute Engine leer secrets de QA Secret Manager
# (para crear K8s secrets desde los valores almacenados al hacer kubectl deploy)
resource "google_project_iam_member" "compute_sa_secret_accessor" {
  project = local.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${local.project_num}-compute@developer.gserviceaccount.com"
}

# El worker pool descarga el fuente subido por el CI/CD SA desde el bucket
# {project}_cloudbuild hacia /workspace/. El Compute SA necesita storage.admin
# para leer ese objeto (storage.objects.get).
resource "google_project_iam_member" "compute_sa_storage_admin" {
  project = local.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${local.project_num}-compute@developer.gserviceaccount.com"
}

# El SA de deploy QA (sa-sie-fin-qa-cicd) usa gcloud builds submit con --project=QA
# desde el infra-pipeline. Necesita los mismos roles que los SAs de servicio para
# poder crear builds y usar el worker pool privado.
resource "google_project_iam_member" "qa_deploy_sa_storage_admin" {
  project = local.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${local.shared.qa_deploy.sa_name}@${local.shared.hub.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "qa_deploy_sa_cloudbuild_editor" {
  project = local.project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${local.shared.qa_deploy.sa_name}@${local.shared.hub.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "qa_deploy_sa_workerpool_user" {
  project = local.project_id
  role    = "roles/cloudbuild.workerPoolUser"
  member  = "serviceAccount:${local.shared.qa_deploy.sa_name}@${local.shared.hub.project_id}.iam.gserviceaccount.com"
}

# --- IAM: Roles complementarios por grupo (nivel proyecto) ---
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
  for_each = try(local.config.dev_access.enabled, false) ? toset(local.admins_extra_roles) : toset([])

  project = local.project_id
  role    = each.value
  member  = local.config.dev_access.admins_group
}

resource "google_project_iam_member" "devs_cloudsql_client" {
  count   = try(local.config.dev_access.enabled, false) ? 1 : 0

  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = local.config.dev_access.devs_group
}

# --- Monitoring ---
module "monitoring" {
  source = "../../modules/monitoring"

  project_id               = local.project_id
  alert_email              = local.config.monitoring.alert_email
  cloudsql_instance_id     = local.config.database.instance_name
  cloudsql_max_connections = 50
  labels                   = local.labels
}

# ─── Import blocks ───────────────────────────────────────────────────────────
# Idempotentes — si el recurso ya está en state, no hacen nada.

# Pub/Sub Topics (pre-existentes en QA)
import {
  to = google_pubsub_topic.access_manager_events
  id = "projects/prj-sie-fin-financiero-qas/topics/access-manager-events"
}
import {
  to = google_pubsub_topic.segments_events
  id = "projects/prj-sie-fin-financiero-qas/topics/segments-events"
}
import {
  to = google_pubsub_topic.base_config_events
  id = "projects/prj-sie-fin-financiero-qas/topics/base-config-events"
}
import {
  to = google_pubsub_topic.liquid_tax_events
  id = "projects/prj-sie-fin-financiero-qas/topics/liquid-tax-events"
}
import {
  to = google_pubsub_topic.third_party_events
  id = "projects/prj-sie-fin-financiero-qas/topics/third-party-events"
}
import {
  to = google_pubsub_topic.treasury_events
  id = "projects/prj-sie-fin-financiero-qas/topics/treasury-events"
}
import {
  to = google_pubsub_topic.accounting_events
  id = "projects/prj-sie-fin-financiero-qas/topics/accounting-events"
}

# Pub/Sub Subscriptions (pre-existentes en QA)
import {
  to = google_pubsub_subscription.segments_self_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/segments-segments-events"
}
import {
  to = google_pubsub_subscription.segments_access_manager_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/segments-access-manager-events"
}
import {
  to = google_pubsub_subscription.segments_stub_subscriptions["segments-base-config-events"]
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/segments-base-config-events"
}
import {
  to = google_pubsub_subscription.segments_stub_subscriptions["segments-liquid-tax-events"]
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/segments-liquid-tax-events"
}
import {
  to = google_pubsub_subscription.segments_stub_subscriptions["segments-third-party-events"]
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/segments-third-party-events"
}
import {
  to = google_pubsub_subscription.access_manager_self_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/accessmanager-access-manager-events"
}
import {
  to = google_pubsub_subscription.base_config_access_manager_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/base-config-access-manager-events"
}
import {
  to = google_pubsub_subscription.base_config_segments_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/base-config-segments-events"
}
import {
  to = google_pubsub_subscription.third_party_access_manager_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/third-party-access-manager-events"
}
import {
  to = google_pubsub_subscription.third_party_segments_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/third-party-segments-events"
}
import {
  to = google_pubsub_subscription.third_party_base_config_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/third-party-base-config-events"
}
import {
  to = google_pubsub_subscription.third_party_liquid_tax_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/third-party-liquid-tax-events"
}
import {
  to = google_pubsub_subscription.third_party_treasury_events
  id = "projects/prj-sie-fin-financiero-qas/subscriptions/third-party-treasury-events"
}

# SQL Users (pre-existentes — creados por gcloud antes del primer deploy de servicio)
import {
  to = google_sql_user.accmgr
  id = "prj-sie-fin-financiero-qas/pgsql-fin-financiero-qa/accmgr"
}
import {
  to = google_sql_user.segments
  id = "prj-sie-fin-financiero-qas/pgsql-fin-financiero-qa/segments"
}

# Runtime SAs (pre-existentes en QA)
import {
  to = google_service_account.base_config_runtime
  id = "projects/prj-sie-fin-financiero-qas/serviceAccounts/sa-sie-fin-baseconfig-sql-qa@prj-sie-fin-financiero-qas.iam.gserviceaccount.com"
}
import {
  to = google_service_account.third_party_runtime
  id = "projects/prj-sie-fin-financiero-qas/serviceAccounts/sa-sie-fin-tprt-sql-qa@prj-sie-fin-financiero-qas.iam.gserviceaccount.com"
}
import {
  to = google_service_account.accounting_runtime
  id = "projects/prj-sie-fin-financiero-qas/serviceAccounts/sa-sie-fin-acct-sql-qa@prj-sie-fin-financiero-qas.iam.gserviceaccount.com"
}
import {
  to = google_service_account.liquid_tax_runtime
  id = "projects/prj-sie-fin-financiero-qas/serviceAccounts/sa-sie-fin-liquid-tax-sql-qa@prj-sie-fin-financiero-qas.iam.gserviceaccount.com"
}

# Certificate Manager (pre-existentes en QA + CNAME en zona DNS de DEV)
import {
  to = module.certificate_manager.google_certificate_manager_dns_authorization.this
  id = "projects/prj-sie-fin-financiero-qas/locations/global/dnsAuthorizations/finance-cert-qa-dns-auth"
}
import {
  to = module.certificate_manager.google_certificate_manager_certificate.this
  id = "projects/prj-sie-fin-financiero-qas/locations/global/certificates/finance-cert-qa"
}
import {
  to = module.certificate_manager.google_certificate_manager_certificate_map.this
  id = "projects/prj-sie-fin-financiero-qas/locations/global/certificateMaps/finance-qa-siesacloud-dev-map"
}
import {
  to = module.certificate_manager.google_dns_record_set.cert_validation_cname
  id = "prj-sie-fin-financiero-dev/siesacloud-dev/_acme-challenge.finance-qa.siesacloud.dev./CNAME"
}
