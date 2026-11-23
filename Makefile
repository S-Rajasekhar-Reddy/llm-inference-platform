# llm-inference-platform: one-command local bring-up on k3s (WSL2 + NVIDIA GPU)
#
#   make up-local      install/upgrade vLLM on the local k3s cluster (device plugin, image, Helm release)
#   make smoke-local   port-forward and send one completion
#   make down-local    remove the vLLM release (keeps k3s, the device plugin and the caches)
#   make monitoring-up kube-prometheus-stack + GPU exporter (run once, before up-local)
#   make grafana       port-forward Grafana with the vLLM dashboard
#   make keda-up       KEDA, for the autoscaling demo (run once)
#   make up-local KEDA=1  demo mode: 2 small replicas on one time-sliced GPU, scaled on queue depth
#   make scale-test    (demo mode) push past the queue threshold and watch it scale out and back
#   make help          list every target
#
# One-time prerequisites: WSL2 with systemd, Docker Engine, NVIDIA Container Toolkit, Helm,
# and k3s (`make k3s-install`). See platform/k3s/README.md.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

export KUBECONFIG ?= /etc/rancher/k3s/k3s.yaml

RELEASE     ?= vllm
NAMESPACE   ?= default
CHART       := charts/vllm
VLLM_TAG    := $(shell awk '/^  tag:/{print $$2; exit}' $(CHART)/values.yaml)
VLLM_IMAGE  := vllm/vllm-openai:$(VLLM_TAG)
HF_CACHE    ?= $(HOME)/.cache/huggingface
VLLM_CACHE  ?= $(HOME)/.cache/vllm
# Optional overrides: MODEL=Qwen/Qwen3-8B-FP8 (must already be in HF_CACHE),
# HELM_EXTRA="--set model.maxModelLen=4096"
MODEL       ?=
LOCAL_PORT  ?= 8000
HELM_EXTRA  ?=
MON_NS      ?= monitoring
KPS_VERSION ?= 93.3.0     # kube-prometheus-stack chart
GPU_EXPORTER_VERSION ?= 2.19.0   # nvidia-gpu-exporter chart (app v1.19.0)
ALERT       ?=
# KEDA=1 adds the autoscaling demo overlay (values-local-keda.yaml)
KEDA        ?= 0
KEDA_VERSION ?= 2.21.1    # kedacore/keda chart
TF_DIR      := infra/terraform
BILLING_DIR := infra/billing

# helm lint can't fake the Prometheus Operator APIs, so it checks the chart without them;
# helm template gets them via --api-versions.
NO_MONITORING   := --set monitoring.serviceMonitor.enabled=false --set monitoring.alerts.enabled=false \
	--set autoscaling.enabled=false
MONITORING_APIS := --api-versions monitoring.coreos.com/v1/ServiceMonitor --api-versions monitoring.coreos.com/v1/PrometheusRule \
	--api-versions keda.sh/v1alpha1/ScaledObject

HELM_LOCAL_ARGS := -f $(CHART)/values-local.yaml $(if $(filter 1,$(KEDA)),-f $(CHART)/values-local-keda.yaml) \
	--set cache.hostPath.huggingface=$(HF_CACHE) \
	--set cache.hostPath.vllm=$(VLLM_CACHE) \
	$(if $(strip $(MODEL)),--set model.name=$(strip $(MODEL))) $(HELM_EXTRA)

.PHONY: help k3s-install preflight device-plugin image-import up-local down-local smoke-local status gpu-smoke lint \
	monitoring-up monitoring-down monitoring-status grafana alert-test keda-up keda-down scale-test tf-init tf-plan bench-replicas \
	billing-plan cloud-preflight cloud-cost cloud-leftovers

help: ## List targets
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

k3s-install: ## One-time: install k3s (asks for sudo; traefik off, kubeconfig readable)
	@curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
	echo "Add to ~/.bashrc:  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

