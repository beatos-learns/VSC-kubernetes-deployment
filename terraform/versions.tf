# Aufgabe 3 (Terraform IaC): the existing DOKS cluster under declarative
# management. Nothing here creates a cluster - imports.tf adopts the one the
# Doks module creates, and `terraform plan` must stay empty afterwards.
terraform {
  required_version = ">= 1.10"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.100"
    }
  }
}
