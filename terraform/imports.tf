# Adopt, never recreate: the cluster exists (created by the Doks module),
# this block tells Terraform which resource address owns it. First run, with
# no resource block present yet:
#   terraform plan -generate-config-out=generated.tf   (writes the resource)
#   terraform apply                                     (records it in state)
# While generating, the block additionally needs `provider = digitalocean` -
# without a resource block Terraform would otherwise look the type up under
# hashicorp/digitalocean. Once the resource exists that argument is rejected,
# so it is gone again. The block itself stays: it is a no-op once the
# resource is in state, and it documents where the cluster came from.
import {
  to = digitalocean_kubernetes_cluster.this
  id = var.cluster_id
}
