# Adopts the existing cluster (the one the Doks module creates) into state:
# a no-op once imported, kept as the record of where the cluster comes from.
# Regenerating generated.tf from a live cluster: remove the resource block,
# add `provider = digitalocean` here (without a resource block Terraform would
# look the type up under hashicorp/digitalocean), run
# `terraform plan -generate-config-out=generated.tf`, then drop the provider
# argument again - it is rejected once the resource block exists.
import {
  to = digitalocean_kubernetes_cluster.this
  id = var.cluster_id
}
