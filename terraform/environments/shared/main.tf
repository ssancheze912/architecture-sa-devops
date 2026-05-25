# Recursos Compartidos — Business Financiero
# Ref CAF: Standard 04 - Resource Organization, Standard 06 - IAM and Security
#
# Gestiona TODOS los recursos GCP compartidos entre ambientes dev/sandbox/prod:
#   - Zona DNS siesacloud-dev (Spoke DEV)
#   - WIF pool "github-actions" + SAs CI/CD → viven en Hub (prj-sie-sb-fin-common)
#   - Hub AR IAM: deploy SA (admin) + CI/CD SAs (writer) en art-fin-shared
#   - Service Accounts CI/CD por servicio + WIF bindings + IAM roles sobre Spoke DEV
#   - Service Account del ambiente QA + WIF binding + roles cross-project
#   - Cloud Build Worker Pool (peered a Shared VPC, vive en Spoke DEV)
#
# MIGRACIÓN Hub-First (2026-05-18):
#   WIF pool + todos los SAs CI/CD migrados de prj-sie-fin-financiero-dev
#   a prj-sie-sb-fin-common (Hub). Los SAs DEV originales quedan huérfanos
#   en GCP y pueden eliminarse manualmente.
#
# Estado TF independiente: terraform/environments/shared
# Nunca se destruye junto con ningún ambiente específico.

terraform {
  required_version = ">= 1.14"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  backend "gcs" {
    bucket = "bkt-sie-fin-iac-state-prj-sie-fin-financiero-dev"
    prefix = "terraform/environments/shared"
  }
}

locals {
  config = yamldecode(file("${path.module}/../../../environments/shared.yaml"))

  # Spoke DEV: Cloud Build, DNS, Worker Pool
  project_id  = local.config.gcp.project_id
  project_num = local.config.gcp.project_number
  region      = local.config.gcp.region

  # Hub: WIF pool + todos los SAs CI/CD
  hub_project_id  = local.config.hub.project_id
  hub_project_num = local.config.hub.project_number

  labels = {
    business-unit = local.config.naming.business_unit
    product-suite = local.config.naming.product_suite
    managed-by    = "terraform"
  }
}

provider "google" {
  project               = local.project_id
  region                = local.region
  billing_project       = local.project_id
  user_project_override = true
}

# ─── DNS Zone (compartida entre todos los ambientes, vive en Spoke DEV) ─────
module "dns" {
  source = "../../modules/dns"

  project_id = local.project_id
  zone_name  = local.config.dns.zone_name
  dns_name   = local.config.dns.dns_name
}

# ─── IAM: WIF pool + SAs CI/CD en Hub, roles sobre Spoke DEV ────────────────
# - WIF pool + provider → Hub (project_id = hub_project_id)
# - SAs CI/CD (servicios + deploy) → Hub
# - IAM roles (Cloud Build, GKE, etc.) → Spoke DEV (roles_project_id = project_id)
module "iam" {
  source = "../../modules/iam"

  project_id       = local.hub_project_id
  project_num      = local.hub_project_num
  roles_project_id = local.project_id
  wif_pool         = local.config.wif.pool_name
  services = merge(
    {
      for name, svc in local.config.services : name => {
        sa_name     = svc.sa_name
        github_repo = svc.github_repo
        roles       = try(svc.roles, null)
      }
    },
    {
      "deploy" = {
        sa_name     = local.config.deploy.sa_name
        github_repo = local.config.deploy.github_repo
        roles       = local.config.deploy.roles
      }
    }
  )
}

# Roles Hub-level para el deploy SA (gestión de WIF pool + SAs en Hub)
# El deploy SA vive en Hub → necesita admin en Hub además de sus roles en Spoke DEV.
resource "google_project_iam_member" "hub_deploy_admin_roles" {
  for_each = toset([
    "roles/iam.serviceAccountAdmin",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/cloudbuild.builds.editor",  # necesario para gestionar Cloud Build triggers via Terraform
  ])

  project = local.hub_project_id
  role    = each.value
  member  = "serviceAccount:${module.iam.service_accounts["deploy"]}"
}

# ─── Cloud Build Worker Pool ────────────────────────────────────────────────
# Vive en Spoke DEV, peered a la Shared VPC para acceder al API server de GKE
# (Master Authorized Networks requiere conectividad privada).
resource "google_cloudbuild_worker_pool" "main" {
  name     = local.config.cloud_build.worker_pool_name
  location = local.region
  project  = local.project_id

  worker_config {
    disk_size_gb   = 100
    machine_type   = "e2-medium"
    no_external_ip = false
  }

  network_config {
    peered_network = local.config.cloud_build.network
  }
}

