# llm-inference-platform: one-command local bring-up on k3s (WSL2 + NVIDIA GPU)
#
#   make up-local      install/upgrade vLLM on the local k3s cluster (device plugin, image, Helm release)
#   make smoke-local   port-forward and send one completion
#   make down-local    remove the vLLM release (keeps k3s, the device plugin and the caches)
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

HELM_LOCAL_ARGS := -f $(CHART)/values-local.yaml \
	--set cache.hostPath.huggingface=$(HF_CACHE) \
	--set cache.hostPath.vllm=$(VLLM_CACHE) \
	$(if $(strip $(MODEL)),--set model.name=$(strip $(MODEL))) $(HELM_EXTRA)

.PHONY: help k3s-install preflight device-plugin image-import up-local down-local smoke-local status gpu-smoke lint

help: ## List targets
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

k3s-install: ## One-time: install k3s (asks for sudo; traefik off, kubeconfig readable)
	@curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
	echo "Add to ~/.bashrc:  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

preflight: ## Check tools, node, nvidia runtime, caches, and leftovers from the plain manifests
	@for t in kubectl helm docker; do command -v $$t >/dev/null || { echo "missing: $$t"; exit 1; }; done
	kubectl wait --for=condition=Ready node --all --timeout=60s >/dev/null
	kubectl get runtimeclass nvidia >/dev/null 2>&1 || { echo "no 'nvidia' RuntimeClass: is the NVIDIA Container Toolkit installed? then: sudo systemctl restart k3s"; exit 1; }
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
	for i in $$(seq 1 30); do
	  gpus=$$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')
	  [ -n "$$gpus" ] && [ "$$gpus" != "0" ] && { echo "node advertises nvidia.com/gpu: $$gpus"; exit 0; }
	  sleep 2
	done
	echo "device plugin did not advertise a GPU within 60 s: kubectl -n kube-system logs ds/nvidia-device-plugin-daemonset"; exit 1

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
	@helm lint $(CHART) $(HELM_LOCAL_ARGS)
	helm template $(RELEASE) $(CHART) $(HELM_LOCAL_ARGS) >/dev/null && echo "template renders"
