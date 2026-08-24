# Bootstrap (one-time, imperative)

Everything here is applied **once** per cluster, by hand — or by
`Bootstrap-DoksCluster` from the `Doks` module, which runs exactly these steps.
After step 4 the cluster converges on git: no further `kubectl apply` or
`helm install` against the apps, ever (Aufgabe 4).

Prerequisites: `doctl`, `kubectl`, `helm`. Cluster sizing: 2 × `s-2vcpu-4gb`
(autoscale 2–5) — see `Doks/Doks.defaults.psd1`; the quotas, anti-affinity and
PDBs assume at least two nodes.

## 1. Cluster access

```sh
doctl auth init
doctl kubernetes cluster kubeconfig save <cluster-name>
kubectl get nodes
```

## 2. Namespaces and secrets (out-of-band, never in git)

The chart contract expects one pre-created Secret per namespace
(`existingSecret: auth-stack-secrets`, keys `db-password` and `jwt-secret`).
Create it from a manifest on stdin — never with `--from-literal` — so the
values stay out of shell history and process listings:

```sh
for ns in auth-staging auth-prod; do
  kubectl create namespace "$ns" 2>/dev/null || true
  kubectl -n "$ns" get secret auth-stack-secrets >/dev/null 2>&1 && continue
  kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: auth-stack-secrets
  namespace: $ns
type: Opaque
stringData:
  db-password: "$(openssl rand -base64 24)"
  jwt-secret: "$(openssl rand -base64 48)"
EOF
done
```

The GHCR packages are public; no pull secret is needed. (For private packages:
`kubectl -n <ns> create secret docker-registry ghcr-pull ...` with a
`read:packages` fine-grained PAT, and set `global.imagePullSecrets` in
`charts/auth-stack/values.yaml`.)

> The DB password is generated independently per environment and is baked
> into the PostgreSQL volume on first start — see *Rotation* below.

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

The root app syncs `argocd/`: the two AppProjects, Traefik, cert-manager and
its ClusterIssuer, metrics-server (DOKS does not ship one; the HPA needs it),
ArgoCD itself, and the two environment Applications (sync-waves −3 … 0).
`kubectl top nodes` works once metrics-server is up.

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

A CronJob per environment (`dbBackup` in the values) writes `pg_dump`
archives to the `auth-db-backup` PVC (never pruned or cascade-deleted) and
keeps the newest N:

```sh
kubectl -n auth-prod get cronjob auth-db-backup                 # schedule / last run
kubectl -n auth-prod create job --from=cronjob/auth-db-backup backup-now
kubectl -n auth-prod get jobs -l app.kubernetes.io/name=db-backup
```

Restore (everything through git — no imperative step):

1. Scale the backend down: set `backend.hpa.enabled: false` and
   `backend.replicas: 0` in the environment overlay, merge, wait for the sync.
2. Set `dbBackup.restore.file: app-<timestamp>.dump` (list the PVC with a
   `backup-now` job's log), merge → a one-off `auth-db-restore-*` Job runs
   `pg_restore --clean --if-exists` against the database.
3. Revert both changes, merge; the backend comes back on the restored data.

Volumes are DigitalOcean block storage; take a volume snapshot before risky
changes (`doctl compute volume-action snapshot`).

## 9. Schema changes

The seed SQL in `charts/auth-stack/values.yaml` creates the schema once per
fresh volume; the backend runs with `ddl-auto: validate` in every environment
and refuses to start on drift. A new backend build that changes entities
therefore needs a migration on existing volumes (a one-off Job with `psql`
like the restore Job) **and** the seed SQL updated for fresh ones — the
overlays' tag bump and the migration belong in the same PR.

Existing clusters, once: the backend Deployment was applied with a static
`replicas` before the HPA took over. Strip it from the last-applied state so
the first HPA-managed sync does not scale to 1 in between:
`kubectl -n <ns> apply edit-last-applied deployment/auth-backend` (delete
`spec.replicas`).

## Rotation

| Secret | Procedure |
|---|---|
| `jwt-secret` | update the key in `auth-stack-secrets`, then `kubectl -n <ns> rollout restart deployment/auth-backend` — all sessions are invalidated |
| `db-password` | `ALTER ROLE app PASSWORD '<new>'` inside `auth-db-0`, update the key in the Secret, then `rollout restart deployment/auth-backend`; the Secret alone does **not** change the database password |
| ArgoCD admin | `argocd account update-password` (step 5) |

`existingSecret` material is outside the chart's checksum: without the
`rollout restart` the pods keep the old value.
