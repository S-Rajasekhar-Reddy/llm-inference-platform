# Local Kubernetes: k3s on WSL2

Plain manifests for running the platform on a single-node k3s cluster inside WSL2
(RTX 5080 Laptop GPU, 16 GB). A Helm chart comes later; EKS runs this properly in week 4.

| File | What it does |
|---|---|
| `00-gpu-smoke-test.yaml` | Runs `nvidia-smi` once under the `nvidia` RuntimeClass. If this prints the GPU, the runtime plumbing works. |
| `10-nvidia-device-plugin.yaml` | NVIDIA device plugin v0.20.1, modified to run under the `nvidia` RuntimeClass (k3s keeps runc as default). Advertises `nvidia.com/gpu` on the node. |
| `20-vllm-qwen3-1.7b.yaml` | vLLM v0.33.0 Deployment + Service serving Qwen3-1.7B, requesting `nvidia.com/gpu: 1`. |

## Run it

Prerequisite: NVIDIA Container Toolkit installed in WSL (`/usr/bin/nvidia-container-runtime`) *before* k3s starts, so k3s registers the runtime.

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
docker save vllm/vllm-openai:v0.33.0 | sudo k3s ctr images import -   # reuse the Docker image
kubectl apply -f deploy/k8s/
kubectl port-forward svc/vllm 8000:8000
curl -s localhost:8000/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-1.7B","prompt":"Kubernetes schedules GPUs by","max_tokens":40}'
```

## What broke and how it was fixed (11 Nov 2026)

1. **vLLM crashed at startup with `ValueError: VLLM_PORT 'tcp://10.43.211.50:8000' appears to be a URI`.**
   Kubernetes injects legacy service-link env vars (`<SERVICE>_PORT=tcp://<ip>:<port>`) into every pod.
   A Service named `vllm` therefore sets `VLLM_PORT`, which vLLM reads as its own internal-port setting.
   The engine loaded weights and captured CUDA graphs, then failed about 2 minutes in, every restart.
   Fix: `enableServiceLinks: false` in the pod spec. The same bug would hit EKS.
2. **Image store.** k3s runs its own containerd, separate from Docker, so the vLLM image is imported
   with `docker save | k3s ctr images import` instead of pulled again.

What I expected to be hard was not: k3s auto-detected the nvidia runtime and created the `nvidia`
RuntimeClass, the CUDA smoke test passed first try, and device plugin v0.20.1 logged
`Detected platform: wsl` and advertised `nvidia.com/gpu: 1` (WSL2 support landed in v0.19.1).

## Results

- Pod to Ready in 2m03s. Engine init 89.6 s, of which torch.compile 0.48 s: the compile cache written by the
  Docker runs was reused through the hostPath volume.
- KV cache 9.23 GiB for Qwen3-1.7B at `--gpu-memory-utilization 0.85`.

## Known local limitations

- Cache volumes are `hostPath` with hard-coded `/home/tamms/...` paths. Helm will template these.
- One GPU, so the Deployment uses `strategy: Recreate`: a rollout has downtime instead of an OOM.
- On WSL2 the device plugin reports the GPU as a single `all` device. Fine for one GPU; no per-GPU UUIDs or health checks.
- Windows keeps about 1.5 GB of the 16 GB for the display.
- The host is a desktop OS: on 10 Nov a Microsoft Store update closed the terminal and shut WSL down mid-session.
