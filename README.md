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
   └─ promote ──────────── PR, auto-merge on ✓ ────► values-staging.yaml (tag bump)
                           PR, human-merged ───────► values-prod.yaml   (prod gate)
                                                              │ validate: lint, render,
                                                              │ kubeconform, signatures
                                                              ▼ pull (no push deploys!)
                                                     ArgoCD @ DOKS
                                                       ├─ ns argocd          ArgoCD (manages itself)
                                                       ├─ ns traefik         ingress controller (1 DO LB, TLS)
                                                       ├─ ns cert-manager    ACME certificates for the hosts
                                                       ├─ ns metrics-server  metrics API for the HPA
                                                       ├─ ns monitoring      Prometheus, Grafana, Alertmanager
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
  kustomization.yaml        what the root app renders; every file below must
                            be listed here or it is not deployed
  sync-defaults.patch       destination.server + syncPolicy shared by every
                            Application that carries a sync-wave
  root.yaml                 the app-of-apps itself (applied once at bootstrap;
                            no sync-wave, so the patch skips it and the file
                            stays complete for `kubectl apply -f`)
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
  infra-monitoring.yaml     charts/monitoring (kube-prometheus-stack)
  argocd.yaml               ArgoCD reconciling its own installation
  app-staging.yaml          charts/auth-stack + values-staging.yaml → auth-staging
  app-prod.yaml             charts/auth-stack + values-prod.yaml   → auth-prod
charts/cert-manager-issuer/ Let's Encrypt (staging) ClusterIssuer chart;
                            ACME endpoint, email and ingress class in values
charts/monitoring/          wrapper chart:
  Chart.yaml                pins kube-prometheus-stack (prometheus-community)
  values.yaml               the monitoring stack's own configuration: scrape
                            targets, retention + storage, Alertmanager routing
                            and receiver, Grafana provisioning
  files/dashboards/         the three dashboards of this repo (as code):
                            user-mgmt-service, auth-stack/Kubernetes, k6 load test
  templates/dashboards.yaml renders them into sidecar-labelled ConfigMaps
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
                            pg_dump CronJob + backup PVC, ServiceMonitor +
                            PrometheusRule for the backend
Doks/                       PowerShell module: create/connect/delete the
                            throwaway DOKS cluster and run the bootstrap
                            (New-DoksCluster | Bootstrap-DoksCluster);
                            see Doks/README.md
terraform/                  the DOKS cluster as code (Aufgabe 3): DigitalOcean
                            provider, import block for the existing cluster,
                            the generated-then-cleaned resource, variables;
                            token via environment only; see terraform/README.md
loadtest/                   k6 load test as a Kubernetes Job (Aufgabe 2):
                            namespace + policy, script ConfigMap, Job; applied
                            per run, results in Prometheus/Grafana; see
                            loadtest/README.md
.github/workflows/
  validate.yml              PR/main gate: helm lint + template + kubeconform
                            for both env overlays, the issuer chart, the
                            monitoring chart and the ArgoCD manifests; builds
                            argocd/ with kustomize and asserts the Application
                            invariants on the result (see Design decisions);
                            every referenced image and the chart dependency
                            must exist in GHCR and carry a cosign signature
                            from the CI repo's workflow; uploads the rendered
                            env manifests (debug aid); builds loadtest/ with
                            kustomize and kubeconform-checks it; runs
                            terraform fmt/init/validate (no credentials)
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
* **`argocd/` is a kustomize overlay; the charts stay Helm.** Helm packages
  *applications* — templated, versioned, pulled from OCI, schema-validated,
  signed. `argocd/` is not an application: it is a set of literal objects
  sharing one policy, so it uses kustomize instead of being templated.
  `kustomization.yaml` is the deploy list — the root app's `path: argocd` has
  no `directory:` filter, so under a plain directory source *any* file left in
  that folder would ship; now nothing deploys until it is listed, and
  `validate.yml` fails if the list and the folder disagree.
  `sync-defaults.patch` holds `destination.server` and the shared `syncPolicy`
  once instead of nine times. It OVERRIDES rather than backfills, so CI rejects
  any manifest that redeclares a field it owns, and rejects a list inside it
  (kustomize replaces lists on this CRD, which would wipe each app's own
  `syncOptions`). An Application diverges deliberately by carrying
  `sync-defaults.vsc/opt-out: "true"` and restating what it needs.
  `root.yaml` is excluded — no sync-wave, so the patch skips it and it stays a
  complete manifest that `kubectl apply -f` can bootstrap on an empty cluster.
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
* **Observability is one stack for everything** (Aufgabe 7).
  `charts/monitoring` wraps kube-prometheus-stack the same way `auth-stack`
  wraps `generic-stack`; its `values.yaml` is the whole configuration — scrape
  targets, retention, Alertmanager routing, Grafana provisioning — and the two
  dashboards are JSON files rendered into sidecar-labelled ConfigMaps, so
  Grafana needs no PVC and a UI edit never becomes state. DOKS specifics are
  part of it: the managed control plane and Cilium mean kube-scheduler,
  controller-manager, etcd and kube-proxy are switched off instead of failing
  forever. The environments carry their own `ServiceMonitor` and
  `PrometheusRule` (thresholds per overlay), Prometheus discovers them only in
  the namespaces this platform owns, and the alert route matches the
  `service: user-mgmt-service` label, so the application's alerts reach the
  configured webhook receiver. The webhook URL is a Secret read through
  `url_file` — the notification channel follows the same "secrets never touch
  git" rule as everything else.
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
* **Load tests run in the cluster, but through the front door** (Aufgabe 2).
  `loadtest/` is a kustomize directory applied per run - a load test is an
  experiment, not a desired state, so it is deliberately not an ArgoCD
  Application (it is still built and kubeconform-checked by `validate.yml`).
  k6 runs as a restricted, default-deny Job and targets the environment's
  public host, so the load balancer, Traefik, the frontend's `/api` proxy and
  the Service round-robin over the backend replicas are all under test. Its
  metrics go into the one Prometheus via remote write (receiver enabled in
  `charts/monitoring/values.yaml`) and a third dashboard puts them next to
  the server-side view and the HPA; the test account is a Secret created
  out-of-band, like every other secret. k6: AGPL-3.0, Grafana Labs.
