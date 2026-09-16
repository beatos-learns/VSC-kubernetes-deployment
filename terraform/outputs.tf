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

output "database" {
  description = "Managed PostgreSQL endpoint (private, VPC-only) and the database per environment - what the auth-stack-secrets Secret carries (bootstrap/README.md step 2)."
  value = {
    host      = digitalocean_database_cluster.postgres.private_host
    port      = digitalocean_database_cluster.postgres.port
    version   = digitalocean_database_cluster.postgres.version
    databases = { for env, db in digitalocean_database_db.environment : env => db.name }
  }
}

output "database_credentials" {
  description = "Login role per environment and the cluster admin, for the auth-stack-secrets Secret. Sensitive: read with terraform output -json database_credentials."
  sensitive   = true
  value = {
    admin = {
      user     = digitalocean_database_cluster.postgres.user
      password = digitalocean_database_cluster.postgres.password
    }
    environments = {
      for env, user in digitalocean_database_user.environment : env => {
        user     = user.name
        password = user.password
      }
    }
  }
}

output "modules_database" {
  description = "Managed MySQL of the module service: private endpoint, the database per environment and the cluster CA the service verifies the server against - the mysql-* and database-url keys of the auth-stack-secrets Secret (bootstrap/README.md step 2)."
  value = {
    host      = digitalocean_database_cluster.mysql.private_host
    port      = digitalocean_database_cluster.mysql.port
    version   = digitalocean_database_cluster.mysql.version
    databases = { for env, db in digitalocean_database_db.modules : env => db.name }
    ca        = data.digitalocean_database_ca.mysql.certificate
  }
}

output "modules_database_credentials" {
  description = "Login role per environment and the cluster admin of the managed MySQL. Sensitive: read with terraform output -json modules_database_credentials."
  sensitive   = true
  value = {
    admin = {
      user     = digitalocean_database_cluster.mysql.user
      password = digitalocean_database_cluster.mysql.password
    }
    environments = {
      for env, user in digitalocean_database_user.modules : env => {
        user     = user.name
        password = user.password
      }
    }
  }
}
