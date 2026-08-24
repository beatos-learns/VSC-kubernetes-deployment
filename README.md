# VSC-kubernetes-deployment

GitOps **Ops repository** for the auth stack built in
[VSC-kubernetes-containers](https://github.com/beatos-learns/VSC-kubernetes-containers)
(CI repo: images + the `generic-stack` Helm chart, published to GHCR as signed
OCI artifacts). This repo declares *what runs where*: environment values,
ArgoCD Application manifests, and namespace policy for a DigitalOcean
Kubernetes (DOKS) cluster.

TEKO «Verteilte Systeme, Containerisierung» — Orchestrierung (the assignment
PDF is not part of the repository).

## How a change reaches the cluster

```
 CI repo (VSC-kubernetes-containers)                 Ops repo (this)
 ───────────────────────────────────                 ────────────────────────────
 push to master
   └─ build images ─ scan ─ publish to GHCR
   └─ publish generic-stack chart (OCI)
   └─ sign images + chart (cosign, keyless)
   └─ PROMOTE (planned) ── PR, auto-merge on ✓ ────► values-staging.yaml (tag bump)
                           PR, human-merged ───────► values-prod.yaml   (prod gate)
                                                              │ validate: lint, render,
                                                              │ kubeconform, signatures
                                                              ▼ pull (no push deploys!)
                                                     ArgoCD @ DOKS
                                                       ├─ ns argocd          ArgoCD (manages itself)
                                                       ├─ ns traefik         ingress controller (1 DO LB, TLS)
                                                       ├─ ns cert-manager    ACME certificates for the hosts
                                                       ├─ ns metrics-server  metrics API for the HPA
                                                       ├─ ns auth-staging    release "auth"
                                                       └─ ns auth-prod       release "auth"
```

Nothing in either repo runs `kubectl apply` or `helm upgrade` against the
cluster. GitHub workflows build, validate, and **commit**; ArgoCD pulls.
The only imperative step is the one-time bootstrap (`bootstrap/README.md`) -
automated by the `Doks` PowerShell module as
`New-DoksCluster | Bootstrap-DoksCluster` (see `Doks/README.md`).

## Layout

```
bootstrap/                  one-time cluster setup: ArgoCD install values,
                            secrets procedure (documented, never committed),
                            backup/restore and rotation runbooks
argocd/                     synced by the root app (sync-waves -3 … 0):
  root.yaml                 the app-of-apps itself (applied once at bootstrap)
  project-infra.yaml        AppProject for the platform: explicit chart repos,
                            namespaces and cluster-scoped kinds
  project.yaml              AppProject for the env apps: this repo only, two
                            namespaces, explicit list of namespaced kinds
  infra-traefik.yaml        Traefik ingress controller (official chart, MIT)
  infra-cert-manager.yaml   cert-manager (official chart, Apache-2.0)
  infra-cert-manager-issuer.yaml
                            charts/cert-manager-issuer, wave-ordered after
                            the cert-manager CRDs
  infra-metrics-server.yaml metrics-server (Kubernetes SIG, Apache-2.0)
  argocd.yaml               ArgoCD reconciling its own installation
  app-staging.yaml          charts/auth-stack + values-staging.yaml → auth-staging
  app-prod.yaml             charts/auth-stack + values-prod.yaml   → auth-prod
charts/cert-manager-issuer/ Let's Encrypt (staging) ClusterIssuer chart;
                            ACME endpoint, email and ingress class in values
charts/auth-stack/          wrapper chart:
  Chart.yaml                pins generic-stack (OCI dependency from GHCR)
  values.yaml               DO-common: storageClass, rolling-update policy,
                            resources, seed SQL, ingress + TLS + security
                            headers, backup, namespace policy defaults
  values-staging.yaml       env overlay — CI promotion target (image tags),
                            small HPA/PDB, hosts, quota
  values-prod.yaml          env overlay — promoted via PR; HPA 2–5, PDBs,
                            schema validation, hosts, quota
  values.schema.json        strict schema for the wrapper's own keys
  templates/                namespace + edge policy: ResourceQuota, LimitRange,
                            NetworkPolicies (default-deny in/out + explicit
                            flows), Traefik security-headers Middleware,
                            pg_dump CronJob + backup PVC
Doks/                       PowerShell module: create/connect/delete the
                            throwaway DOKS cluster and run the bootstrap
                            (New-DoksCluster | Bootstrap-DoksCluster);
                            see Doks/README.md
.github/workflows/
  validate.yml              PR/main gate: helm lint + template + kubeconform
                            for both env overlays, the issuer chart and the
                            ArgoCD manifests; every referenced image and the
                            chart dependency must exist in GHCR and carry a
                            cosign signature from the CI repo's workflow;
                            uploads the rendered env manifests (debug aid)
```

## Design decisions

* **Wrapper chart, not a fork.** `auth-stack` declares `generic-stack` as an
  OCI dependency (`helm dependency build` vendors it via `Chart.lock`). The
  CI repo owns application policy (probes, security posture, wiring, scaling
  mechanics); this repo owns environment policy (sizes, hosts, quotas,
  isolation, thresholds). Image tags are overridden per environment — that
  override is the promotion interface.
* **One ingress controller instead of per-env proxies.** The chart's in-stack
  Traefik `proxy` component is disabled; a cluster-wide Traefik
  (`argocd/infra-traefik.yaml`, 2 replicas, PDB, spread across nodes, TLS ≥ 1.2,
  dashboard off, JSON access logs) serves standard `Ingress` resources for
  all environments through a single DigitalOcean load balancer.
* **TLS via cert-manager + Let's Encrypt staging (HTTP-01).** Traefik
  redirects HTTP → HTTPS (Let's Encrypt follows the redirect when validating);
  the frontend Ingress carries the
  `cert-manager.io/cluster-issuer` annotation, a per-env `tls` secret and a
  security-headers Middleware (HSTS, nosniff, frame-deny, referrer policy).
  Staging CA on purpose (not browser-trusted): every throwaway cluster gets a
  new nip.io host, and nip.io is not on the Public Suffix List, so the
  production rate limit is shared with every nip.io user. cert-manager:
  Apache-2.0, CNCF; Let's Encrypt: ISRG (US non-profit) — accepted as
  passive self-hosted exceptions.
* **Secrets never touch git.** `db-password` and `jwt-secret` are created
  out-of-band per namespace from a manifest on stdin (never on a command
  line) and referenced via `existingSecret`; the database pod only receives
  the `db-password` key. Rotation runbook in `bootstrap/README.md`. Upgrade
  path if full GitOps for secrets is wanted later: Sealed Secrets
  (Apache-2.0).
* **Prod auto-syncs too.** The production gate is the promotion *pull
  request*, not a manual sync button — review happens in git, where it is
  auditable. Prod runs the backend with `ddl-auto: validate`: the seed SQL
  owns the schema, nothing changes it implicitly.
* **Supply chain is verified at the gate.** The CI repo publishes immutable
  version tags (a source change without a tag bump fails its build), signs
  every image and chart keylessly (cosign, GitHub OIDC, Rekor) and attaches
  SBOM attestations; `validate.yml` refuses any reference that does not
  exist or is not signed by that workflow. Actions are pinned to commit SHAs,
  downloaded tools are checksum-verified.
* **Scaling policy lives in `generic-stack`** (Aufgabe 6): `hpa:` / `pdb:`,
  explicit `RollingUpdate` with `maxUnavailable: 0`, `minReadySeconds`,
  hostname anti-affinity per component; this repo sets the thresholds in the
  overlays and `minReadySeconds`. metrics-server is deployed as an infra app
  because DOKS does not ship one. Traffic reaches only ready replicas: Traefik
  balances the Ingress round-robin over the frontend's ready endpoints, and the
  frontend reaches the autoscaled backend through its Service the same way.
* **Namespace policy is complete, not decorative.** ResourceQuota (CPU,
  memory, pods, storage, PVC count, no LoadBalancers/NodePorts), LimitRange,
  default-deny ingress **and** egress with explicit flows
  (edge → frontend → backend → db, DNS, ACME solver, metrics, backup job),
  Pod Security Admission `restricted` enforced on the namespace, and an
  AppProject that whitelists exactly the kinds the chart renders — no RBAC,
  no Secrets — so a values PR cannot escalate.
* **Backups are part of the deployment.** A `pg_dump` CronJob per environment
  (stack's own PostgreSQL image, same major version) writes to a dedicated
  PVC with retention; restore and volume-snapshot procedure in
  `bootstrap/README.md`. Postgres stays single-instance: HA would need an
  operator (Zalando postgres-operator, MIT, Zalando SE) and a larger cluster.
* **Blast radius.** The root app does not prune and carries no finalizer;
  infra apps carry no finalizer either — removing a manifest never cascades
  into deleting the load balancer or an environment; the backup PVCs are
  never pruned or cascade-deleted. ArgoCD is version-pinned
  and manages itself; the UI is port-forward only, every non-admin identity is
  read-only until an IdP is wired in.

## Environments

| | staging | prod |
|---|---|---|
| Namespace | `auth-staging` | `auth-prod` |
| Values | `values-staging.yaml` | `values-prod.yaml` |
| Promotion | PR by CI, auto-merged on green validate (planned) | PR by CI, human-merged (planned) |
| Backend | HPA 1–2 @ 70 % CPU, PDB `maxUnavailable: 1` | HPA 2–5 @ 70 % CPU (scale-down 1 pod / 60 s after 5 min), PDB `maxUnavailable: 1`, `ddl-auto: validate` |
| Frontend | 1 replica, PDB | 2 replicas, PDB `maxUnavailable: 1` |
| Rollouts | RollingUpdate `maxUnavailable: 0` / `maxSurge: 1`, `minReadySeconds: 5`, hostname anti-affinity | same |
| Quota (req / lim CPU) | 1 / 3 | 2 / 5 |
| Quota (req / lim memory) | 1Gi / 2Gi | 2Gi / 4Gi |
| Quota (storage / PVCs / pods) | 5Gi / 2 / 10 | 10Gi / 3 / 20 |
| Backups | daily, keep 3, 2Gi PVC | daily, keep 7, 5Gi PVC |
| Host | `auth-staging.<lb-ip>.nip.io` | `auth-prod.<lb-ip>.nip.io` |
| TLS secret | `auth-staging-tls` | `auth-prod-tls` (both Let's Encrypt staging) |
| Isolation | default-deny in/out, explicit flows, PSA restricted | same |

## Promotion contract (CI-repo side) — planned

The CI repo's `build.yml` does **not** yet contain the `promote` job; until
it does, image tags in the overlays are bumped by hand via PR. The intended
contract:

1. Secret `OPS_REPO_TOKEN`: fine-grained PAT, Contents + Pull requests
   read/write, scoped to **this repo only**.
2. After images + chart are published and signed: bump
   `components.<name>.image.tag` in `charts/auth-stack/values-staging.yaml`
   on branch `promote/staging`, open a PR, enable auto-merge — it merges
   itself once the `validate` checks pass.
3. Open/refresh a PR applying the same bump to `values-prod.yaml`
   (`promote/prod`) — merged by a human.

`main` is enforced by the `main-protection` ruleset: changes only via PR,
and only with green `chart (staging)`, `chart (prod)`, and
`argocd-manifests` checks — an invalid or unsigned configuration cannot reach
the branch ArgoCD watches. ArgoCD detects the merge and converges the matching
namespace. No cluster credentials ever exist in GitHub.

## Working locally

```sh
helm dependency build charts/auth-stack
helm lint charts/auth-stack -f charts/auth-stack/values.yaml \
  -f charts/auth-stack/values-staging.yaml --strict
helm template auth charts/auth-stack --namespace auth-staging \
  -f charts/auth-stack/values.yaml -f charts/auth-stack/values-staging.yaml
helm lint charts/cert-manager-issuer --strict
```

Same steps run in CI (`validate.yml`) for both environments, plus
`kubeconform` against the cluster's Kubernetes version and cosign
verification of every referenced artifact.

## Task mapping (grading)

| Aufgabe | Where |
|---|---|
| 1 Manifests | `helm template` output of `generic-stack` (Service, Deployment/StatefulSet, ConfigMap, PVC, Ingress per component; the Secret is created out-of-band by design — manifest in `bootstrap/README.md` step 2, the chart renders one from an inline `secret:` map); the stack was built chart-first, the rendered manifests are the `validate.yml` artifacts (90 days) |
| 2 Helm chart | `generic-stack` in the CI repo (schema-validated, helpers, no hardcoding); consumed here as OCI dependency |
| 3 ArgoCD | `bootstrap/`, `argocd/` — dedicated `argocd` ns, apps deploy to separate namespaces, dashboard via port-forward |
| 4 Pipeline | CI repo `build.yml`: build/scan/sign/publish on push, immutable version tag + unique `tree-<git tree hash>` tag per source state, registry login via `GITHUB_TOKEN`, no imperative deploy, no cluster credentials; `validate.yml` here is deploy-free; promotion job planned |
| 5 Namespaces | `values-*.yaml` overlays, `templates/resourcequota.yaml`, `limitrange.yaml`, `networkpolicy.yaml`, PSA labels in `argocd/app-*.yaml` |
| 6 Scaling | HPA/PDB/RollingUpdate/anti-affinity via `generic-stack`, thresholds in the overlays; liveness/readiness/startup probes on every component; Traefik round-robins the Ingress over ready endpoints only; TLS via cert-manager; metrics-server infra app |
