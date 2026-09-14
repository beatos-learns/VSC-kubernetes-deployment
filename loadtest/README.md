# Load test (Aufgabe 2, Chaos Testing)

k6 runs **inside the cluster** as a Kubernetes Job and puts controlled,
rising load on the user-mgmt-service through its public path (load balancer
→ Traefik → frontend `/api` proxy → backend replicas). The run is observed
from two sides: k6 pushes its client-side metrics into the cluster Prometheus
(remote write), and the backend's own metrics plus kube-state-metrics show
what the service and the HPA did meanwhile. The **k6 load test** dashboard in
Grafana puts both next to each other.

```
loadtest/
  kustomization.yaml            namespace + policy + script ConfigMap + Job
  namespace.yaml                ns loadtest, Pod Security `restricted`
  networkpolicy.yaml            default-deny; egress DNS, HTTPS out, Traefik, Prometheus
  job.yaml                      the k6 run (image pinned by digest, env = knobs)
  scripts/user-mgmt-service.js  the test: signup once, then login + /api/me per iteration
```

Not an ArgoCD Application on purpose: a load test is an experiment you start
and stop, not a desired state. Everything else about it is still declarative
and validated by `validate.yml` (kustomize build + kubeconform).

## 1. One-time: the test account

The script logs in with one account, created through `/api/signup` on first
use. Its credentials are a Secret, created out-of-band like every other
secret in this repo (never on a command line, never in git):

```sh
kubectl create namespace loadtest 2>/dev/null || true
kubectl -n loadtest get secret k6-test-user >/dev/null 2>&1 || kubectl create -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: k6-test-user
  namespace: loadtest
type: Opaque
stringData:
  email: k6-loadtest@example.com
  password: "$(openssl rand -base64 24)"
EOF
```

> **Fresh database?** The seed SQL makes the *first* registered user ADMIN
> (`charts/auth-stack/values.yaml`). Register the intended admin through the
> UI before the first load test, or the k6 account inherits the role.

## 2. Run