preflight: ## Check tools, node, nvidia runtime, caches, and leftovers from the plain manifests
	@for t in kubectl helm docker; do command -v $$t >/dev/null || { echo "missing: $$t"; exit 1; }; done
	kubectl wait --for=condition=Ready node --all --timeout=60s >/dev/null
	kubectl get runtimeclass nvidia >/dev/null 2>&1 || { echo "no 'nvidia' RuntimeClass: is the NVIDIA Container Toolkit installed? then: sudo systemctl restart k3s"; exit 1; }
	kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 || { echo "Prometheus Operator CRDs missing: run 'make monitoring-up' first"; exit 1; }
	[ "$(KEDA)" != 1 ] || kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1 || { echo "KEDA CRDs missing: run 'make keda-up' first"; exit 1; }
	test -d "$(HF_CACHE)" || { echo "HF cache not found at $(HF_CACHE)"; exit 1; }
	model="$(strip $(MODEL))"; model="$${model:-$$(awk '/^  name:/{print $$2; exit}' $(CHART)/values.yaml)}"
	test -d "$(HF_CACHE)/hub/models--$${model//\//--}" || { echo "$$model is not in $(HF_CACHE); the chart runs offline. Download it once first."; exit 1; }
	for kind in deployment service; do
	  owner=$$(kubectl -n $(NAMESPACE) get $$kind $(RELEASE) -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
	  if kubectl -n $(NAMESPACE) get $$kind $(RELEASE) >/dev/null 2>&1 && [ "$$owner" != "Helm" ]; then
	    echo "$$kind/$(RELEASE) exists but is not managed by Helm (left over from the plain manifests)."
	    echo "Remove it once with: kubectl -n $(NAMESPACE) delete deployment/$(RELEASE) service/$(RELEASE)"; exit 1
	  fi
	done
	echo "preflight ok (model: $$model, image: $(VLLM_IMAGE))"

device-plugin: ## Deploy the NVIDIA device plugin and wait until the node advertises nvidia.com/gpu
	@kubectl apply -f platform/k3s/10-nvidia-device-plugin.yaml >/dev/null
	kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=120s >/dev/null
	want=$$(awk '/replicas:/{print $$2; exit}' platform/k3s/10-nvidia-device-plugin.yaml)
	for i in $$(seq 1 30); do
	  gpus=$$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')
	  [ "$$gpus" = "$$want" ] && { echo "node advertises nvidia.com/gpu: $$gpus (time-sliced)"; exit 0; }
	  sleep 2
	done
	echo "node advertises nvidia.com/gpu: $${gpus:-0}, expected $$want after 60 s: kubectl -n kube-system logs ds/nvidia-device-plugin-daemonset"; exit 1

image-import: ## Copy the pinned vLLM image from Docker into k3s's containerd (skips if present)
	@if sudo k3s ctr -n k8s.io images ls -q | grep -qx "docker.io/$(VLLM_IMAGE)"; then
	  echo "k3s already has $(VLLM_IMAGE)"
	else
	  docker image inspect $(VLLM_IMAGE) >/dev/null 2>&1 || docker pull $(VLLM_IMAGE)
	  echo "importing $(VLLM_IMAGE) into k3s (a few minutes)..."
	  docker save $(VLLM_IMAGE) | sudo k3s ctr -n k8s.io images import -
	fi

up-local: preflight device-plugin image-import ## Install or upgrade vLLM on local k3s and wait until Ready
	@mkdir -p "$(VLLM_CACHE)"
	helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) $(HELM_LOCAL_ARGS) --wait --timeout 15m
	kubectl -n $(NAMESPACE) get pods -l app.kubernetes.io/instance=$(RELEASE)
	echo "Ready. Next: make smoke-local"

down-local: ## Remove the vLLM release (k3s, device plugin and caches stay)
	@helm uninstall $(RELEASE) -n $(NAMESPACE) --wait || echo "release $(RELEASE) not installed"

