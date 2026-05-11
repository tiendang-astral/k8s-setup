# DocFlow Platform — Kubernetes Deployment

Production deployment on Kubernetes (Minikube / any K8s cluster).

## Architecture Map

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                           │
│                                                                     │
│  ┌─────────────── NodePort Services (External Access) ─────────────┐│
│  │                                                                  ││
│  │  Frontend:30000  Backend:30001  Grafana:30002                   ││
│  │  MinIO API:30003  MinIO Console:30004                          ││
│  │                                                                  ││
│  │  ┌────────────┐  ┌────────────┐  ┌──────────┐  ┌────────────┐  ││
│  │  │ Frontend   │  │  Backend   │  │ Grafana  │  │  MinIO     │  ││
│  │  │ Pod :3000  │  │  Pod :8000 │  │ Pod :3000│  │  Pod :9000 │  ││
│  │  └────────────┘  └────────────┘  └──────────┘  └────────────┘  ││
│  └─────────────────────────────────────────────────────────────────┘│
│                                                                     │
│  ┌─────────── ClusterIP Services (Internal Only) ──────────────────┐│
│  │                                                                  ││
│  │  Postgres:5432  Redis:6379  Prometheus:9090                     ││
│  │  MinIO (headless):9000  MinIO (headless):9001                  ││
│  │                                                                  ││
│  │  ┌────────────┐  ┌────────────┐  ┌──────────────┐              ││
│  │  │ Postgres   │  │  Redis     │  │ Prometheus   │              ││
│  │  │ StatefulSet│  │StatefulSet │  │ Deployment   │              ││
│  │  └────────────┘  └────────────┘  └──────────────┘              ││
│  │  ┌────────────┐  ┌──────────────────┐                           ││
│  │  │ Platform   │  │ Docprocess       │                           ││
│  │  │ Worker     │  │ Worker           │                           ││
│  │  │ Deployment │  │ Deployment       │                           ││
│  │  └────────────┘  └──────────────────┘                           ││
│  └─────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────┘
```

## File Structure

```
deployment/
├── app/                                    # Application services
│   ├── 01-app.config-map.yml              │   ConfigMap — shared env vars
│   ├── 02-app.secret.yml                  │   Secret — passwords & keys
│   ├── 03-app.pvc.yml                     │   PVCs — uploads, temp, output, logs, workspace
│   ├── 04-docaiplatform-platform-worker.deployment.yml  │   Platform Worker
│   ├── 05-docprocess-worker.deployment.yml              │   Docprocess Worker
│   ├── 06-docaiplatform-backend.deployment.yml          │   Backend + NodePort Service
│   └── 07-docaiplatform-frontend.deployment.yml         │   Frontend + NodePort Service
│
├── database/                               # Database layer
│   ├── 01-postgres.config-map.yml         │   ConfigMap — DB name, user, port
│   ├── 02-postgres.secret.yml             │   Secret — DB password
│   ├── 03-postgres.statefulset.yml        │   Headless Svc + ClusterIP Svc + StatefulSet
│   └── 04-redis.statefulset.yml           │   Headless Svc + ClusterIP Svc + StatefulSet
│
├── min-io/                                 # Object storage (MinIO)
│   ├── 01-min-io.config-map.yml           │   ConfigMap — bucket name + CORS
│   ├── 02-min-io.secret.yml               │   Secret — MinIO root credentials
│   ├── 03-init.job.yml                    │   Job — create bucket + apply CORS
│   └── 04-min-io.statefulset.yml          │   Headless Svc + NodePort Svc + StatefulSet
│
└── monitoring/                             # Observability
    ├── 01-monitoring.config-map.yml       │   ConfigMap — Prometheus config, alerts, Grafana provisioning
    ├── 02-monitoring.pvc.yml              │   PVCs — prometheus-data, grafana-data
    ├── 03-prometheus.deployment.yml       │   Service + Deployment
    └── 04-grafana.deployment.yml          │   Service (NodePort) + Deployment
```

## Public Access URLs

Access all services via `<minikube-ip>:<nodePort>`:

```bash
minikube ip
# e.g. 192.168.49.2
```

| Service | URL | Description |
|---|---|---|
| Frontend | `http://<minikube-ip>:30000` | Main UI |
| Backend API | `http://<minikube-ip>:30001/api` | REST API |
| Grafana | `http://<minikube-ip>:30002` | Dashboards (admin/admin password from secret) |
| MinIO API | `http://<minikube-ip>:30003` | Object storage API |
| MinIO Console | `http://<minikube-ip>:30004` | MinIO web UI |

## Internal Services (no external access)

