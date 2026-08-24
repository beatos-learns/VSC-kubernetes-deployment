# VSC-kubernetes-deployment

GitOps **Ops repository** for the auth stack built in
[VSC-kubernetes-containers](https://github.com/beatos-learns/VSC-kubernetes-containers)
(CI repo: images + the `generic-stack` Helm chart, published to GHCR as OCI
artifacts). This repo declares *what runs where*: environment values, ArgoCD
Application manifests, and namespace policy for a DigitalOcean Kubernetes
(DOKS) cluster.

TEKO «Verteilte Systeme, Containerisierung» — Orchestrierung
(`VSC_Orchestrierung.pdf`).

## How a change reaches the cluster

```
 CI repo (VSC-kubernetes-containers)                 Ops repo (this)
 ───────────────────────────────────                 ────────────────────────────
 push to master                                      
   └─ build images ─ publish to GHCR                 
   └─ publish generic-stack chart (OCI)              
   └─ PROMOTE ────────── PR, auto-merge on ✓ ─────► values-staging.yaml (tag bump)
                         PR, human-merged ────────► values-prod.yaml   (prod gate)
                                                              │
                                                              ▼ pull (no push deploys!)
                                                     ArgoCD @ DOKS
                                                       ├─ ns argocd        ArgoCD itself
                                                       ├─ ns traefik       ingress controller (1 DO LB, TLS)
                                                       ├─ ns cert-manager  ACME certificates for the hosts
                                                       ├─ ns auth-staging  release "auth"
                                                       └─ ns auth-prod     release "auth"
```

Nothing in either repo runs `kubectl apply` or `helm upgrade` against the
cluster. GitHub workflows build, validate, and **commit**; ArgoCD pulls.
The only imperative step is the one-time bootstrap (`bootstrap/README.md`) -
automated by the `Doks` PowerShell module as
`New-DoksCluster | Bootstrap-DoksCluster` (see `Doks/README.md`).

## Layout

```
bootstrap/                  one-time cluster setup: ArgoCD install values,
                            root app-of-apps, secrets procedure (documented,
                            never committed)
argocd/                     synced by the root app:
  project.yaml              strict AppProject for the env namespaces
  infra-traefik.yaml        Traefik ingress controller (official chart, MIT)
  infra-cert-manager.yaml   cert-manager (official chart, Apache-2.0)
  infra-cert-manager-issuer.yaml
                            ClusterIssuers from cert-manager-issuer/, wave-
                            ordered after the cert-manager CRDs
  app-staging.yaml          charts/auth-stack + values-staging.yaml → auth-staging
  app-prod.yaml             charts/auth-stack + values-prod.yaml   → auth-prod
cert-manager-issuer/        Let's Encrypt ClusterIssuers (prod + staging ACME
                            endpoint), applied by infra-cert-manager-issuer
charts/auth-stack/          wrapper chart:
  Chart.yaml                pins generic-stack (OCI dependency from GHCR)
  values.yaml               DO-common: storageClass, pull secret, ingress on
                            (+ cert-manager annotation), in-stack proxy off,
                            baseline resources
  values-staging.yaml       env overlay — CI promotion target (image tags)
  values-prod.yaml          env overlay — promoted via PR
  templates/                namespace policy only: ResourceQuota, NetworkPolicies
                            (default-deny, same-ns, ingress→frontend,
                            ingress→ACME solver)
Doks/                       PowerShell module: create/connect/delete the
                            throwaway DOKS cluster and run the bootstrap
                            (New-DoksCluster | Bootstrap-DoksCluster);
                            see Doks/README.md
.github/workflows/
  validate.yml              PR/main gate: helm lint + template + kubeconform;
                            uploads the rendered manifests per env as a run
                            artifact (debug aid for red-gated PRs)
```

## Design decisions

* **Wrapper chart, not a fork.** `auth-stack` declares `generic-stack` as an
  OCI dependency (`helm dependency build` vendors it via `Chart.lock`). The
  CI repo owns application policy (probes, security posture, wiring); this
  repo owns environment policy (sizes, hosts, quotas, isolation). Image tags
  are overridden per environment — that override is the promotion interface.
* **One ingress controller instead of per-env proxies.** The chart's in-stack
  Traefik `proxy` component is disabled; a cluster-wide Traefik
  (`argocd/infra-traefik.yaml`) serves standard `Ingress` resources for all
  environments through a single DigitalOcean load balancer.
* **TLS via cert-manager + Let's Encrypt (HTTP-01).** Traefik redirects
  `web` → `websecure` permanently (ACME bypass on); the frontend Ingress
  carries `cert-manager.io/cluster-issuer: letsencrypt-prod` and a per-env
  `tls` secret, so the auth-portal's `Secure` cookie default actually holds.
  Hosts are nip.io names on the Traefik LB IP: a fresh cluster means a new
  IP, new host, new certificate — and nip.io is not on the Public Suffix
  List, so Let's Encrypt's 50-certs/week limit is shared with every nip.io
  user (escape hatch: the `letsencrypt-staging` issuer). The NetworkPolicy
  explicitly allows the ingress controller to reach the HTTP-01 solver pods;
  default-deny would otherwise silently block every challenge.
  Stack note: cert-manager is Apache-2.0 and CNCF-graduated (originated at
  Jetstack UK, now maintained under Venafi/CyberArk); Let's Encrypt is run by
  ISRG, a US non-profit. Both are accepted as the pragmatic self-hosted /
  passive exception; a European ACME CA (e.g. ZeroSSL, AT) is a drop-in
  swap via `externalAccountBinding` on the ClusterIssuer.
* **Secrets never touch git.** `db-password`, `jwt-secret`, and the GHCR pull
  secret are created out-of-band per namespace (see `bootstrap/README.md`)
  and referenced via `existingSecret`. Upgrade path if full GitOps for
  secrets is wanted later: Sealed Secrets (Apache-2.0).
* **Prod auto-syncs too.** The production gate is the promotion *pull
  request*, not a manual sync button — review happens in git, where it is
  auditable.
* **HPA/PDB (Aufgabe 6) belong in `generic-stack`.** They are policy
  templates for the component model, to be added in the CI repo; this repo
  will then only set thresholds in `values-prod.yaml` (see TODO markers).

## Environments

| | staging | prod |
|---|---|---|
| Namespace | `auth-staging` | `auth-prod` |
| Values | `values-staging.yaml` | `values-prod.yaml` |
| Promotion | PR by CI, auto-merged on green validate | PR by CI, human-merged |
| Replicas (backend/frontend) | 1 / 1 | 2 / 2 (→ HPA in Aufgabe 6) |
| Quota (req / lim CPU) | 1 / 2 | 2 / 4 |
| Quota (req / lim memory) | 1Gi / 2Gi | 2Gi / 4Gi |
| Host | `auth-staging.<lb-ip>.nip.io` | `auth-prod.<lb-ip>.nip.io` |
| TLS secret | `auth-staging-tls` (Let's Encrypt) | `auth-prod-tls` (Let's Encrypt) |
| Isolation | default-deny ingress + same-namespace + ingress-controller→frontend / ACME solver | same |

## Promotion contract (CI-repo side)

The CI repo's `build.yml` gets a final `promote` job (see
`CI-REPO-NOTES.md`):

