# The DOKS cluster as intent, not as the API reports it (the raw output of
# `terraform plan -generate-config-out` is not valid as written):
#   - no GPU plugin/DRA and RDMA/P2P-registry blocks: all `enabled = false`,
#     mutually exclusive, rejected by the provider when present together
#   - no null attributes (`destroy_all_associated_resources`,
#     `kubeconfig_expire_seconds`, `registry_integration`) and no provider
#     defaults (`routing_agent { enabled = false }`, `isolated_workers = false`)
#   - `cluster_subnet`, `service_subnet`, `vpc_uuid`, `worker_subnet_uuid` are
#     left computed: what DigitalOcean assigns from the default VPC, so the
#     configuration is not tied to one account's network ids
#   - node_pool: `node_count` is autoscaler-owned (the API reports 0) ->
#     var.node_count, ignored in plans below; no empty `labels`/`tags`, no
#     null `gpu_partition_mode`
#   - every literal is a variable (variables.tf), so the same configuration
#     adopts or creates a cluster with the Doks module's defaults
resource "digitalocean_kubernetes_cluster" "this" {
  name    = var.cluster_name
  region  = var.region
  version = var.kubernetes_version
  tags    = var.tags

  # Control plane: HA (cannot be switched off again), surge upgrades so node
  # replacements never drop below the pool size, no unattended minor upgrades -
  # a version bump is a reviewed change to var.kubernetes_version.
  ha            = true
  surge_upgrade = true
  auto_upgrade  = false

  maintenance_policy {
    day        = var.maintenance_window.day
    start_time = var.maintenance_window.start_time
  }

  # DOKS default; keeps CoreDNS replicas proportional to the node count.
  coredns_autoscaler {
    enabled = true
  }

  node_pool {
    name       = var.node_pool_name
    size       = var.node_size
    node_count = var.node_count
    auto_scale = true
    min_nodes  = var.min_nodes
    max_nodes  = var.max_nodes
  }

  lifecycle {
    # The cluster autoscaler owns the live node count between min and max;
    # `version` moves on its own during automatic patch upgrades in the
    # maintenance window and must not be reverted by the next apply.
    ignore_changes = [
      node_pool[0].node_count,
    ]
  }
}
