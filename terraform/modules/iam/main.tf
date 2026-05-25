# Módulo: IAM + Workload Identity Federation para CI/CD
# Ref CAF: Standard 06 - IAM and Security, Standard 16 - CI/CD

variable "project_id" { type = string }
variable "project_num" { type = string }
variable "wif_pool" { type = string }
# Si se especifica, los roles de CI/CD se otorgan sobre este proyecto (Spoke)
# en lugar del proyecto donde viven los SAs (Hub).
variable "roles_project_id" {
  type    = string
  default = null
}
variable "services" {
  type = map(object({
    sa_name     = string
    github_repo = string
    roles       = optional(list(string))
  }))
}

locals {
  # Roles por defecto para servicios de aplicación
  default_roles = [
    "roles/cloudbuild.builds.editor",
    "roles/artifactregistry.writer",
    "roles/container.developer",
    "roles/secretmanager.secretAccessor",
  ]
}

# WIF Pool
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.wif_pool
  display_name              = "GitHub Actions"
}

# WIF Provider
resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  # Restricción de seguridad: solo tokens de la organización SiesaTeams son aceptados.
  # assertion.repository_owner es un claim nativo del token OIDC de GitHub Actions.
  attribute_condition = "assertion.repository_owner == 'SiesaTeams'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Service Account por servicio
resource "google_service_account" "cicd" {
  for_each = var.services

  project      = var.project_id
  account_id   = each.value.sa_name
  display_name = "CI/CD SA for ${each.key}"
}

# Binding: GitHub repo → SA via WIF
resource "google_service_account_iam_member" "wif_binding" {
  for_each = var.services

  service_account_id = google_service_account.cicd[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${var.project_num}/locations/global/workloadIdentityPools/${var.wif_pool}/attribute.repository/${each.value.github_repo}"
}

# Roles necesarios para CI/CD
# Usa roles personalizados si se definen, sino usa los roles por defecto
resource "google_project_iam_member" "cicd_roles" {
  for_each = {
    for pair in flatten([
      for svc, cfg in var.services : [
        for role in coalesce(cfg.roles, local.default_roles) : {
          key  = "${svc}-${role}"
          sa   = svc
          role = role
        }
      ]
    ]) : pair.key => pair
  }

  project = coalesce(var.roles_project_id, var.project_id)
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.cicd[each.value.sa].email}"
}

output "service_accounts" {
  value = {
    for k, v in google_service_account.cicd : k => v.email
  }
}
