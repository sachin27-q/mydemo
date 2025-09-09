terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
  }
  required_version = ">= 1.0"
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Enable APIs
resource "google_project_service" "enable_apis" {
  for_each = toset([
    "container.googleapis.com",     # GKE
    "sqladmin.googleapis.com",      # Cloud SQL
    "pubsub.googleapis.com",        # Pub/Sub
    "containerregistry.googleapis.com", # GCR
    "iam.googleapis.com",
    "compute.googleapis.com",
    "servicemanagement.googleapis.com",
    "serviceusage.googleapis.com",
    "iamcredentials.googleapis.com",
  ])
  project = var.project_id
  service = each.key
}

# Service account for CI / GKE
resource "google_service_account" "ci" {
  account_id   = "ci-deployer"
  display_name = "CI deployer for github actions"
}

# Bind roles to service account (minimum set)
resource "google_project_iam_member" "ci_roles" {
  for_each = toset([
    "roles/container.developer",
    "roles/iam.serviceAccountUser",
    "roles/storage.admin",        # for pushing images to GCR (or storage.objectAdmin)
    "roles/cloudsql.client",
    "roles/pubsub.editor"
  ])
  project = var.project_id
  member  = "serviceAccount:${google_service_account.ci.email}"
  role    = each.key
}

# Create a key for CI (you will store the JSON in GitHub)
resource "google_service_account_key" "ci_key" {
  service_account_id = google_service_account.ci.name
  keepers = {
    # keepers to avoid replacement unless SA changes
    sa = google_service_account.ci.email
  }
}

# GKE cluster (small, low-cost)
resource "google_container_cluster" "gke" {
  name     = "demo1-gke"
  location = var.zone

  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {}

  network_policy {
    enabled = true
  }
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "small-pool"
  cluster    = google_container_cluster.gke.name
  location   = var.zone

  autoscaling {
    min_node_count = 0
    max_node_count = 2
  }

  node_config {
    machine_type = var.gke_machine_type
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  initial_node_count = 1
}

# Cloud SQL Postgres
resource "google_sql_database_instance" "postgres" {
  name             = "demo1-postgres"
  project          = var.project_id
  region           = var.region
  database_version = "POSTGRES_15"

  settings {
    tier = "db-custom-1-3840" # very small, you can change to shared-core if needed
    availability_type = "ZONAL"
    backup_configuration {
      enabled = false
    }
    ip_configuration {
      ipv4_enabled    = true   # for quick setup; for production use private ip and VPC
      authorized_networks = [] # keep empty; we'll use Cloud SQL Auth Proxy
    }
  }
}

resource "google_sql_database" "appdb" {
  instance = google_sql_database_instance.postgres.name
  name     = "appdb"
  project  = var.project_id
}

resource "google_sql_user" "appuser" {
  name     = "appuser"
  instance = google_sql_database_instance.postgres.name
  password = "ChangeThisPassword123!" # replace with secret or use terraform variable
}

# Pub/Sub topic
resource "google_pubsub_topic" "app_topic" {
  name    = "demo1-topic"
  project = var.project_id
}

# (Optional) create a registry repository - for Artifact Registry; GCR doesn't need this
resource "google_artifact_registry_repository" "docker_repo" {
  provider = google
  project  = var.project_id
  location = var.region
  repository_id = "demo1-docker"
  format = "DOCKER"
  description = "Docker repo for demo1"
}

# Outputs
output "gke_name" {
  value = google_container_cluster.gke.name
}
output "gke_zone" {
  value = var.zone
}
output "cloud_sql_instance" {
  value = google_sql_database_instance.postgres.name
}
output "service_account_key" {
  value = google_service_account_key.ci_key.private_key
  sensitive = true
}
