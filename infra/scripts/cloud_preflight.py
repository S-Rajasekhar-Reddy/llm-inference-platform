#!/usr/bin/env python3
"""Read-only checks before the cloud run. Creates nothing.

  make cloud-preflight

Checks: identity, whether this account can activate cost allocation tags, the G/VT quota vs the
Karpenter NodePool limit, g6.xlarge in the AZs Terraform will use, the EKS version's support
status, the project budget and tag, the weights bucket, and that nothing from a previous run is
still up. Exits 1 if any FAIL.
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from awscli import NAME, PROJECT, REGION, AwsError, aws, require_cli  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
NODEPOOL = ROOT / "platform/eks/karpenter-gpu.yaml"
TF = ROOT / "infra/terraform"
GPU_TYPE = "g6.xlarge"
GVT_QUOTA = "L-DB2E81BA"  # Running On-Demand G and VT instances (vCPUs)

results = []


def report(status, check, detail):
    results.append(status)
    print(f"[{status:4}] {check}: {detail}")


def tf_var(name, default):
    """Value from infra/terraform/terraform.tfvars if set there, else the default in variables.tf."""
    pat = re.compile(rf'^\s*{name}\s*=\s*"([^"]+)"', re.M)
    for f in (TF / "terraform.tfvars", TF / "variables.tf"):
        if f.exists():
            text = f.read_text()
            if f.name == "variables.tf":
                block = re.search(rf'variable "{name}" \{{(.*?)\n\}}', text, re.S)
                text = block.group(1).replace("default", name) if block else ""
            m = pat.search(text)
            if m:
                return m.group(1)
    return default


def main():
    require_cli()
    ident = aws("sts", "get-caller-identity")
    account = ident["Account"]
    report("INFO", "identity", f"{ident['Arn']} (account {account}), region {REGION}")

    # 1. Can this account activate the project tag for cost allocation?
    org = aws("organizations", "describe-organization", check=False)
    if org is None:
        report("OK", "billing", "standalone account: you can activate the project tag yourself")
    elif org["Organization"]["MasterAccountId"] == account:
        report("OK", "billing", "management account: you can activate the project tag yourself")
    else:
        report("WARN", "billing", "member account: only the payer account can activate cost allocation "
               "tags. Ask its admin, or use budget_scope = \"account\" and the Cost Explorer filters in docs/cloud-run.md")

    tags = aws("ce", "list-cost-allocation-tags", "--tag-keys", "project", region="us-east-1", check=False)
    found = (tags or {}).get("CostAllocationTags", [])
    if not found:
        report("WARN", "cost tag", "tag key 'project' not visible in billing yet: it appears up to 24 h after a "
               "tagged resource is billed (apply infra/billing and upload the weights), then activate it")
    elif found[0]["Status"] != "Active":
        report("WARN", "cost tag", "tag key 'project' found but Inactive: Billing > Cost allocation tags > Activate "
               "(up to 24 h)")
    else:
        report("OK", "cost tag", "project is an active cost allocation tag")

    budgets = aws("budgets", "describe-budgets", "--account-id", account, region="us-east-1", check=False) or {}
    mine = [b for b in budgets.get("Budgets", []) if b["BudgetName"].startswith(f"{NAME}-")]
    if mine:
        for b in mine:
            spent = b.get("CalculatedSpend", {}).get("ActualSpend", {}).get("Amount", "?")
            report("OK", "budget", f"{b['BudgetName']}: limit {b['BudgetLimit']['Amount']} USD, "
                   f"this month so far {float(spent):.2f} USD (billing data lags by hours)")
    else:
        report("FAIL", "budget", "no budget yet: apply infra/billing before the run")

    # 2. Quota vs NodePool limit vs instance size
    vcpus = aws("ec2", "describe-instance-types", "--instance-types", GPU_TYPE)["InstanceTypes"][0]["VCpuInfo"]["DefaultVCpus"]
    m = re.search(r"^\s*limits:\s*\n\s*cpu:\s*(\d+)", NODEPOOL.read_text(), re.M)
    limit = int(m.group(1)) if m else None
    try:
        quota = aws("service-quotas", "get-service-quota", "--service-code", "ec2", "--quota-code", GVT_QUOTA)["Quota"]["Value"]
    except AwsError as e:
        quota = None
        report("FAIL", "quota", f"could not read G/VT quota: {e}")
    if quota is not None:
        ok = limit is not None and vcpus <= limit <= quota
        report("OK" if ok else "FAIL", "quota",
               f"G/VT on-demand quota {quota:g} vCPU, NodePool limit {limit} vCPU, {GPU_TYPE} = {vcpus} vCPU "
               f"-> at most {int(min(quota, limit or 0) // vcpus)} GPU node(s)")

    # 3. g6.xlarge in the AZs Terraform picks (first 3 opt-in-not-required AZs)
    azs = aws("ec2", "describe-availability-zones", "--filters", "Name=opt-in-status,Values=opt-in-not-required")
    first3 = sorted(z["ZoneName"] for z in azs["AvailabilityZones"])[:3]
    offers = aws("ec2", "describe-instance-type-offerings", "--location-type", "availability-zone",
                 "--filters", f"Name=instance-type,Values={GPU_TYPE}")
    offered = {o["Location"] for o in offers["InstanceTypeOfferings"]}
    usable = [z for z in first3 if z in offered]
    report("OK" if usable else "FAIL", "GPU AZs",
           f"Terraform uses {', '.join(first3)}; {GPU_TYPE} offered in {', '.join(usable) or 'none of them'}")

    # 4. EKS version support status (extended support = $0.60/hr control plane)
    version = tf_var("kubernetes_version", "?")
    vers = aws("eks", "describe-cluster-versions", "--cluster-versions", version, check=False) or {}
    info = (vers.get("clusterVersions") or [{}])[0]
    status = info.get("versionStatus") or info.get("status") or "unknown"
    end = info.get("endOfStandardSupportDate", "?")
    ok = status.upper() == "STANDARD_SUPPORT"
    report("OK" if ok else "FAIL", "EKS version", f"{version}: {status}, standard support ends {end}")

    # 4b. The EKS API only accepts api_allowed_cidrs: this machine's public IP must be in it, or
    #     kubectl (and make cloud-teardown) stop working. Home IPs can change between days.
    import ipaddress
    import urllib.request
    try:
        ip = urllib.request.urlopen("https://checkip.amazonaws.com", timeout=10).read().decode().strip()
    except OSError as e:
        ip = None
        report("WARN", "API access", f"could not read this machine's public IP: {e}")
    tfvars = TF / "terraform.tfvars"
    cidrs = re.findall(r'"(\d+\.\d+\.\d+\.\d+/\d+)"', re.search(r"api_allowed_cidrs\s*=\s*\[(.*?)\]", tfvars.read_text(), re.S).group(1)) \
        if tfvars.exists() and "api_allowed_cidrs" in tfvars.read_text() else []
    if ip:
        inside = any(ipaddress.ip_address(ip) in ipaddress.ip_network(c, strict=False) for c in cidrs)
        report("OK" if inside else "FAIL", "API access",
               f"public IP {ip} {'is' if inside else 'is NOT'} in api_allowed_cidrs {cidrs or '(not set)'}"
               + ("" if inside else f": set api_allowed_cidrs = [\"{ip}/32\"] in infra/terraform/terraform.tfvars"))

    # 5. Weights uploaded?
    bucket = f"{NAME}-weights-{account}"
    objs = aws("s3api", "list-objects-v2", "--bucket", bucket, "--max-items", "1", check=False)
    if objs is None:
        report("WARN", "weights", f"bucket {bucket} not found: apply infra/billing")
    elif not objs.get("Contents"):
        report("WARN", "weights", f"bucket {bucket} is empty: run the upload command from `terraform -chdir=infra/billing output`")
    else:
        report("OK", "weights", f"bucket {bucket} has objects")

    # 6. Nothing from a previous run still up
    clusters = aws("eks", "list-clusters")["clusters"]
    running = aws("ec2", "describe-instances", "--filters", f"Name=tag:project,Values={PROJECT}",
                  "Name=instance-state-name,Values=pending,running,stopping,stopped")
    n = sum(len(r["Instances"]) for r in running["Reservations"])
    if NAME in clusters or n:
        report("WARN", "leftovers", f"cluster {NAME} exists: {NAME in clusters}; tagged instances: {n} (make cloud-leftovers)")
    else:
        report("OK", "leftovers", "no cluster and no tagged instances")

    print()
    if "FAIL" in results:
        print("Not ready: fix the FAIL lines first.")
        sys.exit(1)
    print("Ready" + (" (read the WARN lines)" if "WARN" in results else "") + ".")


if __name__ == "__main__":
    main()
