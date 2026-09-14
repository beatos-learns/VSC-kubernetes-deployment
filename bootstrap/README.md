# Bootstrap (one-time, imperative)

Everything here is applied **once** per cluster, by hand — or by
`Bootstrap-DoksCluster` from the `Doks` module, which runs exactly these steps.
After step 4 the cluster converges on git: no further `kubectl apply` or
`helm install` against the apps, ever (Aufgabe 4).

Prerequisites: `doctl`, `kubectl`, `helm`, `terraform` (the managed database
and its credentials come from `terraform/`, step 2). Cluster sizing: 2 × `s-2vcpu-4gb`
(autoscale 2–5) — see `Doks/Doks.defaults.psd1`; the quotas, anti-affinity and
PDBs assume at least two nodes.

## 1. Cluster access

```sh
doctl auth init
doctl kubernetes cluster kubeconfig save <cluster-name>
kubectl get nodes
```

## 2. Namespaces and secrets (out-of-band, never in git)

Each environment namespace needs one pre-created Secret
(`existingSecret: auth-stack-secrets`): the managed database's endpoint and
login role for the backend (`db-url`, `db-user`, `db-password`), the seed
Job's connection data and admin credentials (`db-host`, `db-port`, `db-name`,
`db-admin-user`, `db-admin-password`) and a random `jwt-secret`. The database
values are Terraform outputs (`terraform/README.md`, `terraform apply` first).
Create the Secret from a manifest on stdin — never with `--from-literal` — so
the values stay out of shell history and process listings:

```sh
db=$(terraform -chdir=terraform output -json database)
creds=$(terraform -chdir=terraform output -json database_credentials)
for ns in auth-staging auth-prod; do
  env=${ns#auth-}
  kubectl create namespace "$ns" 2>/dev/null || true
  kubectl -n "$ns" get secret auth-stack-secrets >/dev/null 2>&1 && continue
  host=$(jq -r .host <<<"$db"); port=$(jq -r .port <<<"$db"); name=$(jq -r ".databases.$env" <<<"$db")
  kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-stack-secrets
  namespace: $ns
type: Opaque
stringData:
  db-host: "$host"
  db-port: "$port"
  db-name: "$name"
  db-url: "jdbc:postgresql://$host:$port/$name?sslmode=require"
  db-user: "$(jq -r ".environments.$env.user" <<<"$creds")"
  db-password: "$(jq -r ".environments.$env.password" <<<"$creds")"
  db-admin-user: "$(jq -r .admin.user <<<"$creds")"
  db-admin-password: "$(jq -r .admin.password <<<"$creds")"
  jwt-secret: "$(openssl rand -base64 48)"
EOF
done
```

The monitoring stack expects two more Secrets in its own namespace: Grafana's
admin credentials and the Alertmanager notification channel. Alertmanager
reads the webhook URL from the mounted file (`url_file`), so the channel never
appears in git or in a Helm value:

```sh
kubectl create namespace monitoring 2>/dev/null || true

kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1 || kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: "$(openssl rand -base64 24)"
EOF

kubectl -n monitoring get secret alertmanager-webhook >/dev/null 2>&1 || kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-webhook
  namespace: monitoring
type: Opaque
stringData:
  webhook-url: "https://<incoming-webhook-url>"
EOF
```

Any endpoint that accepts Alertmanager's JSON payload is a valid channel: a
chat bridge, an automation platform, or a `https://webhook.site/<id>` inbox
for a demonstration. Alertmanager reads the file per notification, so
replacing the Secret is enough — the kubelet refreshes the mount within about
a minute (`kubectl -n monitoring rollout restart statefulset/alertmanager-monitoring-kube-prometheus`
forces it). Without the Secret the Alertmanager pod does not start: the
notification channel is part of the deployment, not an afterthought.

