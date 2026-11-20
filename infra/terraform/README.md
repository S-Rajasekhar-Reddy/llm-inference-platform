# Cloud run infrastructure (EKS) — plan only for now

One short GPU run on AWS (week 3): VPC, EKS, Karpenter, an S3 bucket for model weights, and a
cost budget. Nothing here has been applied yet; `make tf-plan` shows what would be created.

```bash
cp infra/terraform/terraform.tfvars.example infra/terraform/terraform.tfvars   # fill in owner, your IP, email
make tf-init
make tf-plan          # read-only AWS calls; writes infra/terraform/tfplan
```

Needs Terraform >= 1.6 and AWS credentials for the target account (`AWS_PROFILE=...`).

## What it creates

| File | Resources | Notes |
|---|---|---|
| [`main.tf`](main.tf) | VPC (3 AZs, one NAT gateway), EKS with a 2-node `t3.large` Bottlerocket system group, Karpenter IAM + interruption queue + controller | GPU nodes are not in Terraform: Karpenter launches them from [`platform/eks/karpenter-gpu.yaml`](../../platform/eks/karpenter-gpu.yaml) (g6.xlarge, on-demand, max 4 vCPU = one node, the G/VT quota requested; removed 5 min after going idle). |
| [`s3.tf`](s3.tf) | Weights bucket (private, encrypted) and a read policy for GPU nodes | Decision D9: weights come from S3, not Hugging Face, so cold start measures loading. |
| [`budget.tf`](budget.tf) | Monthly budget with email alerts at 5, 10 and 20 USD actual, plus a forecast alert | Created with everything else, so it exists before the first GPU node. |
| [`providers.tf`](providers.tf) | `default_tags`: `owner`, `project`, `managed-by` | Karpenter-launched instances get the same tags from the EC2NodeClass. |

The EKS API is public but limited to `api_allowed_cidrs` (set your own /32). State is local and git-ignored.

## Cost of the run (estimates, us-east-1 on-demand)

| Item | Rate | Note |
|---|---|---|
| EKS control plane | about $0.10/hr | |
| 2x t3.large system nodes | about $0.17/hr | |
| NAT gateway | about $0.045/hr + data | |
| g6.xlarge (1x L4) | about $0.80/hr | only while a GPU pod needs it |

At about $1.10/hr with one GPU node, a 5-hour run stays well inside the $20 cap. Check current
prices before applying; these are planning numbers, not measured spend.
