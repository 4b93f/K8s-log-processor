API_URL := http://localhost:8080
TF_DIR       := terraform/environments/dev

.PHONY: help setup monitoring deploy infra test clean reset

help:
	@echo "Usage:"
	@echo "  make setup       Start Minikube and install ArgoCD"
	@echo "  make monitoring  Deploy Prometheus + Grafana (run before 'deploy')"
	@echo "  make infra       Provision LocalStack S3 + SQS with Terraform"
	@echo "  make deploy      Deploy the app via ArgoCD"
	@echo "  make test        Run a quick API smoke test"
	@echo "  make clean       Delete Minikube cluster + stop LocalStack"
	@echo "  make reset       clean + remove Terraform state"

## 1. Start Minikube and install ArgoCD
setup:
	minikube start --driver=qemu2 --cpus=4 --memory=6144
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	@echo "Waiting for ArgoCD server..."
	kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s
	@echo "ArgoCD ready."
	@echo "UI password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

## 2. Deploy monitoring (must run before 'deploy' — installs Prometheus CRDs)
monitoring:
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env from example — set GRAFANA_PASSWORD, then re-run 'make monitoring'"; \
		exit 1; \
	fi
	@set -a; . ./.env; set +a; \
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -; \
	kubectl create secret generic grafana-admin \
		--from-literal=admin-user=admin \
		--from-literal=admin-password=$$GRAFANA_PASSWORD \
		-n monitoring --dry-run=client -o yaml | kubectl apply -f -
	curl -sL https://raw.githubusercontent.com/4b93f-organization/K8s-log-processor-config/main/argocd/monitor.yaml | kubectl apply -f -
	@echo "Waiting for Prometheus operator CRDs..."
	@until kubectl get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1; do \
		echo "  CRDs not ready yet, retrying in 10s..."; sleep 10; \
	done
	@echo "CRDs ready."

## 3. Deploy the app
deploy:
	curl -sL https://raw.githubusercontent.com/4b93f-organization/K8s-log-processor-config/main/argocd/application.yaml | kubectl apply -f -
	@echo "App syncing via ArgoCD. Watch: kubectl get pods -n app --watch"

## 4. Provision LocalStack resources
infra:
	@if [ ! -f $(TF_DIR)/terraform.tfvars ]; then \
		cp $(TF_DIR)/terraform.tfvars.example $(TF_DIR)/terraform.tfvars; \
		echo "Created terraform.tfvars from example — edit it to add your LocalStack auth token, then re-run 'make infra'"; \
		exit 1; \
	fi
	cd $(TF_DIR) && terraform init -input=false
	cd $(TF_DIR) && terraform apply -auto-approve -refresh=true

## 5. Smoke test
test:
	@kill $$(cat /tmp/pf.pid 2>/dev/null) 2>/dev/null; true; \
	kubectl port-forward svc/api 8080:8000 -n app &>/tmp/pf.log & echo $$! > /tmp/pf.pid; \
	sleep 5; \
	echo "Health check:"; \
	curl -sf http://localhost:8080/health | python3 -m json.tool; \
	echo "Uploading test log..."; \
	JOB=$$(curl -sf -X POST http://localhost:8080/upload -F "file=@log/test.log" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])"); \
	echo "Job ID: $$JOB"; \
	sleep 3; \
	echo "Result:"; \
	curl -sf http://localhost:8080/jobs/$$JOB | python3 -m json.tool; \
	kill $$(cat /tmp/pf.pid) 2>/dev/null; true

## Teardown
clean:
	minikube delete
	localstack stop || true

reset: clean
	rm -f $(TF_DIR)/terraform.tfstate $(TF_DIR)/terraform.tfstate.backup
