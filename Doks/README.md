# Doks Module - DOKS clusters from PowerShell

PowerShell module for the **imperative edge** of this repo: creating and
destroying the DigitalOcean Kubernetes (DOKS) cluster that ArgoCD then
takes over (`bootstrap/README.md`). It wraps `doctl`/`kubectl` so a test
cluster is one command to create, one to connect to, and - because DOKS
bills by the hour - one to delete *including* its load balancers and
volumes.

Works in Windows PowerShell 5.1 and PowerShell 7 (Windows, Linux, macOS).
Requires `doctl` and `kubectl` on `PATH`; `helm` and `terraform` too for
`Bootstrap-DoksCluster`.

## One-time setup

```powershell
Import-Module .\Doks           # or the full path to this folder
Set-DoksToken                  # paste a DO API token once (Kubernetes read+write)
Test-DoksSetup                 # doctl / kubectl / helm / terraform / token / API all green?
```

The token is stored per user, never in this repo: Windows Credential
Manager (`Doks/DigitalOcean-API-Token`) on Windows, `~/.doks/token`
elsewhere. `$env:DIGITALOCEAN_ACCESS_TOKEN` overrides both for a session.

## Daily use

```powershell
New-DoksCluster | Sync-DoksTerraform | Bootstrap-DoksCluster; Connect-DoksPortForward
                                   # the whole startup: create + connect, terraform apply (adopt
                                   # the cluster, managed database), GitOps handover, every UI
                                   # on localhost with its credentials
New-DoksCluster                    # create (fra1, 2x s-2vcpu-4gb, autoscale 2-10), wait, connect
Sync-DoksTerraform                 # terraform.tfvars = this cluster, state, init + apply (verbose)
Bootstrap-DoksCluster              # GitOps handover: namespaces+secrets, ArgoCD, root app
Connect-DoksPortForward            # ArgoCD, Grafana, Prometheus, Alertmanager on localhost
Get-DoksCluster                    # what is running (= what is billing) right now
Use-DoksCluster k8s-test-fra1      # point this window at an existing cluster
Disconnect-DoksCluster             # forget the cluster in this window
Remove-DoksCluster k8s-test-fra1   # delete cluster + load balancers/volumes + local kubeconfig
```

`Use-DoksCluster` sets `$env:KUBECONFIG` for the **current window only** —
other terminals and the machine-wide `~/.kube/config` are never touched,
so several clusters can be driven side by side.

## GitOps bootstrap

`Bootstrap-DoksCluster` (alias of `Initialize-DoksCluster`) shadows the
manual procedure in `bootstrap/README.md`: environment namespaces +
secrets (the managed database's endpoint and credentials from
`terraform output`, a random `jwt-secret`, optional GHCR pull secret), the
`monitoring` namespace with Grafana's admin password and the Alertmanager
notification channel (a webhook.site inbox created on the spot unless
`-AlertWebhookUrl` names your own), ArgoCD (pinned chart version) from
`bootstrap/argocd-values.yaml`, then the root application `argocd/root.yaml` -
after which ArgoCD pulls everything from git - and finally the load balancer IP
into the nip.io hosts of the overlays and the load test (commit that, together
with `terraform.tfvars`).

```powershell
New-DoksCluster | Sync-DoksTerraform            # cluster, then terraform.tfvars + init + apply (adopt it, managed database)
Bootstrap-DoksCluster k8s-test-fra1                # secrets from the Terraform outputs, ArgoCD, root app;
                                                   # alert channel = a webhook.site inbox opened in the browser
Bootstrap-DoksCluster k8s-test-fra1 `
    -GhcrUsername beatos-learns `                  # prompts for the read:packages PAT
    -AlertWebhookUrl https://hooks.example.org/x   # your own channel instead of the webhook.site inbox
Get-Help Bootstrap-DoksCluster -Full               # all parameters, examples, caveats
```

Safe to re-run: existing Secrets are never overwritten, ArgoCD upgrades in
place, the root application applies declaratively. `Sync-DoksTerraform` (or a
manual `terraform apply`) must have run first: the database outputs are read
from `terraform/` (-TerraformDir).

## Commands

| Command | Does |
|---|---|
| `New-DoksCluster` | create a cluster, wait until nodes are Ready, connect this window |
| `Get-DoksCluster` | list clusters (name, state, nodes, age — i.e. current billing) |
| `Use-DoksCluster` | fetch a kubeconfig and point this window at a cluster |
| `Disconnect-DoksCluster` | drop `$env:KUBECONFIG` in this window |
| `Remove-DoksCluster` | delete cluster **and** its load balancers/volumes (`-KeepResources` to keep); refuses clusters without the module tag unless `-Force` |
| `Wait-DoksNodeReady` | block until N nodes report Ready |
| `Get-DoksOption` | list valid `Regions` / `Sizes` / `Versions` |
| `Bootstrap-DoksCluster` | one-time GitOps bootstrap per `bootstrap/README.md` (alias of `Initialize-DoksCluster`) |
| `Sync-DoksTerraform` | write the cluster into `terraform/terraform.tfvars`, drop a previous cluster from the state, `terraform init` + `apply` (adopt the cluster, managed database); passes the cluster through the pipeline |
| `Sync-DoksHostname` | wait for the Traefik load balancer IP and write it into the nip.io hosts of both overlays and `loadtest/job.yaml` (the bootstrap's last step; standalone to repeat it) |
| `Set-DoksToken` / `Remove-DoksToken` | store / delete the API token per user |
| `Connect-DoksAccount` / `Disconnect-DoksAccount` / `Get-DoksAccount` | session auth against the DO API |
| `Get-DoksDefault` / `Set-DoksDefault` | inspect / change the effective settings |
| `Test-DoksSetup` | diagnose tools, token, API access, kubeconfig folder |
| `Connect-DoksPortForward` / `Disconnect-DoksPortForward` | forward ArgoCD (8080), Grafana (3000), Prometheus (9090) and Alertmanager (9093) to localhost in one command; Ctrl+C or the second command ends them all (`-Background` keeps them) |

All destructive commands support `-WhatIf` / `-Confirm`;
`Remove-DoksCluster` prompts unless `-Force` is given.

## Settings (layered)

Later layers win; `Get-DoksDefault` shows the effective result,
`Test-DoksSetup` shows which layers were loaded:

1. built-in defaults (`fra1`, 2× `s-2vcpu-2gb`, autoscale 2–10, …)
   — the repo file below raises the node size to `s-2vcpu-4gb` for the auth stack
2. `Doks.defaults.psd1` next to the module — the **repo's** settings,
   committed (tag `doks-VSC-deploy`, kubeconfigs to `../kubeconfig`)
3. `~/.doks/defaults.psd1` — personal overrides, never committed
4. `$env:DOKS_*` (e.g. `DOKS_REGION`, `DOKS_KUBECONFIG_DIR`)
5. `Set-DoksDefault` — this session
6. command parameters — this call

## Kubeconfigs

Fetched kubeconfigs land in the directory from the `KubeconfigDir`
setting — for this repo `kubeconfig/` at the repo root, which the root
`.gitignore` excludes (`/kubeconfig/`, `*-kubeconfig.yaml`).

> Kubeconfigs are cluster credentials. If you point `KubeconfigDir`
> somewhere else inside a repository, make sure that location is
> git-ignored too.

## Files

```
Doks.psd1            module manifest (import target)
Doks.psm1            implementation
Doks.defaults.psd1   repo-level settings (layer 2 above)
README.md            this file
```