# ─── Hub AR — IAM para art-fin-shared en prj-sie-sb-fin-common ──────────────
# Los SAs ahora viven en Hub → emails usan hub_project_id.
# GKE Compute SA: ya tiene roles/artifactregistry.reader en Hub (pre-autorizado por org).
resource "google_artifact_registry_repository_iam_member" "hub_deploy_admin" {
  project    = local.hub_project_id
  location   = local.region
  repository = "art-fin-shared"
  role       = "roles/artifactregistry.admin"
  member     = "serviceAccount:${local.config.deploy.sa_name}@${local.hub_project_id}.iam.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "hub_cicd_writer" {
  for_each = local.config.services

  project    = local.hub_project_id
  location   = local.region
  repository = "art-fin-shared"
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${each.value.sa_name}@${local.hub_project_id}.iam.gserviceaccount.com"
}

# SAs del Spoke DEV que aún no han migrado su ci-pipeline.yml al WIF+SA de Hub.
# Necesitan writer sobre art-fin-shared (Hub) hasta que cada repo de servicio
# actualice su pipeline para usar sa-sie-fin-{svc}-cicd@prj-sie-sb-fin-common.
resource "google_artifact_registry_repository_iam_member" "spoke_dev_cicd_writer" {
  for_each = local.config.services

  project    = local.hub_project_id
  location   = local.region
  repository = "art-fin-shared"
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${each.value.sa_name}@${local.project_id}.iam.gserviceaccount.com"
}

# ─── Deploy SA del ambiente QA ──────────────────────────────────────────────
# Vive en Hub para reusar el WIF pool compartido.
# Tiene roles cross-project sobre prj-sie-fin-financiero-qas.
resource "google_service_account" "qa_deploy" {
  project      = local.hub_project_id
  account_id   = local.config.qa_deploy.sa_name
  display_name = "Deploy SA - QA"
}

resource "google_service_account_iam_member" "qa_deploy_wif" {
  service_account_id = google_service_account.qa_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${local.hub_project_num}/locations/global/workloadIdentityPools/${local.config.wif.pool_name}/attribute.repository/${local.config.qa_deploy.github_repo}"
}

resource "google_project_iam_member" "qa_deploy_roles" {
  for_each = toset(local.config.qa_deploy.roles)

  project = local.config.qa_deploy.qa_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.qa_deploy.email}"
}

# Acceso a la zona DNS compartida (vive en Spoke DEV) — para crear CNAME de validación TLS
resource "google_project_iam_member" "qa_deploy_dev_dns" {
  project = local.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.qa_deploy.email}"
}

# Acceso al bucket de TF state (vive en Spoke DEV)
resource "google_storage_bucket_iam_member" "qa_deploy_state_bucket" {
  bucket = "bkt-sie-fin-iac-state-${local.project_id}"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.qa_deploy.email}"
}

# ─── Outputs ────────────────────────────────────────────────────────────────
output "service_account_emails" {
  description = "Emails de SAs CI/CD de cada servicio"
  value       = module.iam.service_accounts
}

output "worker_pool_id" {
  description = "ID completo del Cloud Build Worker Pool"
  value       = google_cloudbuild_worker_pool.main.id
}

output "dns_name_servers" {
  description = "Name servers de la zona DNS (para delegación en el registrar)"
  value       = module.dns.name_servers
}

# ─── Import blocks ───────────────────────────────────────────────────────────
# IMPORTANTE: Idempotentes — si el recurso ya está en state, no hacen nada.
#
# Nota migración Hub (2026-05-18):
#   Los import blocks de WIF pool, SAs y hub_deploy_admin fueron eliminados
#   porque apuntaban a recursos en prj-sie-fin-financiero-dev (DEV).
#   Tras terraform state rm, TF crea recursos nuevos directamente en Hub.

# DNS Zone (Spoke DEV — sin cambios)
import {
  to = module.dns.google_dns_managed_zone.zone
  id = "projects/prj-sie-fin-financiero-dev/managedZones/siesacloud-dev"
}

# Cloud Build Worker Pool (Spoke DEV — sin cambios)
import {
  to = google_cloudbuild_worker_pool.main
  id = "projects/prj-sie-fin-financiero-dev/locations/us-east1/workerPools/financiero-pool"
}