smoke-local: ## Port-forward and request one completion from the running release
	@kubectl -n $(NAMESPACE) port-forward svc/$(RELEASE) $(LOCAL_PORT):8000 >/tmp/$(RELEASE)-pf.log 2>&1 &
	pf=$$!; trap 'kill $$pf 2>/dev/null' EXIT
	for i in $$(seq 1 15); do curl -sf localhost:$(LOCAL_PORT)/health >/dev/null && break; sleep 1; done
	model=$$(curl -sf localhost:$(LOCAL_PORT)/v1/models | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])')
	echo "model: $$model"
	curl -sf localhost:$(LOCAL_PORT)/v1/completions -H 'Content-Type: application/json' \
	  -d "{\"model\":\"$$model\",\"prompt\":\"Kubernetes schedules GPUs by\",\"max_tokens\":40}" \
	  | python3 -c 'import sys,json; r=json.load(sys.stdin); print(repr(r["choices"][0]["text"])); print("tokens:", r["usage"])'

status: ## Show the release, its pods and the node's GPU capacity
	@helm list -n $(NAMESPACE)
	kubectl -n $(NAMESPACE) get pods,svc -l app.kubernetes.io/instance=$(RELEASE)
	echo "allocatable nvidia.com/gpu: $$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')"

gpu-smoke: ## Run nvidia-smi in a pod under the nvidia RuntimeClass, then clean up
	@kubectl delete pod gpu-smoke --ignore-not-found >/dev/null
	kubectl apply -f platform/k3s/00-gpu-smoke-test.yaml >/dev/null
	kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke --timeout=180s >/dev/null
	kubectl logs gpu-smoke
	kubectl delete pod gpu-smoke >/dev/null

lint: ## helm lint + render the local values (no cluster needed)
	@helm lint $(CHART) $(HELM_LOCAL_ARGS) $(NO_MONITORING)
	helm template $(RELEASE) $(CHART) $(HELM_LOCAL_ARGS) $(MONITORING_APIS) >/dev/null && echo "template renders"
	helm template $(RELEASE) $(CHART) $(HELM_LOCAL_ARGS) -f $(CHART)/values-local-keda.yaml $(MONITORING_APIS) >/dev/null && echo "template renders (KEDA demo)"
	bash -n platform/monitoring/alert-test.sh && bash -n platform/monitoring/prom-api.sh && bash -n platform/autoscaling/scale-test.sh && bash -n bench/replicas-same-gpu.sh && python3 -m py_compile platform/monitoring/loadgen.py platform/monitoring/promq.py && echo "scripts parse"

monitoring-up: ## Install kube-prometheus-stack + nvidia_gpu_exporter into the monitoring namespace
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
	helm repo update prometheus-community >/dev/null
	helm upgrade --install kps prometheus-community/kube-prometheus-stack --version $(strip $(KPS_VERSION)) \
	  -n $(MON_NS) --create-namespace -f platform/monitoring/kube-prometheus-stack-values.yaml --wait --timeout 10m
	helm upgrade --install nvidia-gpu-exporter oci://ghcr.io/utkuozdemir/charts/nvidia-gpu-exporter \
	  --version $(strip $(GPU_EXPORTER_VERSION)) -n $(MON_NS) -f platform/monitoring/nvidia-gpu-exporter-values.yaml --wait --timeout 5m
	kubectl -n $(MON_NS) get pods
	echo "Monitoring ready. Next: make up-local (adds the vLLM ServiceMonitor, alerts, dashboard), then make grafana"

monitoring-down: ## Remove the monitoring releases (CRDs stay, so the vLLM release keeps working)
	@helm uninstall nvidia-gpu-exporter -n $(MON_NS) || true
	helm uninstall kps -n $(MON_NS) || true

monitoring-status: ## Scrape-target health for vLLM and the GPU exporter, plus pending/firing alerts
	@prom() { platform/monitoring/prom-api.sh "$(MON_NS)" "$$1"; }
	prom targets | python3 platform/monitoring/promq.py targets
	prom alerts  | python3 platform/monitoring/promq.py alerts

grafana: ## Print the Grafana admin password and port-forward to http://localhost:3000
	@echo "user: admin   password: $$(kubectl -n $(MON_NS) get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
	echo "http://localhost:3000 -> Dashboards -> 'vLLM inference platform' (Ctrl-C to stop)"
	kubectl -n $(MON_NS) port-forward svc/kps-grafana 3000:80