The GHCR packages are public; no pull secret is needed. (For private packages:
`kubectl -n <ns> create secret docker-registry ghcr-pull ...` with a
`read:packages` fine-grained PAT, and set `global.imagePullSecrets` in
`charts/auth-stack/values.yaml`.)

> The admin credentials are read only by the seed Job (an ArgoCD PreSync
> hook); the backend pods never see them.

## 3. Install ArgoCD (dedicated namespace, Aufgabe 3)

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd --version 10.4.0 \
  --namespace argocd --create-namespace \
  --values argocd-values.yaml
```

Pinned version — `argocd/argocd.yaml` is the source of truth (the Doks module
reads it from there). After step 4 ArgoCD reconciles its own installation:
later changes to `argocd-values.yaml` go in via PR, and a re-run of the
bootstrap skips this step.

## 4. Point ArgoCD at this repo

```sh
kubectl apply -f ../argocd/root.yaml
kubectl -n argocd get applications -w
```

The root app syncs `argocd/`: the two AppProjects, the Prometheus Operator
CRDs, Traefik, cert-manager and its ClusterIssuer, metrics-server (DOKS does
not ship one; the HPA needs it), the monitoring stack, ArgoCD itself, and the
two environment Applications (sync-waves −4 … 0). `kubectl top nodes` works
once metrics-server is up.

`argocd/` is a kustomize directory (`argocd/kustomization.yaml`), which is how
the shared sync policy stays in one file. `root.yaml` is deliberately kept
complete and outside that patch, so the single-file apply above still works on
an empty cluster — do not replace it with `kubectl apply -k ../argocd`, which
would apply the whole directory by hand instead of letting root adopt it.

## 5. Dashboard access and admin password

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:80
# → http://localhost:8080  (user: admin)
```

The UI is reachable only through the port-forward (no public endpoint). Rotate
the generated password once and delete the bootstrap secret:

```sh
argocd login localhost:8080 --plaintext --username admin
argocd account update-password
kubectl -n argocd delete secret argocd-initial-admin-secret
```

Everyone except `admin` is read-only (`policy.default: role:readonly`);
wire an identity provider (Dex/OIDC) before handing out further accounts.

## 6. DNS / ingress hosts

```sh
kubectl -n traefik get svc infra-traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Point DNS records at that IP — or use nip.io hosts (e.g.
`auth-staging.203-0-113-10.nip.io`) — and set the `ingress.hosts` **and**
`ingress.tls[].hosts` values in `charts/auth-stack/values-staging.yaml` /
`values-prod.yaml` via a pull request (`main` only accepts PRs with green
validate checks). ArgoCD picks it up after the merge.

## 7. TLS (automatic)

cert-manager requests a Let's Encrypt **staging** certificate (not
browser-trusted — expect a warning) for each Ingress via HTTP-01 and stores
it in the environment's `tls.secretName`:

```sh
kubectl -n auth-staging get certificate,challenge
```

## 8. Backups and restore

Backups are the provider's: the managed cluster takes daily backups (7 days
retained) and supports point-in-time recovery. A restore creates a *new*
database cluster from a backup or a timestamp:

```sh
doctl databases backups list <cluster-id>            # id: terraform -chdir=terraform output
doctl databases create auth-restore --engine pg --version 16 --region fra1 --size db-s-1vcpu-1gb \n  --restore-from-cluster-name k8s-test-fra1-pg --restore-from-timestamp <RFC3339>
```

Pointing an environment at the restored cluster is a change of its Secret's
`db-*` keys followed by `rollout restart deployment/auth-backend` — or,
declaratively, adopting the restored cluster in `terraform/database.tf`.

## 9. Schema changes

The seed SQL in `charts/auth-stack/values.yaml` (`dbSeed.files`) is applied
before every sync by the PreSync hook and is idempotent; the backend runs
with `ddl-auto: validate` in every environment and refuses to start on
drift. A new backend build that changes entities therefore ships with the
matching idempotent `ALTER` / `CREATE ... IF NOT EXISTS` statements in that
file — the overlays' tag bump and the migration belong in the same PR, and
the hook applies them before the new pods start. The last run's log:
`kubectl -n <ns> logs job/auth-db-seed`.

## 10. Monitoring

`infra-monitoring` installs kube-prometheus-stack from `charts/monitoring`
into the `monitoring` namespace (its CRDs come first, from
`infra-monitoring-crds`); `charts/monitoring/values.yaml` is its entire
configuration. Like ArgoCD, the three UIs are port-forward only:

```sh
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093
```

Grafana takes the credentials from the `grafana-admin` Secret (step 2); the
dashboards of this repo live in the **auth-stack** folder (user-mgmt-service,
Kubernetes resources, k6 load test) and the **platform** folder (cluster
capacity, edge: Traefik + cert-manager, ArgoCD), next to the bundled
kube-prometheus set. That the application is really scraped is visible in
Prometheus → Status → Target health (`serviceMonitor/auth-staging/…`,
`podMonitor/auth-staging/…` and the `auth-prod` counterparts must be *up*;
the platform jobs `traefik`, `cert-manager`, `cainjector`, `webhook` and
`argocd-*-metrics` next to them) and here:

```sh
kubectl -n auth-prod get servicemonitor,prometheusrule
kubectl -n monitoring logs sts/prometheus-monitoring-kube-prometheus -c prometheus | tail
```

Two ways to prove the alert path end to end:

```sh
# 1. routing + channel only: hand Alertmanager a synthetic alert
curl -sS -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels": {"alertname":"UserMgmtServiceHighErrorRate","service":"user-mgmt-service",
             "severity":"critical","namespace":"auth-staging"},
  "annotations": {"summary":"notification channel test"}}]'

