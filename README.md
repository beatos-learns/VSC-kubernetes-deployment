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
   └─ PROMOTE ───────────────────────── commit ────► values-staging.yaml (tag bump)
                                        PR ────────► values-prod.yaml   (human gate)
                                                              │
                                                              ▼ pull (no push deploys!)
                                                     ArgoCD @ DOKS
                                                       ├─ ns argocd        ArgoCD itself
                                                       ├─ ns traefik       ingress controller (1 DO LB)
                                                       ├─ ns auth-staging  release "auth"
                                                       └─ ns auth-prod     release "auth"
```

Nothing in either repo runs `kubectl apply` or `helm upgrade` against the
cluster. GitHub workflows build, validate, and **commit**; ArgoCD pulls.
The only imperative step is the one-time bootstrap (`bootstrap/README.md`).

## Layout

```
bootstrap/                  one-time cluster setup: ArgoCD install values,
                            root app-of-apps, secrets procedure (documented,
                            never committed)
argocd/                     synced by the root app:
  project.yaml              strict AppProject for the env namespaces
  infra-traefik.yaml        Traefik ingress controller (official chart, MIT)
  app-staging.yaml          charts/auth-stack + values-staging.yaml → auth-staging
  app-prod.yaml             charts/auth-stack + values-prod.yaml   → auth-prod
charts/auth-stack/          wrapper chart:
  Chart.yaml                pins generic-stack (OCI dependency from GHCR)
  values.yaml               DO-common: storageClass, pull secret, ingress on,
                            in-stack proxy off, baseline resources
  values-staging.yaml       env overlay — CI promotion target (image tags)
  values-prod.yaml          env overlay — promoted via PR
  templates/                namespace policy only: ResourceQuota, NetworkPolicies
.github/workflows/
  validate.yml              PR/main gate: helm lint + template + kubeconform
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
| Promotion | automatic commit by CI | pull request by CI, human-merged |
| Replicas (backend/frontend) | 1 / 1 | 2 / 2 (→ HPA in Aufgabe 6) |
| Quota (req / lim CPU) | 1 / 2 | 2 / 4 |
| Quota (req / lim memory) | 1Gi / 2Gi | 2Gi / 4Gi |
| Isolation | default-deny ingress + same-namespace + ingress-controller→frontend | same |

## Promotion contract (CI-repo side)

The CI repo's `build.yml` gets a final `promote` job (to be added there):

1. Secret `OPS_REPO_TOKEN`: fine-grained PAT, contents read/write, scoped to
   **this repo only**.
2. After images + chart are published: clone this repo, bump
   `components.<name>.image.tag` in `charts/auth-stack/values-staging.yaml`,
   commit to `main` (message: `promote: <component> <tag>`).
3. Open/refresh a PR applying the same bump to `values-prod.yaml`.

ArgoCD detects the commit and converges the matching namespace. No cluster
credentials ever exist in GitHub.

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
