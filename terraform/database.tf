# DigitalOcean Managed PostgreSQL (Aufgabe 4, Managed Ressources): one single-node cluster in the
# DOKS VPC, one database and one login role per environment, reachable only
# from the Kubernetes cluster (plus var.database_trusted_ips). Backups,
# failover and version upgrades are DigitalOcean's; nothing in the Kubernetes
# cluster runs PostgreSQL.
resource "digitalocean_database_cluster" "postgres" {
  name                 = "${var.cluster_name}-pg"
  engine               = "pg"
  version              = var.database_version
  size                 = var.database_size
  region               = var.region
  node_count           = 1
  private_network_uuid = digitalocean_kubernetes_cluster.this.vpc_uuid
  tags                 = var.tags
}

# The application connects as the environment's role; the schema seed Job
# (charts/auth-stack) creates the tables as the cluster admin and grants that
# role DML only - it owns nothing and cannot alter the schema.
resource "digitalocean_database_db" "environment" {
  for_each   = var.environments
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = "auth_${each.key}"
}

resource "digitalocean_database_user" "environment" {
  for_each   = var.environments
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = "auth_${each.key}"
}

# Only the Kubernetes cluster's nodes may connect; operator addresses have to
# be listed explicitly.
resource "digitalocean_database_firewall" "postgres" {
  cluster_id = digitalocean_database_cluster.postgres.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.this.id
  }

  dynamic "rule" {
    for_each = var.database_trusted_ips
    content {
      type  = "ip_addr"
      value = rule.value
    }
  }
}

# DigitalOcean Managed MySQL (Aufgabe 6, Microservices): the module service's own
# database, shaped like the PostgreSQL cluster - one single-node cluster in the
# DOKS VPC, a database and a login role per environment, the same firewall.
# Only the modules pods and their seed Job receive its credentials; the
# user-mgmt backend reaches modules through the module service's API.
resource "digitalocean_database_cluster" "mysql" {
  name                 = "${var.cluster_name}-mysql"
  engine               = "mysql"
  version              = var.mysql_version
  size                 = var.mysql_size
  region               = var.region
  node_count           = 1
  private_network_uuid = digitalocean_kubernetes_cluster.this.vpc_uuid
  tags                 = var.tags
}

resource "digitalocean_database_db" "modules" {
  for_each   = var.environments
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = "modules_${each.key}"
}

resource "digitalocean_database_user" "modules" {
  for_each   = var.environments
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = "modules_${each.key}"
}

resource "digitalocean_database_firewall" "mysql" {
  cluster_id = digitalocean_database_cluster.mysql.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.this.id
  }

  dynamic "rule" {
    for_each = var.database_trusted_ips
    content {
      type  = "ip_addr"
      value = rule.value
    }
  }
}

# The cluster's CA certificate: the module service verifies the server's
# certificate chain and host name against it (MYSQL_SSL_MODE=verify-identity).
data "digitalocean_database_ca" "mysql" {
  cluster_id = digitalocean_database_cluster.mysql.id
}
