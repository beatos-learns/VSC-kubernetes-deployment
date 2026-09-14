# Aufgaben 3 + 4 (Terraform IaC, managed resources): the DOKS cluster under
# declarative management - never created here, imports.tf adopts the one the
# Doks module creates - and the managed PostgreSQL it uses (database.tf),
# which is created here. `terraform plan` must stay empty in between changes.
terraform {
  required_version = ">= 1.10"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.100"
    }
  }
}
