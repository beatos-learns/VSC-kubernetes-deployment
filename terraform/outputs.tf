output "cluster_id" {
  description = "UUID of the managed cluster."
  value       = digitalocean_kubernetes_cluster.this.id
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = digitalocean_kubernetes_cluster.this.endpoint
}

output "kubernetes_version" {
  description = "Running DOKS version slug."
  value       = digitalocean_kubernetes_cluster.this.version
}

output "node_pool" {
  description = "Default node pool as the API reports it (size, live count, autoscale bounds)."
  value = {
    name       = digitalocean_kubernetes_cluster.this.node_pool[0].name
    size       = digitalocean_kubernetes_cluster.this.node_pool[0].size
    node_count = digitalocean_kubernetes_cluster.this.node_pool[0].actual_node_count
    min_nodes  = digitalocean_kubernetes_cluster.this.node_pool[0].min_nodes
    max_nodes  = digitalocean_kubernetes_cluster.this.node_pool[0].max_nodes
  }
}
