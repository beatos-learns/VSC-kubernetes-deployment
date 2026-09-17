# Sensitive input - no default on purpose, see providers.tf.
variable "do_token" {
  description = "DigitalOcean API token (Kubernetes read/write). Prefer the DIGITALOCEAN_TOKEN environment variable over a tfvars file."
  type        = string
  sensitive   = true
  default     = null
  nullable    = true
}

# Identity of the cluster that imports.tf adopts. The id is what
# `doctl kubernetes cluster get <name>` reports; the name must match the
# cluster's current name or the plan renames it.
variable "cluster_id" {
  description = "UUID of the existing DOKS cluster to import (doctl kubernetes cluster get <name> --format ID)."
  type        = string
}

variable "cluster_name" {
  description = "Name of the DOKS cluster (the Doks module default is k8s-test-<region>)."
  type        = string
  default     = "k8s-test-fra1"
}

# The values below mirror Doks/Doks.defaults.psd1 (what New-DoksCluster
# creates). Changing one here changes the cluster (after review of the plan).
variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "fra1"
}

variable "kubernetes_version" {
  description = "Exact DOKS version slug (doctl kubernetes options versions). A change here is a control-plane upgrade."
  type        = string
}

variable "node_pool_name" {
  description = "Name of the default node pool (the Doks module uses pool-<cluster name>)."
  type        = string
  default     = "pool-k8s-test-fra1"
}

variable "node_size" {
  description = "Droplet size of the worker nodes."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "node_count" {
  description = "Initial node count; with autoscaling the autoscaler owns the live count (ignored in plans)."
  type        = number
  default     = 2
}

variable "min_nodes" {
  description = "Autoscaler lower bound. Two, so anti-affinity, PDBs and rolling updates have somewhere to go."
  type        = number
  default     = 2
}

variable "max_nodes" {
  description = "Autoscaler upper bound."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Tags on the cluster. `doks-VSC-deploy` marks it as owned by this repo (Remove-DoksCluster refuses untagged clusters)."
  type        = list(string)
  default     = ["doks-VSC-deploy"]
}

variable "maintenance_window" {
  description = "Weekly maintenance window for automatic patch upgrades (day `any` = DigitalOcean picks)."
  type = object({
    day        = string
    start_time = string
  })
  default = {
    day        = "any"
    start_time = "00:00"
  }
}

# Managed PostgreSQL (database.tf). One database and one login role per
# environment on a single cluster; the sizes are the smallest DigitalOcean
# offers, matching the throwaway character of the platform.
variable "environments" {
  description = "Environments that get a database and a login role (auth_<name>) on the managed PostgreSQL cluster - the auth-stack namespaces without their auth- prefix."
  type        = set(string)
  default     = ["staging", "prod"]
}

variable "database_version" {
  description = "PostgreSQL major version of the managed cluster (doctl databases options versions --engine pg); the seed SQL targets 16."
  type        = string
  default     = "16"
}

variable "database_size" {
  description = "Size slug of the database node (doctl databases options slugs --engine pg)."
  type        = string
  default     = "db-s-1vcpu-1gb"
}

variable "database_trusted_ips" {
  description = "Operator addresses (IP or CIDR) allowed through the database firewall besides the Kubernetes cluster, e.g. for psql from a workstation. Empty: cluster-only."
  type        = list(string)
  default     = []
}

# Managed MySQL of the module service (database.tf, Aufgabe 6, Microservices):
# same shape and size class as the PostgreSQL cluster, one database and one
# login role per environment (modules_<name>).
variable "mysql_version" {
  description = "MySQL major version of the managed cluster (doctl databases options versions --engine mysql); the module service targets 8.4."
  type        = string
  default     = "8.4"
}

variable "mysql_size" {
  description = "Size slug of the MySQL database node (doctl databases options slugs --engine mysql)."
  type        = string
  default     = "db-s-1vcpu-1gb"
}
