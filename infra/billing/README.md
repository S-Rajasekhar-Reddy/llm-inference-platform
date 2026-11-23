# Billing stack: project budget and weights bucket

Applied once before the cloud run and kept until the month ends, in its own local state, so
destroying the cluster (`infra/terraform`) does not delete the budget.

| Resource | Why |
|---|---|
| Budget, $20/month, only costs tagged `project=llm-inference-platform` | Emails at $5, $10, $20 actual and when the forecast passes $20. Needs `project` active as a cost allocation tag; set `budget_scope = "account"` if the account runs nothing else. |
| S3 bucket for model weights + read policy | Weights are uploaded before the run; GPU nodes read them through the VPC's S3 gateway endpoint. Being billed (cents) also makes the `project` tag key appear for activation. |

```bash
cp infra/billing/terraform.tfvars.example infra/billing/terraform.tfvars   # owner, alert email
make billing-plan
terraform -chdir=infra/billing apply tfplan
terraform -chdir=infra/billing output upload_weights                        # run the printed command
```

Destroy at the end of the month, after the last line items of the run have arrived:
`terraform -chdir=infra/billing destroy`.
