# Doks Module - DOKS clusters from PowerShell

PowerShell module for the **imperative edge** of this repo: creating and
destroying the DigitalOcean Kubernetes (DOKS) cluster that ArgoCD then
takes over (`bootstrap/README.md`). It wraps `doctl`/`kubectl` so a test
cluster is one command to create, one to connect to, and - because DOKS
bills by the hour - one to delete *including* its load balancers and
volumes.

Works in Windows PowerShell 5.1 and PowerShell 7 (Windows, Linux, macOS).
Requires `doctl` and `kubectl` on `PATH`; `helm` too for
`Bootstrap-DoksCluster`.

## One-time setup

```powershell
Import-Module .\Doks           # or the full path to this folder
Set-DoksToken                  # paste a DO API token once (Kubernetes read+write)
Test-DoksSetup                 # doctl / kubectl / token / API all green?
```

The token is stored per user, never in this repo: Windows Credential
Manager (`Doks/DigitalOcean-API-Token`) on Windows, `~/.doks/token`
elsewhere. `$env:DIGITALOCEAN_ACCESS_TOKEN` overrides both for a session.

## Daily use

```powershell
New-DoksCluster                    # create (fra1, 2x s-2vcpu-4gb, autoscale 2-5), wait, connect
kubectl get nodes                  # this window now talks to the new cluster
Get-DoksCluster                    # what is running (= what is billing) right now
Use-DoksCluster k8s-test-fra1      # point this window at an existing cluster
Bootstrap-DoksCluster              # GitOps handover: namespaces+secrets, ArgoCD, root app
Disconnect-DoksCluster             # forget the cluster in this window
Remove-DoksCluster k8s-test-fra1   # delete cluster + load balancers/volumes + local kubeconfig
```

`Use-DoksCluster` sets `$env:KUBECONFIG` for the **current window only** —
other terminals and the machine-wide `~/.kube/config` are never touched,
so several clusters can be driven side by side.

## GitOps bootstrap

`Bootstrap-DoksCluster` (alias of `Initialize-DoksCluster`) shadows the
manual procedure in `bootstrap/README.md`: environment namespaces +
secrets (random `db-password`/`jwt-secret`, optional GHCR pull secret),
ArgoCD (pinned chart version) from `bootstrap/argocd-values.yaml`, then the root
application `argocd/root.yaml` -
after which ArgoCD pulls everything from git.

```powershell
New-DoksCluster | Bootstrap-DoksCluster            # fresh cluster, one line
Bootstrap-DoksCluster k8s-test-fra1 `
    -GhcrUsername beatos-learns                    # prompts for the read:packages PAT
Get-Help Bootstrap-DoksCluster -Full               # all parameters, examples, caveats
```

Safe to re-run: existing Secrets are never overwritten (a regenerated
`db-password` would not match the initialized PostgreSQL PVC), ArgoCD
upgrades in place, the root application applies declaratively.

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
| `Set-DoksToken` / `Remove-DoksToken` | store / delete the API token per user |
| `Connect-DoksAccount` / `Disconnect-DoksAccount` / `Get-DoksAccount` | session auth against the DO API |
| `Get-DoksDefault` / `Set-DoksDefault` | inspect / change the effective settings |
| `Test-DoksSetup` | diagnose tools, token, API access, kubeconfig folder |

All destructive commands support `-WhatIf` / `-Confirm`;
`Remove-DoksCluster` prompts unless `-Force` is given.

## Settings (layered)

Later layers win; `Get-DoksDefault` shows the effective result,
`Test-DoksSetup` shows which layers were loaded:

1. built-in defaults (`fra1`, `s-2vcpu-2gb`, autoscale 1–5, …)
   — the repo file below raises this to 2× `s-2vcpu-4gb` for the auth stack
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