alert-test: ## Force one alert to fire, then restore thresholds: make alert-test ALERT=ttft|queue|idle
	@RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) CHART=$(CHART) MON_NS=$(MON_NS) LOCAL_PORT=$(LOCAL_PORT) \
	  HELM_ARGS='$(HELM_LOCAL_ARGS)' platform/monitoring/alert-test.sh $(ALERT)

keda-up: ## Install KEDA (namespace keda); the chart's ScaledObject needs its CRDs
	@helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
	helm repo update kedacore >/dev/null
	helm upgrade --install keda kedacore/keda --version $(strip $(KEDA_VERSION)) -n keda --create-namespace --wait --timeout 5m
	kubectl -n keda get pods
	echo "KEDA ready. Next: make up-local (adds the ScaledObject), then make scale-test"

keda-down: ## Remove KEDA (delete the vLLM release's ScaledObject first: make up-local HELM_EXTRA='--set autoscaling.enabled=false')
	@helm uninstall keda -n keda || true

scale-test: ## (after make up-local KEDA=1) Load past the queue threshold; watch 1 -> 2 -> 1 (about 10 min)
	@RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) MON_NS=$(MON_NS) VLLM_IMAGE=$(VLLM_IMAGE) \
	  platform/autoscaling/scale-test.sh

bench-replicas: ## Same model on one GPU: 1 vs 2 replicas vs 1 full-GPU replica, REPEATS=3 (about 55 min; KEDA paused, then restored)
	@RELEASE=$(RELEASE) NAMESPACE=$(NAMESPACE) CHART=$(CHART) MON_NS=$(MON_NS) VLLM_IMAGE=$(VLLM_IMAGE) \
	  HELM_ARGS='$(HELM_LOCAL_ARGS)' bench/replicas-same-gpu.sh

tf-init: ## terraform init + fmt check + validate for the EKS cloud run (no AWS changes)
	@command -v terraform >/dev/null || { echo "missing: terraform (>= 1.6)"; exit 1; }
	terraform -chdir=$(TF_DIR) init -upgrade
	terraform -chdir=$(TF_DIR) fmt -check -diff
	terraform -chdir=$(TF_DIR) validate

tf-plan: ## terraform plan for the EKS cloud run (read-only; needs AWS credentials and terraform.tfvars)
	@test -f $(TF_DIR)/terraform.tfvars || { echo "copy $(TF_DIR)/terraform.tfvars.example to terraform.tfvars and fill it in"; exit 1; }
	terraform -chdir=$(TF_DIR) plan -out=tfplan
	terraform -chdir=$(TF_DIR) show -no-color tfplan | grep -E '^Plan:'

billing-plan: ## terraform init + plan for infra/billing (project budget + weights bucket; applied before the run, kept after it)
	@command -v terraform >/dev/null || { echo "missing: terraform (>= 1.6)"; exit 1; }
	@test -f $(BILLING_DIR)/terraform.tfvars || { echo "copy $(BILLING_DIR)/terraform.tfvars.example to terraform.tfvars and fill it in"; exit 1; }
	terraform -chdir=$(BILLING_DIR) init -upgrade
	terraform -chdir=$(BILLING_DIR) fmt -check -diff
	terraform -chdir=$(BILLING_DIR) validate
	terraform -chdir=$(BILLING_DIR) plan -out=tfplan
	terraform -chdir=$(BILLING_DIR) show -no-color tfplan | grep -E '^Plan:'
	@echo "Apply (creates the budget and an empty bucket): terraform -chdir=$(BILLING_DIR) apply tfplan"

cloud-preflight: ## Read-only checks before the cloud run: quota vs NodePool limit, GPU AZs, EKS version support, budget, cost tag, leftovers
	@python3 infra/scripts/cloud_preflight.py

cloud-cost: ## Live cost estimate of the running cloud run (runtime x price); billing data lags by hours
	@python3 infra/scripts/cloud_cost.py

cloud-leftovers: ## After terraform destroy: anything from the run that still exists and bills (exit 1 if so)
	@python3 infra/scripts/cloud_leftovers.py