1. Secret `OPS_REPO_TOKEN`: fine-grained PAT, Contents + Pull requests
   read/write, scoped to **this repo only**.
2. After images + chart are published: bump
   `components.<name>.image.tag` in `charts/auth-stack/values-staging.yaml`
   on branch `promote/staging`, open a PR, enable auto-merge — it merges
   itself once the `validate` checks pass.
3. Open/refresh a PR applying the same bump to `values-prod.yaml`
   (`promote/prod`) — merged by a human.

`main` is enforced by the `main-protection` ruleset: changes only via PR,
and only with green `chart (staging)`, `chart (prod)`, and
`argocd-manifests` checks — an invalid configuration cannot reach the branch
ArgoCD watches. ArgoCD detects the merge and converges the matching
namespace. No cluster credentials ever exist in GitHub.

## Working locally

```sh
helm dependency build charts/auth-stack
helm lint charts/auth-stack -f charts/auth-stack/values.yaml \
  -f charts/auth-stack/values-staging.yaml --strict
helm template auth charts/auth-stack --namespace auth-staging \
  -f charts/auth-stack/values.yaml -f charts/auth-stack/values-staging.yaml
```

Same steps run in CI (`validate.yml`) for both environments, plus
`kubeconform` against the cluster's Kubernetes version.

## Task mapping (grading)

| Aufgabe | Where |
|---|---|
| 1 Manifests | historical — rendered by `helm template` (tag `aufgabe-1`); originals evolved into the CI repo's chart |
| 2 Helm chart | `generic-stack` in the CI repo; consumed here as OCI dependency |
| 3 ArgoCD | `bootstrap/`, `argocd/` — dedicated `argocd` ns, apps deploy to separate namespaces, dashboard via port-forward |
| 4 Pipeline | CI repo `build.yml` (build/scan/publish) + promotion commits into this repo; `validate.yml` here is deploy-free |
| 5 Namespaces | `values-*.yaml` overlays, `templates/resourcequota.yaml`, `templates/networkpolicy.yaml` |
| 6 Scaling | resources/probes/strategy via `generic-stack`; HPA + PDB values land in `values-prod.yaml` once the chart ships them |
