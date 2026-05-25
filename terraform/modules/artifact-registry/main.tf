# Módulo: Artifact Registry
# Ref CAF: Standard 16 - CI/CD and Automation

variable "project_id" { type = string }
variable "region" { type = string }
variable "repos" { type = map(string) }
variable "labels" { type = map(string) }
variable "writer_members" {
  type        = list(string)
  default     = []
  description = "SAs que reciben roles/artifactregistry.writer en todos los repos (ej: Compute SA, Cloud Build SA)"
}

resource "google_artifact_registry_repository" "repo" {
  for_each = var.repos

  project       = var.project_id
  location      = var.region
  repository_id = each.key
  description   = each.value
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-last-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  labels = var.labels
}

# IAM: writer_members reciben acceso de escritura en todos los repos
# (Cloud Build worker pool corre como Compute SA, no como el SA de CI/CD)
resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each = {
    for pair in flatten([
      for repo_key in keys(var.repos) : [
        for member in var.writer_members : {
          key    = "${repo_key}-${member}"
          repo   = repo_key
          member = member
        }
      ]
    ]) : pair.key => pair
  }

  project    = var.project_id
  location   = var.region
  repository = each.value.repo
  role       = "roles/artifactregistry.writer"
  member     = each.value.member

  depends_on = [google_artifact_registry_repository.repo]
}

output "repo_urls" {
  value = {
    for k, v in google_artifact_registry_repository.repo :
    k => "${v.location}-docker.pkg.dev/${var.project_id}/${v.repository_id}"
  }
}
