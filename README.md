# app-manifests

Kubernetes manifests for [Track Your Budget](https://github.com/Eduard1999Gol/Track-Your-Budget),
managed with Kustomize and deployed by Argo CD. This repository is the single
source of truth for what runs in the test and prod clusters: nothing is
`kubectl apply`ed by hand except the two Secrets described below.

---

## How a change reaches a cluster

```
track-your-budget repo            this repo                     clusters
──────────────────────            ──────────────────────        ───────────────────
push to `test` or `main`
  └─ Azure Pipeline
       ├─ build + push images ──► Docker Hub
       └─ kustomize edit set image
            in overlays/<env>  ──► commit "[skip ci]" ──► Argo CD (dev server)
                                                             ├─ overlays/test ──► test cluster (in-cluster)
                                                             └─ overlays/prod ──► prod cluster (remote)
```

| Branch in app repo | Overlay | Cluster | Ingress host | Argo CD Application |
| --- | --- | --- | --- | --- |
| `test` | `overlays/test` | dev server, same cluster as Argo CD | `dev.track-your-budget.de` (HTTP) | `budget-app-test` |
| `main` | `overlays/prod` | prod server (k3s, single node) | `track-your-budget.de` (HTTPS via Cloudflare) | `budget-app-production` |

The pipeline only ever touches the `images:` block of an overlay. Everything
else in this repo is edited by hand and reviewed like code.

---

## Layout

```
.
├── base/
│   ├── backend.yaml        Deployment (migrate init container + gunicorn), Service "backend", media PVC
│   ├── frontend.yaml       Deployment (nginx serving the SPA, proxies /api to "backend"), Service
│   ├── ingress.yaml        Traefik Ingress, host track-your-budget.de → frontend-service
│   └── kustomization.yaml
├── overlays/
│   ├── test/
│   │   ├── kustomization.yaml   namespace, image tags, host/DEBUG/JWT patches
│   │   └── postgres.yaml        Postgres running IN the cluster (Deployment + PVC + Service "postgres")
│   └── prod/
│       ├── kustomization.yaml   namespace, image tags, ALLOWED_HOSTS/JWT/DEBUG patches
│       └── postgres.yaml        Postgres running ON the host, exposed as Service "postgres"
└── secrets/
    ├── backend-secret.template.yaml    copy, fill in, apply by hand (see Secrets)
    └── frontend-secret.template.yaml
```

Two names are load-bearing and must not change:

- Service **`backend`**: the frontend image has `proxy_pass http://backend:8000` baked in.
- Service **`postgres`**: `backend-secret` sets `POSTGRES_HOST=postgres` in both
  environments. Test and prod each provide a Service with that name, backed by
  different things.

---

## Environment differences

| Setting | base | test | prod |
| --- | --- | --- | --- |
| `namespace` | none | `default` | `default` |
| Database | – | `postgres:16-alpine` Deployment with 1Gi PVC | PostgreSQL on the k3s host, reached via `10.42.0.1` |
| Ingress host | `track-your-budget.de` | patched to `dev.track-your-budget.de` | inherited |
| `ALLOWED_HOSTS` | not set | `dev.track-your-budget.de,localhost,127.0.0.1` | `track-your-budget.de,localhost,127.0.0.1` |
| `DEBUG` | `False` | `True` (tracebacks on purpose) | `False` |
| `JWT_AUTH_SECURE` | `True` | `False` (plain HTTP) | `True` (HTTPS) |

`localhost` stays in every `ALLOWED_HOSTS` because the kubelet probes send
`Host: localhost` (see `base/backend.yaml`).

### Prod database

Prod does not run Postgres in Kubernetes. `overlays/prod/postgres.yaml` defines
a Service **without a selector** plus a hand-written **EndpointSlice** that
points at `10.42.0.1:5432`, the k3s `cni0` bridge address, which is the host
as seen from the pod network.

Requirements outside this repo:

- On the host: `listen_addresses = '*'` in `postgresql.conf`, a
  `host <db> <user> 10.42.0.0/16 scram-sha-256` line in `pg_hba.conf`, port
  5432 firewalled to the pod range only.
- In Argo CD: the default `resource.exclusions` in `argocd-cm` exclude
  `Endpoints` and `EndpointSlice`. That block has been removed on the dev
  server, otherwise Argo CD silently skips the slice and the backend gets
  "Connection refused" from the `postgres` Service. Keep it removed.

---

## Secrets

Secrets are **not** in Git (`*secret.yaml` is ignored) and Argo CD does not
manage them. Each cluster gets them once, by hand, from the templates:

```bash
cp secrets/backend-secret.template.yaml  secrets/backend-secret.yaml
cp secrets/frontend-secret.template.yaml secrets/frontend-secret.yaml
# fill in the placeholders, then on the target cluster:
kubectl apply -n default -f secrets/backend-secret.yaml -f secrets/frontend-secret.yaml
kubectl rollout restart deployment/budget-backend deployment/budget-frontend -n default
```

| Secret | Consumed by | Keys |
| --- | --- | --- |
| `backend-secret` | backend + migrate init container via `envFrom` | `DJANGO_SECRET_KEY`, `FRONTEND_URL`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_PORT` |
| `frontend-secret` | frontend via `env` | `VITE_GOOGLE_LINK`, `VITE_GITHUB_LINK`, `VITE_MICROSOFT_LINK` |

`FRONTEND_URL` and the `redirect_uri` inside each `VITE_*_LINK` must be the
same value, and that value must be registered at the OAuth provider. OAuth
client IDs and secrets are **not** environment variables: they live in the
database as django-allauth `SocialApp` rows and are created through the Django
admin (or `manage.py shell`) after the first migration.

Plain configuration (`ALLOWED_HOSTS`, `DEBUG`, `JWT_AUTH_SECURE`) belongs in the
overlay patches, not in the Secret.

---

## Argo CD

Argo CD runs on the dev server and manages both environments. The Application
objects are created by hand and are not stored in this repo.

| Application | Source path | Destination | Sync policy |
| --- | --- | --- | --- |
| `budget-app-test` | `overlays/test` | in-cluster, `default` | automated, prune |
| `budget-app-production` | `overlays/prod` | `https://<prod-ip>:6443`, `default` | automated, prune |

`selfHeal` is off, so Argo CD only syncs when the Git revision changes. If a
resource is deleted or edited in the cluster, or a previously excluded kind
becomes visible, trigger a sync by hand:

```bash
argocd app sync budget-app-production
```

The prod server gets its IP by DHCP. When it changes, update `server` in the
cluster Secret (`kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster`)
and `spec.destination.server` in the Application. The k3s API certificate
already includes the new IP after a k3s restart.

---

## Working locally

Render an overlay without a cluster:

```bash
kustomize build overlays/prod
kustomize build overlays/test
```

Bump an image tag the same way the pipeline does:

```bash
cd overlays/prod
kustomize edit set image eduardgohl/budget-tracker-backend=eduardgohl/budget-tracker-backend:<tag>
```

Do not edit the `images:` blocks by hand in a branch the pipeline also writes
to; the pipeline commits directly to `main` with `[skip ci]`, and concurrent
edits produce conflicts.

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Backend pod stuck in `Init:CrashLoopBackOff` | `migrate` cannot reach or log in to Postgres. `kubectl logs <pod> -c migrate` shows which: "Connection refused" = no endpoint behind Service `postgres` or Postgres not listening; "no pg_hba.conf entry" / "password authentication failed" = host config or Secret mismatch. |
| Argo CD condition "Resource … EndpointSlice … is excluded in the settings" | `resource.exclusions` in `argocd-cm` still contains the `Endpoints`/`EndpointSlice` block. |
| Argo CD "Namespace for … is missing" | Overlay lacks `namespace:` or the Application lacks `destination.namespace`. |
| Backend returns 400 for every request | Host not in `ALLOWED_HOSTS` patch for that overlay. |
| Users are logged out every 5 minutes | `JWT_AUTH_SECURE=True` on a plain-HTTP host; the browser drops the Secure refresh cookie. |
| Login buttons missing | `frontend-secret` not applied or a `VITE_*_LINK` value is empty. |
| Login returns 503 "not configured on the server" | No `SocialApp` row for that provider in the database. |
