# Bootstrap (one-time, imperative)

Everything in this directory is applied **once** per cluster, by hand.
After step 5 the cluster converges on git — no further `kubectl apply`
or `helm install` against the apps, ever (Aufgabe 4).

Prerequisites: `doctl`, `kubectl`, `helm`.

## 1. Cluster access

```sh
doctl auth init
doctl kubernetes cluster kubeconfig save <cluster-name>
kubectl get nodes
```

## 2. Namespaces and secrets (out-of-band, never in git)

The generic-stack chart contract expects a pre-created Secret per namespace
(referenced as `existingSecret: auth-stack-secrets` in the values) plus a
GHCR pull secret (referenced via `global.imagePullSecrets`).

```sh
for ns in auth-staging auth-prod; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$ns" create secret generic auth-stack-secrets \
    --from-literal=db-password="$(openssl rand -base64 24)" \
    --from-literal=jwt-secret="$(openssl rand -base64 48)"

  # PAT with read:packages only. Skip if the GHCR packages are public
  # (then also remove global.imagePullSecrets from charts/auth-stack/values.yaml).
  kubectl -n "$ns" create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io \
    --docker-username=<github-username> \
    --docker-password=<read-packages-PAT>
done
```

> The DB password is generated independently per environment. Losing it means
> recreating the secret **and** the PVC (PostgreSQL initializes it on first start).

## 3. Install ArgoCD (dedicated namespace, Aufgabe 3)

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --values argocd-values.yaml
```

(`upgrade --install` so that later changes to `argocd-values.yaml` — e.g.
the Application health check that makes sync waves work — apply in place.)

## 4. Point ArgoCD at this repo

```sh
kubectl apply -f root-application.yaml
```

The root app syncs `argocd/`: AppProject, Traefik ingress controller,
cert-manager plus its ClusterIssuers, and the two environment Applications. Watch it converge:

```sh
kubectl -n argocd get applications -w
```

If the GHCR **chart** package is private, ArgoCD's repo-server cannot pull the
`generic-stack` OCI dependency — either make the package public or register
`ghcr.io/beatos-learns/vsc-kubernetes-containers/charts` as a Helm OCI
repository credential in ArgoCD before this step.

## 5. Dashboard access

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:80
# → http://localhost:8080  (user: admin)
```

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

Nothing to apply: once the hosts are merged, cert-manager requests a
Let's Encrypt certificate for each Ingress through Traefik (HTTP-01) and
stores it in the `tls.secretName` of the environment. Watch it:

```sh
kubectl -n auth-staging get certificate,challenge
```

`READY=True` within a minute or two is normal. A pending challenge with
"too many certificates already issued" is the shared nip.io rate limit —
see `cert-manager-issuer/cluster-issuer.yaml` for the staging-issuer
fallback.