# 2. the real rule: wrong-password logins above the staging threshold (1/s)
#    for ten minutes make UserMgmtServiceLoginFailures fire
while true; do
  curl -sk -o /dev/null -X POST "https://auth-staging.<lb-ip>.nip.io/api/login" \
    -H 'Content-Type: application/json' \
    -d '{"email":"nobody@example.com","password":"wrong"}'
done
```

The alert appears in Prometheus → Alerts (pending → firing), then in
Alertmanager, and is delivered to the webhook from step 2. Thresholds are
environment policy: `monitoring.alerts.*` in the overlays. The platform's own
rules (OOM kills, unschedulable pods, Traefik, certificates, ArgoCD) are the
`monitoring-kube-prometheus-platform` PrometheusRule from `charts/monitoring/values.yaml`
and take the same route.

When something "is low on resources", open **Platform - cluster capacity**
first: a 4 GB DOKS node leaves about 2.9 GiB to pods, and the dashboard shows per
node what is allocatable, requested and used, which containers exceed their
request or are throttled, and OOM kills. A pod that stays Pending is the
autoscaler's cue (`min_nodes`/`max_nodes` in `terraform/`).

## Rotation

| Secret | Procedure |
|---|---|
| `jwt-secret` | update the key in `auth-stack-secrets`, then `kubectl -n <ns> rollout restart deployment/auth-backend` — all sessions are invalidated |
| `db-password` | reset the role on the managed cluster (`doctl databases user reset <cluster-id> auth_<env>`), copy the new value into the Secret, then `rollout restart deployment/auth-backend`; `terraform apply` afterwards refreshes the value in state |
| `db-admin-password` | `doctl databases user reset <cluster-id> doadmin`, update the key in every environment's Secret; the next sync's seed Job uses it |
| ArgoCD admin | `argocd account update-password` (step 5) |
| `grafana-admin` | update the key, then `kubectl -n monitoring rollout restart deployment/monitoring-grafana` |
| `alertmanager-webhook` | update the key; the file is re-read per notification (step 10) |

`existingSecret` material is outside the chart's checksum: without the
`rollout restart` the pods keep the old value.
