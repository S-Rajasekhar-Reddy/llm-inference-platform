# vllm Helm chart

vLLM's OpenAI-compatible server, one GPU per pod. The same chart runs on the local k3s cluster
(`values-local.yaml`) and on EKS in week 3 (`values-cloud.yaml`, not written yet).

```bash
make up-local                    # the normal way: preflight, device plugin, image import, then this chart
make lint                        # helm lint + render, no cluster needed
helm template vllm charts/vllm -f charts/vllm/values-local.yaml \
  --set cache.hostPath.huggingface=$HOME/.cache/huggingface --set cache.hostPath.vllm=$HOME/.cache/vllm
```

## Values that matter

| Value | Default | Why |
|---|---|---|
| `image.tag` | `v0.33.0` | Pinned vLLM release; bump deliberately. The Makefile reads it from here. |
| `model.name` | `Qwen/Qwen3-1.7B` | Fast iteration model. `make up-local MODEL=Qwen/Qwen3-8B-FP8` for the main one. |
| `model.maxModelLen` | `8192` | Context length; the KV-cache budget is sized against it. |
| `model.gpuMemoryUtilization` | `0.85` | Share of the GPU vLLM may use. Ignored when `kvCacheMemoryBytes` is set. |
| `model.kvCacheMemoryBytes` | empty | Pins the KV cache in bytes so capacity does not change between cold and warm boots ([vllm#54383](https://github.com/vllm-project/vllm/issues/54383)). Set it for benchmarks. |
| `extraArgs` | `[]` | Any other vLLM flags, e.g. `["--kv-cache-dtype", "fp8"]`. |
| `hfOffline` | `false` (local: `true`) | `HF_HUB_OFFLINE=1`: skip Hugging Face network checks once weights are cached. |
| `runtimeClassName` | empty (local: `nvidia`) | k3s keeps runc as the default runtime, so GPU pods name the nvidia one. |
| `gpu.request` / `gpu.count` | `true` / `1` | Requests `nvidia.com/gpu` from the device plugin. |
| `strategy.type` | `Recreate` | With one GPU a rolling update would start a second pod that cannot fit. |
| `cache.type` | `emptyDir` (local: `hostPath`) | hostPath keeps weights and the torch.compile cache across restarts (cold start ~35 min to ~2.3 min). |
| `probes.startup.failureThreshold` | `120` (x 5 s) | Up to 10 minutes for a cold compile and CUDA graph capture before the pod is restarted. |
| `monitoring.serviceMonitor.enabled` | `false` (local: `true`) | Prometheus scrapes `/metrics` every 15 s. Needs the Prometheus Operator CRDs (`make monitoring-up`); the chart fails with that hint if they are missing. |
| `monitoring.dashboard.enabled` | `false` (local: `true`) | Ships [`dashboards/vllm-platform.json`](dashboards/vllm-platform.json) as a ConfigMap for the Grafana sidecar. |
| `monitoring.alerts.enabled` | `false` (local: `true`) | PrometheusRule with the three alerts below. |
| `monitoring.alerts.ttft.sloSeconds` / `.for` | `1` / `5m` | `VLLMTimeToFirstTokenHigh`: p95 TTFT above the SLO (draft chat SLO, fixed after the saturation run). Also the red line on the TTFT panel. |
| `monitoring.alerts.queue.threshold` / `.maxReplicas` / `.for` | `5` / `1` / `2m` | `VLLMOutOfCapacity`: waiting requests per pod above the threshold while already at max replicas. Keep equal to the KEDA settings. |
| `monitoring.alerts.idle.window` / `.for` | `5m` / `30m` | `VLLMIdleGPU`: a ready pod finished no requests and runs none, i.e. a paid GPU doing nothing. |

Always on, not configurable: `enableServiceLinks: false`. A Service named `vllm` otherwise injects
`VLLM_PORT=tcp://...` into the pod, which vLLM reads as its own setting and crashes (found on k3s, 11 Nov).
