# Monitoring: Prometheus, Grafana, GPU metrics, alerts

One dashboard answers three questions: **are users waiting, is the GPU the bottleneck, is it time to scale.**

```bash
make monitoring-up                 # kube-prometheus-stack 93.3.0 + nvidia_gpu_exporter 1.19.0, namespace "monitoring"
make up-local                      # the vLLM release now also ships a ServiceMonitor, PrometheusRule and dashboard
make monitoring-status             # scrape targets (vllm, nvidia-gpu-exporter) and any VLLM* alerts
make grafana                       # admin password + port-forward; open "vLLM inference platform"
make alert-test ALERT=ttft         # or queue / idle: force the alert to fire, then restore thresholds
```

## What runs where

| Piece | Source | Notes |
|---|---|---|
| Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter | [`kube-prometheus-stack-values.yaml`](kube-prometheus-stack-values.yaml) | k3s does not expose etcd, scheduler, controller-manager or kube-proxy metrics, so those scrapes and their rules are off (otherwise they show as permanently down). Prometheus selects ServiceMonitors and rules from every release. 2-day retention. |
| GPU utilisation, memory, power, temperature | [`nvidia-gpu-exporter-values.yaml`](nvidia-gpu-exporter-values.yaml) | Runs under the `nvidia` RuntimeClass and requests **no** `nvidia.com/gpu`: there is one GPU and vLLM holds it. NVIDIA's DCGM exporter does not support WSL2; it replaces this on EKS. |
| vLLM scrape, alerts, dashboard | [`charts/vllm`](../../charts/vllm/README.md) `monitoring.*` | Metric names checked against the v0.33.0 source (`vllm/v1/metrics/loggers.py`). Dashboard JSON: [`charts/vllm/dashboards/vllm-platform.json`](../../charts/vllm/dashboards/vllm-platform.json). |

## Alerts

| Alert | Fires when | Forced test |
|---|---|---|
| `VLLMTimeToFirstTokenHigh` | p95 TTFT above `ttft.sloSeconds` (1 s) for 5 min | SLO lowered to 1 ms for 1 min, 8 concurrent requests |
| `VLLMOutOfCapacity` | waiting requests per pod above `queue.threshold` (5) at `queue.maxReplicas` for 2 min | threshold 0 for 30 s, 512 concurrent requests (above vLLM's default 256 running) |
| `VLLMIdleGPU` | a ready pod finished no requests and runs none for 30 min | 1-min window for 2 min, no traffic |

`alert-test` lowers one alert's numbers with `helm upgrade` (only the PrometheusRule changes, the vLLM pod is not
restarted), drives load through a port-forward with [`loadgen.py`](loadgen.py), polls the Prometheus API (a short port-forward to its pod
per query, see [`prom-api.sh`](prom-api.sh)) until the alert is `firing`, then restores the committed values even if it fails or is interrupted.
