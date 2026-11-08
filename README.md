# llm-inference-platform

Production-style LLM serving on Kubernetes with vLLM: autoscaling, observability and published latency/cost benchmarks.

**Status:** Week 1, in progress. Built in public; progress is logged below.

## Roadmap
- [ ] vLLM serving an open-weight model
- [ ] Kubernetes + Helm deployment, provisioned with Terraform
- [ ] Autoscaling on request queue depth
- [ ] Prometheus/Grafana dashboards: time-to-first-token, p95 latency, throughput, cost per 1M tokens
- [ ] Benchmark write-up

## Progress log
- 2026-11-08: Repo created.
