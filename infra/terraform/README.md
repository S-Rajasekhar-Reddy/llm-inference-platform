# Cloud run infrastructure (EKS) — plan only for now

One short GPU run on AWS (week 3): VPC, EKS and Karpenter. The budget and the weights bucket are in a
separate stack, [`infra/billing`](../billing/), applied first and kept after this one is destroyed.
Nothing here has been applied yet; `make tf-plan` shows what would be created. The run itself
(checklist, cost model, teardown order) is in [`docs/cloud-run.md`](../../docs/cloud-run.md).

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars   # fill in owner, your IP, email
make tf-init
make tf-plan          # read-only AWS calls; writes infra/terraform/tfplan
```

Needs Terraform >= 1.6 and AWS credentials for the target account (`AWS_PROFILE=...`).

## What it creates

| File | Resources | Notes |
|---|---|---|
| [`main.tf`](main.tf) | VPC (3 AZs, one NAT gateway, free S3 gateway endpoint), EKS with a 2-node `t3.large` Bottlerocket system group, Karpenter IAM + interruption queue + controller | GPU nodes are not in Terraform: Karpenter launches them from [`platform/eks/karpenter-gpu.yaml`](../../platform/eks/karpenter-gpu.yaml) (g6.xlarge, on-demand, max 4 vCPU = one node, the G/VT quota requested; removed 5 min after going idle). |
| [`../billing/`](../billing/) | Project budget (only costs tagged `project`; alerts at 5, 10, 20 USD + forecast), weights bucket, read policy | Separate state: destroying the cluster keeps the budget, so late charges still alert. Decision D9: weights from S3 (via the gateway endpoint, not the NAT). |
| [`providers.tf`](providers.tf) | `default_tags`: `owner`, `project`, `managed-by` | Karpenter-launched instances get the same tags from the EC2NodeClass. |

The EKS API is public but limited to `api_allowed_cidrs` (set your own /32). State is local and git-ignored.

## Cost of the run

About $0.33/h with no GPU node and $1.14/h with one; the planned run is roughly $3–5. Prices,
assumptions and how the run's cost is kept separate from the rest of the account:
[`docs/cloud-run.md`](../../docs/cloud-run.md#cost-model-us-east-1-on-demand-checked-23-nov-2026).
`make cloud-cost` estimates live spend during the run; `make cloud-leftovers` checks nothing is left.