* **The cluster is adopted by Terraform, not recreated** (Aufgabe 3).
  `terraform/` imports the DOKS cluster the Doks module created (import
  block, `-generate-config-out`, then cleaned: the mutually exclusive GPU
  plugin blocks, null attributes and account-specific network ids are gone,
  the autoscaler-owned node count is ignored, every literal is a variable).
  `plan` on `main` is empty for the running cluster; a version or pool change
  is a reviewed diff. The API token stays an environment variable, state
  stays local until a second operator needs it, and the load balancer and
  volumes stay with Kubernetes - one owner per object.

## Environments

| | staging | prod |
|---|---|---|
| Namespace | `auth-staging` | `auth-prod` |
| Values | `values-staging.yaml` | `values-prod.yaml` |
| Promotion | PR by CI (`promote/staging`), auto-merged on green validate | PR by CI (`promote/prod`), human-merged |
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
| Alert thresholds | 5xx > 10 %, p95 > 2 s, rejected logins > 1/s | 5xx > 2 %, p95 > 0.8 s, rejected logins > 0.2/s |

## Promotion contract (CI-repo side)

The CI repo's `build.yml` ends with a `promote` job. It runs only on the CI
default branch, after every image and the chart are published **and signed**:

1. Checks this repo out with the CI repo's `OPS_REPO_TOKEN` secret — a
   fine-grained PAT scoped to **this repo only**, Contents + Pull requests
   read/write. That PAT is the only cross-repo credential; no cluster
   credentials exist in GitHub.
2. Sets `components.<name>.image.tag` in both overlays to what the CI tree
   builds — only for the components the overlays manage (`db`, `backend`,
   `frontend`; the anchored `# promoted …` lines are edited in place) — and,
   when the CI repo published a new `generic-stack` version, pins it in
   `Chart.yaml` and refreshes `Chart.lock`.
3. Branch `promote/staging` (`values-staging.yaml` + chart pin): one commit
   on top of `main`, force-pushed, PR opened or refreshed, auto-merge armed —
   it merges itself once the `validate` checks are green; a red gate leaves
   it open for inspection.
4. Branch `promote/prod` (`values-prod.yaml` only): same, without auto-merge
   — a human merges it after verifying the tags on staging.

Identical content is never pushed twice, so a CI run that changed nothing
causes no PR churn. The chart pin is shared by both environments (one
wrapper chart), so a new chart *version* reaches prod with the staging PR —
`validate` renders and checks both overlays against it first; image tags
stay behind the prod gate.

`main` is enforced by the `main-protection` ruleset: changes only via PR,
and only with green `chart (staging)`, `chart (prod)`, and
`argocd-manifests` checks — an invalid or unsigned configuration cannot reach
the branch ArgoCD watches. The flow also relies on three repository settings
(GitHub, not in git): *Allow auto-merge* and *Automatically delete head
branches* enabled, and no required reviewers on the ruleset (otherwise the
staging PR waits for a human, which is the prod flow). ArgoCD detects the
merge and converges the matching namespace.

## Working locally

