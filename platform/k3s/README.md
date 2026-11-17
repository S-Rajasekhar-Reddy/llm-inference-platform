# Local platform: k3s on WSL2

Cluster-level pieces for running the platform on a single-node k3s cluster inside WSL2
(RTX 5080 Laptop GPU, 16 GB). vLLM itself is deployed by the Helm chart in [`charts/vllm/`](../../charts/vllm/);
the same chart runs on EKS in week 3.

| File | What it does |
|---|---|
| `00-gpu-smoke-test.yaml` | Runs `nvidia-smi` once under the `nvidia` RuntimeClass (`make gpu-smoke`). If this prints the GPU, the runtime plumbing works. |
| `10-nvidia-device-plugin.yaml` | NVIDIA device plugin v0.20.1, modified to run under the `nvidia` RuntimeClass (k3s keeps runc as default). Time-slicing config advertises the one GPU as `nvidia.com/gpu: 2`, so two vLLM replicas can share it (no memory isolation). Applied by `make up-local`. |

## Run it

Prerequisites: WSL2 with systemd, Docker Engine, the NVIDIA Container Toolkit installed *before* k3s starts
(so k3s registers the runtime), Helm and make (`sudo apt install make`).

```bash
make k3s-install        # one time; then: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
make up-local           # preflight, device plugin, image import from Docker, helm upgrade --install, wait for Ready
make smoke-local        # port-forward + one completion
make down-local         # remove the release; k3s, the device plugin and the caches stay
```

`make up-local` imports the pinned vLLM image from Docker into k3s's own containerd
(`docker save | k3s ctr images import`), so it is not downloaded twice.

## What broke and how it was fixed (11 Nov 2026, plain manifests; now in the chart)

1. **vLLM crashed at startup with `ValueError: VLLM_PORT 'tcp://10.43.211.50:8000' appears to be a URI`.**
   Kubernetes injects legacy service-link env vars (`<SERVICE>_PORT=tcp://<ip>:<port>`) into every pod.
   A Service named `vllm` therefore sets `VLLM_PORT`, which vLLM reads as its own internal-port setting.
   The engine loaded weights and captured CUDA graphs, then failed about 2 minutes in, every restart.
   Fix: `enableServiceLinks: false` in the pod spec, now hard-coded in the chart. The same bug would hit EKS.
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

- Cache volumes are `hostPath` on the WSL2 filesystem; `make up-local` fills the paths from `$HOME`.
- One GPU, so the Deployment uses `strategy: Recreate`: a rollout has downtime instead of an OOM.
- On WSL2 the device plugin reports the GPU as a single `all` device. Fine for one GPU; no per-GPU UUIDs or health checks.
- Windows keeps about 1.5 GB of the 16 GB for the display.
- The host is a desktop OS: on 10 Nov a Microsoft Store update closed the terminal and shut WSL down mid-session.
