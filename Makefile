MINIKUBE_IP := $(shell minikube ip 2>/dev/null)
API_URL      := http://$(MINIKUBE_IP):30080
TF_DIR       := terraform/environments/dev

.PHONY: help setup monitoring deploy infra test clean reset

help:
	@echo "Usage:"
	@echo "  make setup       Start Minikube and install ArgoCD"
	@echo "  make monitoring  Deploy Prometheus + Grafana (run before 'deploy')"
	@echo "  make deploy      Deploy the app via ArgoCD"
	@echo "  make infra       Provision LocalStack S3 + SQS with Terraform"
	@echo "  make test        Run a quick API smoke test"
	@echo "  make clean       Delete Minikube cluster + stop LocalStack"
	@echo "  make reset       clean + remove Terraform state"

## 1. Start Minikube and install ArgoCD
setup:
	minikube start
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	@echo "Waiting for ArgoCD server..."
	kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s
	@echo "ArgoCD ready."
	@echo "UI password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

## 2. Deploy monitoring (must run before 'deploy' — installs Prometheus CRDs)
monitoring:
	kubectl apply -f https://raw.githubusercontent.com/4b93f-organization/K8s-prod-config/main/argocd/monitor.yaml
	@echo "Waiting for Prometheus operator CRDs..."
	@until kubectl get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1; do \
		echo "  CRDs not ready yet, retrying in 10s..."; sleep 10; \
	done
	@echo "CRDs ready."

## 3. Deploy the app
deploy:
	kubectl apply -f https://raw.githubusercontent.com/4b93f-organization/K8s-prod-config/main/argocd/application.yaml
	@echo "App syncing via ArgoCD. Watch: kubectl get pods -n app --watch"

## 4. Provision LocalStack resources
infra:
	@if [ ! -f $(TF_DIR)/terraform.tfvars ]; then \
		cp $(TF_DIR)/terraform.tfvars.example $(TF_DIR)/terraform.tfvars; \
		echo "Created terraform.tfvars from example — edit it to add your LocalStack auth token, then re-run 'make infra'"; \
		exit 1; \
	fi
	cd $(TF_DIR) && terraform init -input=false
	cd $(TF_DIR) && terraform apply -auto-approve

## 5. Smoke test
test:
	@echo "Testing API at $(API_URL)..."
	@curl -sf $(API_URL)/health | python3 -m json.tool
	@echo "Uploading test log..."
	$(eval JOB := $(shell curl -sf -X POST $(API_URL)/upload -F "file=@log/test.log" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])"))
	@echo "Job ID: $(JOB)"
	@sleep 3
	@curl -sf $(API_URL)/jobs/$(JOB) | python3 -m json.tool

## Teardown
clean:
	minikube delete
	localstack stop || true

reset: clean
	rm -f $(TF_DIR)/terraform.tfstate $(TF_DIR)/terraform.tfstate.backup