```sh
helm dependency build charts/auth-stack
helm lint charts/auth-stack -f charts/auth-stack/values.yaml \
  -f charts/auth-stack/values-staging.yaml --strict
helm template auth charts/auth-stack --namespace auth-staging \
  -f charts/auth-stack/values.yaml -f charts/auth-stack/values-staging.yaml
helm lint charts/cert-manager-issuer --strict

helm dependency build charts/monitoring
helm lint charts/monitoring --strict
helm template monitoring charts/monitoring --namespace monitoring --include-crds

kustomize build argocd/            # what the root app actually applies
```

Same steps run in CI (`validate.yml`) for both environments, plus
`kubeconform` against the cluster's Kubernetes version and cosign
verification of every referenced artifact.

`validate.yml` gates `argocd/` with plain `kustomize`/`yq`/`jq`, so a red run
reproduces locally by copying the step body out of the workflow. Note that
`kubeconform` runs against both `argocd/` and the kustomize output: the
directory reports a schema error against the file it lives in, the rendered
output is what ArgoCD applies and the only place `sync-defaults.patch` is
visible merged.

## Task mapping (grading)

| Aufgabe | Where |
|---|---|
| 1 Manifests | `helm template` output of `generic-stack` (Service, Deployment/StatefulSet, ConfigMap, PVC, Ingress per component; the Secret is created out-of-band by design — manifest in `bootstrap/README.md` step 2, the chart renders one from an inline `secret:` map); the stack was built chart-first, the rendered manifests are the `validate.yml` artifacts (90 days) |
| 2 Helm chart | `generic-stack` in the CI repo (schema-validated, helpers, no hardcoding); consumed here as OCI dependency |
| 3 ArgoCD | `bootstrap/`, `argocd/` — dedicated `argocd` ns, apps deploy to separate namespaces, dashboard via port-forward; the app-of-apps renders `argocd/` as a kustomize overlay (`kustomization.yaml` is the deploy list, `sync-defaults.patch` the shared sync policy) and `validate.yml` asserts the Application invariants on the build output |
| 4 Pipeline | CI repo `build.yml`: build/scan/sign/publish on push, immutable version tag + unique `tree-<git tree hash>` tag per source state, registry login via `GITHUB_TOKEN`, no imperative deploy, no cluster credentials; `validate.yml` here is deploy-free; the CI `promote` job commits tag bumps here as PRs (staging auto-merged on green checks, prod human-merged) |
| 5 Namespaces | `values-*.yaml` overlays, `templates/resourcequota.yaml`, `limitrange.yaml`, `networkpolicy.yaml`, PSA labels in `argocd/app-*.yaml` |
| 6 Scaling | HPA/PDB/RollingUpdate/anti-affinity via `generic-stack`, thresholds in the overlays; liveness/readiness/startup probes on every component; Traefik round-robins the Ingress over ready endpoints only; TLS via cert-manager; metrics-server infra app |
| 7 Monitoring | kube-prometheus-stack in ns `monitoring` via `argocd/infra-monitoring.yaml` + `charts/monitoring` (its `values.yaml` is the whole configuration); per-pod CPU/memory from the kubelet + kube-state-metrics; `charts/auth-stack/templates/servicemonitor.yaml` scrapes the backend's admin port (request rate, response time, error rate); `prometheusrule.yaml` defines the alerts and the Alertmanager route in `charts/monitoring/values.yaml` forwards them to the webhook receiver; two dashboards in `charts/monitoring/files/dashboards/`; verification steps in `bootstrap/README.md` step 10 |

## Task mapping (Tooling block, VSC_Observability)

| Aufgabe | Where |
|---|---|
| 1 Observability | see "7 Monitoring" above: kube-prometheus-stack in ns `monitoring`, per-pod CPU/memory, backend ServiceMonitor (request rate, response time, error rate), two dashboards, PrometheusRule + Alertmanager webhook, all in `charts/monitoring/values.yaml` |
| 2 Chaos Testing | `loadtest/`: k6 as a Kubernetes Job with `scripts/user-mgmt-service.js` (ramping load on `/api/login` + `/api/me`); k6 metrics via remote write into Prometheus, dashboard `k6 load test` (VUs/RPS/p95 next to server-side rate/latency, HPA desired vs. current, CPU vs. target, requests per backend pod); HPA scale-up/down and availability procedure in `loadtest/README.md` |
| 3 Terraform IaC | `terraform/`: DigitalOcean provider, `imports.tf` import block, `generated.tf` from `terraform plan -generate-config-out` (cleaned, header lists the edits), `variables.tf`, token via `DIGITALOCEAN_TOKEN` only, `terraform fmt`/`validate` in `validate.yml`, `plan` empty for the running cluster (`terraform/README.md`) |