| Service | DNS Name | Used By |
|---|---|---|
| Postgres | `postgres:5432` | Backend, Platform Worker |
| Redis | `redis:6379` | Backend, Platform Worker, Docprocess Worker |
| Prometheus | `prometheus:9090` | Grafana datasource |
| MinIO (headless) | `minio:9000` | All app services |

To access internal services for debugging:
```bash
kubectl port-forward svc/prometheus 9090:9090
kubectl port-forward svc/postgres-svc 5432:5432
kubectl port-forward svc/redis-svc 6379:6379
```

## Apply Order

```bash
# 1. Database layer
kubectl apply -f database/

# 2. MinIO storage
kubectl apply -f min-io/01-min-io.config-map.yml
kubectl apply -f min-io/02-min-io.secret.yml
kubectl apply -f min-io/04-min-io.statefulset.yml
# Wait for MinIO to be ready, then run init job
kubectl apply -f min-io/03-init.job.yml

# 3. Monitoring
kubectl apply -f monitoring/01-monitoring.config-map.yml
kubectl apply -f monitoring/02-monitoring.pvc.yml
kubectl apply -f monitoring/03-prometheus.deployment.yml
kubectl apply -f monitoring/04-grafana.deployment.yml

# 4. Application
kubectl apply -f app/01-app.config-map.yml
kubectl apply -f app/02-app.secret.yml
kubectl apply -f app/03-app.pvc.yml
kubectl apply -f app/04-docaiplatform-platform-worker.deployment.yml
kubectl apply -f app/05-docprocess-worker.deployment.yml
kubectl apply -f app/06-docaiplatform-backend.deployment.yml
kubectl apply -f app/07-docaiplatform-frontend.deployment.yml
```

Or apply everything at once (K8s handles dependencies via init containers):
```bash
kubectl apply -f database/ -f min-io/ -f monitoring/ -f app/
```

## Startup Sequence

```
Postgres ──┐
           ├──► Backend ──► Frontend
Redis ─────┘                    ▲
           ┌──► Platform Worker │
Postgres ──┘                    │
Redis ─────┐                    │
           ├──► Docprocess Worker
Redis ─────┘

MinIO ───► MinIO Init Job (bucket + CORS)
```

## Configuration

### Required changes before deploying

Replace placeholder values in these files:

| File | Key | Default Value |
|---|---|---|
| `app/01-app.config-map.yml` | `AI_GATEWAY_ENDPOINT` | `your-ai-gateway-endpoint-here` |
| `app/01-app.config-map.yml` | `AI_GATEWAY_MODEL` | `your-ai-gateway-model-here` |
| `app/01-app.config-map.yml` | `NEXT_PUBLIC_API_BASE_URL` | `your-public-api-base-url-here` |
| `app/02-app.secret.yml` | `JWT_SECRET_KEY` | `your-jwt-secret-key-here` |
| `app/02-app.secret.yml` | `POSTGRES_PASSWORD` | `your-postgres-password-here` |
| `app/02-app.secret.yml` | `MINIO_ACCESS_KEY` | `your-minio-access-key-here` |
| `app/02-app.secret.yml` | `MINIO_SECRET_KEY` | `your-minio-secret-key-here` |
| `app/02-app.secret.yml` | `AI_GATEWAY_KEY` | `your-ai-gateway-key-here` |
| `app/02-app.secret.yml` | `GRAFANA_ADMIN_PASSWORD` | `your-grafana-admin-password-here` |
| `database/02-postgres.secret.yml` | `POSTGRES_PASSWORD` | `your-postgres-password-here` |
| `min-io/02-min-io.secret.yml` | `MINIO_ROOT_USER` | `your-access-key-here` |
| `min-io/02-min-io.secret.yml` | `MINIO_ROOT_PASSWORD` | `your-secret-key-here` |

Or use kubectl to create secrets securely:
```bash
kubectl create secret generic app-secret \
  --from-literal=JWT_SECRET_KEY=<value> \
  --from-literal=POSTGRES_PASSWORD=<value> \
  --from-literal=MINIO_ACCESS_KEY=<value> \
  --from-literal=MINIO_SECRET_KEY=<value> \
  --from-literal=AI_GATEWAY_KEY=<value> \
  --from-literal=GRAFANA_ADMIN_PASSWORD=<value>

kubectl create secret generic postgres-secret \
  --from-literal=POSTGRES_PASSWORD=<value>

kubectl create secret generic minio-secret \
  --from-literal=MINIO_ROOT_USER=<value> \
  --from-literal=MINIO_ROOT_PASSWORD=<value>
```

## Cleanup

```bash
kubectl delete -f app/ -f monitoring/ -f min-io/ -f database/
```
