# Terraform (Aufgabe 3, Infrastructure as Code)

The DOKS cluster the Doks module creates is under Terraform management **as
imported infrastructure** - nothing here recreates it; the managed PostgreSQL
the environments use (Aufgabe 4, Managed Ressources) is created here. `terraform plan` on
`main` shows no changes for the running cluster; a change to a variable is a
reviewed change to the cluster.

```
terraform/
  versions.tf          Terraform >= 1.10, provider digitalocean/digitalocean ~> 2.100
  providers.tf         provider block; token from the environment, never from git
  variables.tf         every reusable value (name, region, version, node pool, tags, …)
  terraform.tfvars     the concrete cluster: id, name, version (nothing sensitive)
  imports.tf           import block that adopts the existing cluster into state
  generated.tf         the resource, stated as intent (see its header)
  database.tf          managed PostgreSQL: cluster in the VPC, database + role per
                       environment, firewall for the Kubernetes cluster
  outputs.tf           cluster id, endpoint, version, node pool; database endpoint
                       and (sensitive) credentials for the Secrets
  .terraform.lock.hcl  provider build pinned (commit it)
```

State is local (`terraform.tfstate`, git-ignored): one cluster, one operator.
Move it to a backend (DigitalOcean Spaces is S3-compatible) before a second
person runs `apply`.

## Token

The DigitalOcean API token is the one the Doks module stores in the Windows
Credential Manager. Export it for the shell you run Terraform in - it is not
a tfvar and no file in this directory may contain it:

```powershell
Import-Module .\Doks
$env:DIGITALOCEAN_TOKEN = & (Get-Module Doks) { (Read-DoksStoredToken).Token }
```

```sh
export DIGITALOCEAN_TOKEN=...            # bash; or TF_VAR_do_token for -var do_token
```

`.gitignore` excludes `*.auto.tfvars` and `secrets.tfvars` so a local token
file cannot be committed by accident; `terraform.tfvars` is committed and
therefore holds only the cluster's identity.

## Adopting a cluster (reproducible)

```sh
cd terraform
terraform init
terraform plan -generate-config-out=generated.tf   # with `provider = digitalocean` in the import block, see imports.tf
```

`generated.tf` is the **cleaned** result: the mutually exclusive GPU/RDMA/registry
plugin blocks (all `enabled = false`, rejected by the provider when present
together) and the null attributes are omitted, the account-specific network
ids are left computed, the autoscaler-owned `node_count` is ignored in plans,
and every literal is a variable. Then:

```sh
terraform fmt -check -recursive
terraform validate
terraform plan        # Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.
terraform apply       # writes the import into state - no infrastructure changes
terraform plan        # No changes. Your infrastructure matches the configuration.
```

The import block stays in `imports.tf`: it is a no-op once the resource is in
state and documents where the cluster came from.

## Managed PostgreSQL (Aufgabe 4, Managed Ressources)

`database.tf` creates one `db-s-1vcpu-1gb` PostgreSQL 16 cluster in the DOKS
VPC, a database and a login role per environment (`auth_staging`,
`auth_prod`) and a firewall that admits only the Kubernetes cluster
(`var.database_trusted_ips` adds operator addresses, e.g. for `psql`). Its
outputs feed the environment Secrets - `database` (private host, port,
database names) and `database_credentials` (sensitive: the roles and the
admin) - see `bootstrap/README.md` step 2; the chart carries no connection
data. Backups (daily, 7 days) and point-in-time recovery are the provider's
(`bootstrap/README.md` step 8). One cluster for both environments is the
cost decision (USD 15/month for the smallest node); a cluster per environment
is `for_each` on the cluster resource.

```sh
terraform -chdir=terraform apply                          # cluster adoption + database, one plan
terraform -chdir=terraform output database                 # endpoint and database names
terraform -chdir=terraform output -json database_credentials | jq .   # roles + admin (sensitive)
```

## Day-to-day

```sh
terraform -chdir=terraform plan              # drift check; must be empty on main
terraform -chdir=terraform apply             # after a reviewed variable change
terraform -chdir=terraform output            # endpoint, version, node pool
```

Typical changes and what they do:

| Change | Effect |
|---|---|
| `kubernetes_version` | control-plane upgrade (surge upgrade: nodes are replaced one by one, the pool never shrinks) |
| `max_nodes` / `min_nodes` | autoscaler bounds; the live count between them is the autoscaler's and ignored |
| `node_size` | DigitalOcean replaces the node pool - plan it, it drains the workloads |
| `tags` | keep `doks-VSC-deploy`: `Remove-DoksCluster` refuses to delete untagged clusters |
| `database_version` / `database_size` | in-place upgrade or resize by DigitalOcean, with a short connection loss - plan it |
| `database_trusted_ips` | firewall rules only |
| `environments` | adds or removes a database and its role; removing one drops its data |

Not managed here on purpose: the load balancer and the block-storage volumes.
They are created by Kubernetes (the Traefik Service, the PVCs) and owned by
the GitOps side; importing them would make two systems responsible for one
object. `ha = true` is a fixed fact of this cluster (DigitalOcean cannot
switch it off), so it is not a variable.

## CI

`validate.yml` runs `terraform fmt -check`, `terraform init -backend=false`
and `terraform validate` on every PR - no token needed, no plan against the
account from CI. The drift check (`plan`) is a local, authenticated step.

## Relation to the Doks module

`New-DoksCluster` creates throwaway clusters imperatively (its defaults in
`Doks/Doks.defaults.psd1` are the variable defaults here); the database only
exists through Terraform. Order for a new cluster: `New-DoksCluster`,
`Sync-DoksTerraform` (writes the cluster's id, name and version into
`terraform.tfvars`, drops a previous cluster from the state, runs `init` and
`apply` with the module's token: adopts the cluster, creates the database),
then `Bootstrap-DoksCluster` (reads the database outputs into the Secrets) -
or the same steps by hand as described above. `Remove-DoksCluster` bypasses
Terraform; the next `Sync-DoksTerraform` removes the deleted cluster from the
state before adopting the new one.
