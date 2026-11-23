# Cloud run runbook (AWS EKS, one g6.xlarge)

One short, time-boxed run that proves the same Helm chart serves on EKS with a Karpenter-launched
NVIDIA L4, and measures cloud throughput and cost per 1M output tokens. This page is the plan, the
cost model and the checklist. Nothing here runs without a person at the keyboard.

## What the run can and cannot show

- **Can:** Karpenter adds a GPU node from zero when a GPU pod is pending and removes it 5 min after
  the pod goes away; the same chart and dashboards work on EKS; L4 throughput and cost per 1M tokens
  next to the laptop numbers.
- **Cannot:** scaling out to a second GPU node. The G/VT quota is 4 vCPU and the NodePool limit is
  `cpu: 4`, so at most one g6.xlarge can exist. Adding capacity with a second GPU node needs 8 vCPU.

## Cost model (us-east-1 on-demand, checked 23 Nov 2026)

| Item | Price | Runs when |
|---|---|---|
| g6.xlarge (1x L4, 4 vCPU) | $0.8048/h | only while a GPU pod needs it (Karpenter) |
| EKS control plane | $0.10/h | apply → destroy. **$0.60/h if the version is in extended support** (`make cloud-preflight` checks) |
| 2x t3.large system nodes | 2 x $0.0832/h | apply → destroy |
| NAT gateway + its public IPv4 | $0.045/h + $0.005/h | apply → destroy |
| NAT data processed | $0.045/GB | image pulls (vLLM image ~10 GB). Weights skip the NAT via the free S3 gateway endpoint |
| EBS gp3 (GPU node 100 GB, system nodes) | $0.08/GB-month | negligible for hours |
| KMS key (EKS secrets), CloudWatch logs, S3 storage | cents | KMS at most ~$1 for the month |

- **Burn rate:** about **$0.33/h** with no GPU node, about **$1.14/h** with the GPU node.
- **Planned run:** about 2.75 h of cluster and 1.6 h of GPU node (two launches) is roughly **$3–5**
  including ~$0.50 of NAT data.
- **What the $20 budget buys:** about 17 h of everything running. The real risk is not the run but
  something left running: a forgotten cluster without the GPU is ~$8/day, with it ~$27/day.

## Keeping the run's cost separate from the rest of the account

The account is shared, so the account total is the wrong number. Two views:

1. **Live, during the run: `make cloud-cost`.** Finds the run's resources by tag (`project`,
   `karpenter.sh/discovery`, `eks:cluster-name`), multiplies their age by the prices above, and shows
   spend so far, burn rate, budget left and hours left. It is an estimate, but it is current;
   billing data is hours behind.
2. **Billed, the next day: Cost Explorer filtered by the `project` tag**, and the budget in
   [`infra/billing`](../infra/billing/), which only counts costs tagged `project=llm-inference-platform`.
   For that the tag must be an **active cost allocation tag**:
   - Only a standalone account or the organisation's management (payer) account can activate it;
     `make cloud-preflight` says which this account is.
   - The key only appears on the Cost allocation tags page after a tagged resource has been billed
     (up to 24 h), and activation takes up to another 24 h. Hence infra/billing (budget + weights
     bucket) is applied the day before.
   - Fallback if the tag can't be activated in time: in Cost Explorer, filter region `us-east-1` and
     usage types containing `g6.xlarge`, `AmazonEKS` and `NatGateway`. That isolates the run only if
     nothing else in the account uses EKS, NAT gateways or g6 in us-east-1; check last month first.

The budget lives in its own Terraform state (`infra/billing`), so `terraform destroy` of the cluster
does not delete it and late charges still alert. Alerts at $5, $10 and $20 actual, plus a forecast
alert. Budgets are a **backstop, not a brake**: they are evaluated a few times a day on lagging data.

## Day before (no cluster, no GPU)

- [ ] Patch applied, `make lint` and `make tf-init` pass.
- [ ] `make cloud-preflight`: G/VT quota ≥ NodePool limit (4), g6.xlarge offered in the AZs
      Terraform uses, EKS version in standard support, no leftovers. Paste the output into the build log.
- [ ] `make billing-plan`, then `terraform -chdir=infra/billing apply tfplan` (budget + empty bucket; free).
- [ ] Upload weights: the `upload_weights` command from `terraform -chdir=infra/billing output`.
- [ ] Billing > Cost allocation tags: activate `project` as soon as it appears (or ask the payer admin).
- [ ] `make tf-plan`: write down the `Plan: N to add` line.
- [ ] Built and tested locally: `values-cloud.yaml`, `make up-cloud` / `make down-cloud`, and the
      benchmark script (the same script the laptop numbers come from).
- [ ] Phone alarm for the hard stop.

## Run day (IST, 08:00–11:00 build block)

| Time | Stage | Done when | If not |
|---|---|---|---|
| 08:00 | Preflight: `make cloud-preflight`, `make cloud-cost` (expect nothing running) | all OK | stop, no apply |
| 08:05 | `terraform -chdir=infra/terraform apply` (~15–20 min) | apply complete | `terraform destroy`, stop |
| 08:25 | **A. Cluster checks:** nodes Ready, Karpenter running, monitoring up, `make cloud-cost` lists the EKS cluster, both system nodes and the NAT (proves tags reach them) | all listed | fix tags or stop; cluster costs $0.33/h |
| 08:40 | **B. GPU test run:** apply the NodePool, `make up-cloud`, smoke test. Record cold start (node launch, image pull, weights, model load). Then `make down-cloud` and **watch the GPU node disappear within ~6 min** | node gone, `make cloud-cost` burn rate back to ~$0.33/h | **teardown now**; the scale-to-zero path is the main cost safety |
| 09:15 | **C. Benchmark:** `make up-cloud`, warm-up, 3 repeats, export Grafana snapshots and Prometheus queries, `make cloud-cost` | results files written | keep what you have |
| 10:30 | **D. Teardown, whatever state C is in** (order matters, below) | `make cloud-leftovers` exits 0 | delete what it lists, run it again |

**Hard stop:** teardown starts at 10:30 even mid-benchmark. Never leave the GPU node running
unattended (no breaks with it up). Stuck for 30 min on any stage: tear down and retry another day.

### Teardown order

Terraform cannot see the GPU node (Karpenter launched it). Destroying the cluster first orphans the
instance, which keeps billing, and the VPC delete then hangs on its network interface.

1. `make down-cloud` (vLLM), then `kubectl delete nodepool gpu`.
2. `kubectl get nodeclaims` until empty, and check the g6 instance is terminated:
   `aws ec2 describe-instances --filters Name=tag:karpenter.sh/discovery,Values=llm-inference Name=instance-state-name,Values=running`.
3. No Service of type LoadBalancer exists (`kubectl get svc -A | grep LoadBalancer` is empty).
4. `terraform -chdir=infra/terraform destroy` (~15 min).
5. `make cloud-leftovers` until it reports nothing billable, then `make cloud-cost` once more.

## After

- [ ] Same evening and next morning: `make cloud-leftovers` (exit 0).
- [ ] Next day: Cost Explorer, tag `project` (or the fallback filter), grouped by service. Compare
      with the `make cloud-cost` estimate and record both in the build log.
- [ ] Two days later: check again for late line items. Keep infra/billing until the month ends.