`job.yaml` carries the knobs as environment variables: `TARGET_URL` (the
environment's ingress host from `charts/auth-stack/values-*.yaml`) and
`PEAK_VUS` (virtual users at the plateau, default 5 - see "Findings" below
for why). Change them in the
file or on the fly:

```sh
kubectl apply -k loadtest/
kubectl -n loadtest logs -f job/k6-user-mgmt-service      # live k6 output + summary
kubectl -n loadtest get job k6-user-mgmt-service          # Complete = thresholds held, Failed = breached
```

Profile: 1 min → ¼ peak, 2 min → ½ peak, 2 min → peak, 3 min plateau,
1 min → 0 (9 minutes). Thresholds (`options.thresholds` in the script) state
what "available under load" means - p95 login < 2 s, p95 `/api/me` < 1 s,
< 5 % failed requests, > 95 % checks passed; a breach fails the Job, which is
the point of the test.

Re-run: the Job is immutable once created, so delete it first (it also
disappears on its own six hours after finishing):

```sh
kubectl -n loadtest delete job k6-user-mgmt-service
kubectl apply -k loadtest/
```

## 3. Watch the HPA scale up - and down again

```sh
kubectl -n auth-staging get hpa auth-backend -w            # TARGETS and REPLICAS while the ramp runs
kubectl -n auth-staging get pods -l app.kubernetes.io/name=backend -w
kubectl -n auth-staging describe hpa auth-backend | sed -n '/Events/,$p'
```

Staging scales 1 → 2 replicas at 70 % of the CPU *request* (100m), prod
2 → 5. Scale-down waits out the stabilisation window (5 min in prod,
Kubernetes default 5 min in staging) after the load is gone, so keep
watching after the Job completes. Round-robin across the ready replicas is
visible per pod in the dashboard (request rate by backend pod) and in
Traefik's access log:

```sh
kubectl -n traefik logs deploy/infra-traefik --since=10m | grep -c '"RequestPath":"/api/login"'
```

## 4. Read the results in Prometheus / Grafana

```sh
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Grafana → folder **auth-stack** → **k6 load test**: virtual users, request
rate and p95 as k6 measured them (`testid` = the Job's pod name), next to the
server-side rate/latency/error rate, HPA desired vs. current replicas, backend
CPU against the HPA target and the request rate per backend pod. The other
two dashboards (**user-mgmt-service**, **auth-stack / Kubernetes**) show the
same window from the application and the platform side.

Prometheus queries behind it, for the record:

```promql
k6_vus{testid="k6-user-mgmt-service-xxxxx"}
rate(k6_http_reqs_total{testid="..."}[1m])
k6_http_req_duration_p95{testid="...", name="login"}
kube_horizontalpodautoscaler_status_current_replicas{namespace="auth-staging", horizontalpodautoscaler="auth-backend"}
sum by (pod) (rate(http_server_requests_seconds_count{namespace="auth-staging", uri="/users/login"}[1m]))
```

The push needs Prometheus' remote-write receiver, which
`charts/monitoring/values.yaml` enables (`enableRemoteWriteReceiver`).
k6 keeps running if the push fails - the run is still judged by its own
thresholds, only the k6 panels stay empty.

## Findings on this cluster (2026-09-14, staging, backend 100m request / 500m limit CPU)

Three runs against `auth-staging` with the profile above, HPA 1-2 replicas:

| Peak VUs | Result | What happened |
|---|---|---|
| 5 (default) | **Complete** - login p95 1.58 s, `/api/me` p95 78 ms, 0.05 % failed, 100 % checks | HPA 1 → 2 during the second stage (CPU 168-411 % of request), the new pod took traffic with 0 restarts; back to 1 replica ~5 min after the run |
| 8 | Failed - login p95 2.99 s (threshold 2 s), 0.04 % failed, 100 % checks | still available, but both pods saturated: ~2.3 logins/s is all two pods deliver |
| 30 | Failed - 503/500 from 20 VUs on | both backend pods CrashLoopBackOff: the CPU-throttled JVM misses the liveness probe (2 s timeout), kubelet kills it, the outage cascades |

What that says about the platform, not about k6:

* **Capacity is CPU-bound by bcrypt.** One login costs ~250 ms of CPU; with a
  500m limit a backend pod serves ~2 logins/s before latency climbs. The HPA
  target (70 % of a 100m *request*) trips at 70m, so the autoscaler reaches
  its maximum long before a pod reaches its limit - scaling works, but the
  ceiling is `maxReplicas × 2 logins/s`. Raising the CPU request (so the
  target means something) and the limit (so a pod can absorb a burst) in
  `charts/auth-stack/values.yaml` is the lever; prod's 2-5 replicas give it
  more headroom than staging's 1-2.
* **Overload kills instead of degrading.** The liveness probe shares the
  admin port with everything else; under CPU throttling it times out and the
  pod is restarted while it is merely slow. That belongs in `generic-stack`
  (CI repo): a longer liveness timeout/failure threshold, or a probe that does
  not compete with request handling.
* **The server-side panels stay empty.** The backend image's admin `/metrics`
  currently exposes only `build_info` and `health_check_up` - no Micrometer
  `http_server_requests_seconds_*` - so the user-mgmt-service dashboard's
  request/latency/error panels and the four PrometheusRule alerts have no
  data although `up` is 1 (CI repo, `src/Backend/patches/`). The k6 side, the
  HPA and the CPU panels do not depend on it.
* **The first user cannot log in.** JWT creation fails for any user that
  holds a role (`SimpleGrantedAuthority` is not serialisable) - the account
  the seed SQL promotes to ADMIN gets 401 on every login. That is why the
  k6 account must stay role-less (section 1). Application bug, user_mgmt_service.

## What the run exercises

| Acceptance criterion | Where |
|---|---|
| k6 runs in the cluster, ≥ 1 script for the service | `job.yaml`, `scripts/user-mgmt-service.js` |
| controlled rising load on a relevant endpoint | ramping-vus stages on `/api/login` (bcrypt, CPU-bound) and `/api/me` |
| telemetry recorded, effects visible in Prometheus / Grafana | k6 remote write + backend ServiceMonitor; dashboard **k6 load test** |
| HPA adds replicas under load and removes them after | HPA panel / `kubectl get hpa -w` (section 3) |
| service stays available, requests spread over replicas | k6 thresholds (Job Complete/Failed); request rate per backend pod |
