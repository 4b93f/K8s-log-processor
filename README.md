# k8s-prod

Production-ready log processing system running on Kubernetes. Upload log files or images — the worker parses them, extracts HTTP metrics, and stores results in S3. Full observability via Prometheus + Grafana.

## Architecture

```
User → POST /upload → API → S3 (raw file) + SQS (job message)
                               ↓
                           Worker (polls SQS)
                               ↓
                     S3 (results/job_id/summary.json)
                               ↓
                     GET /jobs/{job_id} → result
```

```
┌─────────────────────────────────────────────────────┐
│  Kubernetes (Minikube)                              │
│                                                     │
│  ┌─────────┐    ┌──────────┐    ┌───────────────┐  │
│  │   API   │    │  Worker  │───▶│  Prometheus   │  │
│  │ FastAPI │    │ (×2 pods)│    │  + Grafana    │  │
│  └────┬────┘    └────┬─────┘    └───────────────┘  │
│       │              │                              │
└───────┼──────────────┼──────────────────────────────┘
        │              │
   ┌────▼──────────────▼────┐
   │     LocalStack         │
   │   S3  │  SQS           │
   └────────────────────────┘
```

## Screenshots

### ArgoCD — apps synced and healthy
![ArgoCD](docs/screenshots/argocd.png)

### Grafana — worker metrics dashboard
![Grafana dashboard](docs/screenshots/grafana-dashboard.png)

### Pods running
![kubectl get pods](docs/screenshots/pods.png)

### API in action
![API upload + job result](docs/screenshots/api.png)

## Features

- **FastAPI** — upload endpoint, job status polling, health check
- **Worker** — SQS consumer with log parsing and OCR support (Tesseract)
- **OCR** — send images of logs, worker extracts text and parses them
- **Prometheus metrics** — messages processed/failed, OCR stats, processing duration
- **Terraform** — provisions S3 + SQS on LocalStack
- **Multi-arch Docker builds** — `linux/amd64` + `linux/arm64`
- **Non-root containers** — runs as `appuser` (uid 1001)
- **Snyk scanning** — container vulnerability scanning in CI

## Repo Structure

```
app/
  api/          # FastAPI service
  worker/       # SQS consumer + OCR + Prometheus metrics
terraform/
  modules/aws/  # S3 and SQS modules
  environments/dev/
.github/workflows/ci.yaml  # Build, push, scan
```

Kubernetes config lives in a separate repo: [k8s-prod-config](https://github.com/4b93f-organization/k8s-prod-config)

## Worker Metrics

| Metric | Description |
|--------|-------------|
| `worker_messages_processed_total` | Successfully processed messages |
| `worker_messages_failed_total` | Failed messages |
| `worker_lines_processed_total` | Log lines parsed |
| `worker_http_errors_found_total` | 4xx/5xx errors found |
| `worker_ocr_processed_total` | Images processed via OCR |
| `worker_ocr_failed_total` | OCR failures |
| `worker_processing_duration_seconds` | Processing time histogram |

## CI/CD

GitHub Actions on every push to `main` (when `app/` files change):

1. Build + push multi-arch Docker images to GHCR
2. Snyk dependency scan
3. Snyk container image scan

Kubernetes deployment is handled by ArgoCD via [k8s-prod-config](https://github.com/4b93f-organization/k8s-prod-config) — push to that repo, cluster updates automatically.

## Local Setup

### Prerequisites

| Tool | Purpose |
|------|---------|
| [Minikube](https://minikube.sigs.k8s.io/) | Local Kubernetes cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Kubernetes CLI |
| [Helm](https://helm.sh/docs/intro/install/) | Chart management |
| [LocalStack](https://docs.localstack.cloud/getting-started/installation/) | Local AWS (S3 + SQS) — needs an auth token from [app.localstack.cloud](https://app.localstack.cloud) |
| [Terraform](https://developer.hashicorp.com/terraform/install) | Provision AWS resources |

### Start LocalStack first

```bash
localstack start
```

### Then run in order

```bash
make setup       # start Minikube + install ArgoCD
make monitoring  # deploy Prometheus + Grafana (waits for CRDs)
make deploy      # deploy the app via ArgoCD
make infra       # provision S3 + SQS on LocalStack
```

> `make infra` will create `terraform.tfvars` from the example on first run and ask you to add your LocalStack auth token.

### Test

```bash
make test        # health check + upload test log + fetch result
```

### Access services

| Service | URL | Credentials |
|---------|-----|-------------|
| API | `http://$(minikube ip):30080` | — |
| Grafana | `http://$(minikube ip):30300` | admin / prom-operator |
| ArgoCD | `kubectl port-forward svc/argocd-server -n argocd 8080:443` | password from `make setup` output |

### Teardown

```bash
make reset       # delete Minikube + stop LocalStack + clear Terraform state
```

## API Reference

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/upload` | Upload log file or image |
| `GET` | `/jobs/{job_id}` | Get job result |
