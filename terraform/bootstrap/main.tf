# Bootstrap: Crea el bucket de estado de Terraform y habilita APIs necesarias
# Ejecutar una sola vez: terraform init && terraform apply
# Ref CAF: Standard 14 - Infrastructure as Code

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "prj-sie-fin-financiero-dev"
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-east1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Bucket para Terraform state
resource "google_storage_bucket" "tf_state" {
  name     = "bkt-sie-fin-iac-state-${var.project_id}"
  location = var.region

  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    business-unit = "financiero"
    product-suite = "fin"
    environment   = "dev"
    managed-by    = "terraform"
  }
}

# APIs necesarias
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "dns.googleapis.com",
    "certificatemanager.googleapis.com",
    "sqladmin.googleapis.com",
    "pubsub.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

output "state_bucket" {
  value = google_storage_bucket.tf_state.name
}
