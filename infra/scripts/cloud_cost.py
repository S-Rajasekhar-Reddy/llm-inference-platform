#!/usr/bin/env python3
"""Live cost estimate of the cloud run, from what is running right now.

  make cloud-cost            # run it every 30 min during the run, and once after destroy

Billing data (Cost Explorer, Budgets) lags by hours, so during the run the only up-to-date
number is runtime x price. This finds the run's resources (by the project tag and the cluster
tags Karpenter and EKS add), multiplies their age by the us-east-1 on-demand prices below, and
shows how much of the budget is left and how many hours that is at the current burn rate.
It is an estimate: Cost Explorer, filtered by the project tag, is the record a day later.
"""
import datetime as dt
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from awscli import NAME, PROJECT, REGION, AwsError, aws, require_cli  # noqa: E402

BUDGET = float(os.environ.get("BUDGET_USD", "20"))

# us-east-1 on-demand prices (USD), checked 23 Nov 2026. Update if the region or prices change.
PRICE = {
    "eks_hour": 0.10,          # standard support; extended support is 0.60
    "nat_hour": 0.045,
    "nat_gb": 0.045,           # per GB processed by the NAT gateway
    "ipv4_hour": 0.005,        # per public IPv4 address
    "gp3_gb_month": 0.08,
    "instance_hour": {"g6.xlarge": 0.8048, "t3.large": 0.0832},
}
HOURS_PER_MONTH = 730

now = dt.datetime.now(dt.timezone.utc)


def hours_since(ts):
    t = ts if isinstance(ts, dt.datetime) else dt.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    return max(0.0, (now - t).total_seconds() / 3600)


def run_instances():
    """Instances of this run, found by any of the three tags they can carry."""
    found = {}
    for f in (f"Name=tag:project,Values={PROJECT}",
              f"Name=tag:karpenter.sh/discovery,Values={NAME}",
              f"Name=tag:eks:cluster-name,Values={NAME}"):
        res = aws("ec2", "describe-instances", "--filters", f, "Name=instance-state-name,Values=pending,running")
        for r in res["Reservations"]:
            for i in r["Instances"]:
                found[i["InstanceId"]] = i
    return list(found.values())


def main():
    require_cli()
    rows, hourly = [], 0.0

    cluster = aws("eks", "describe-cluster", "--name", NAME, check=False)
    if cluster:
        h = hours_since(cluster["cluster"]["createdAt"])
        rows.append(("EKS control plane", f"{h:.2f} h", h * PRICE["eks_hour"]))
        hourly += PRICE["eks_hour"]

    for i in run_instances():
        itype = i["InstanceType"]
        rate = PRICE["instance_hour"].get(itype)
        h = hours_since(i["LaunchTime"])
        if rate is None:
            rows.append((f"{itype} {i['InstanceId']} (PRICE UNKNOWN: add it)", f"{h:.2f} h", 0.0))
            continue
        rows.append((f"{itype} {i['InstanceId']}", f"{h:.2f} h", h * rate))
        hourly += rate

    nats = aws("ec2", "describe-nat-gateways", "--filter", f"Name=tag:project,Values={PROJECT}",
               "Name=state,Values=pending,available")["NatGateways"]
    for n in nats:
        h = hours_since(n["CreateTime"])
        gb = 0.0
        stats_from = n["CreateTime"]
        for metric in ("BytesInFromSource", "BytesInFromDestination"):
            s = aws("cloudwatch", "get-metric-statistics", "--namespace", "AWS/NATGateway",
                    "--metric-name", metric, "--dimensions", f"Name=NatGatewayId,Value={n['NatGatewayId']}",
                    "--start-time", str(stats_from), "--end-time", now.isoformat(),
                    "--period", "3600", "--statistics", "Sum", check=False) or {}
            gb += sum(p["Sum"] for p in s.get("Datapoints", [])) / 1e9
        rows.append((f"NAT gateway {n['NatGatewayId']}", f"{h:.2f} h", h * PRICE["nat_hour"]))
        rows.append(("NAT data processed", f"{gb:.1f} GB", gb * PRICE["nat_gb"]))
        rows.append(("Public IPv4 (NAT)", f"{h:.2f} h", h * PRICE["ipv4_hour"]))
        hourly += PRICE["nat_hour"] + PRICE["ipv4_hour"]

    vols = {}
    for f in (f"Name=tag:project,Values={PROJECT}", f"Name=tag:karpenter.sh/discovery,Values={NAME}",
              f"Name=tag:eks:cluster-name,Values={NAME}"):
        for v in aws("ec2", "describe-volumes", "--filters", f)["Volumes"]:
            vols[v["VolumeId"]] = v
    if vols:
        gb_h = sum(v["Size"] * hours_since(v["CreateTime"]) for v in vols.values())
        cost = gb_h * PRICE["gp3_gb_month"] / HOURS_PER_MONTH
        size = sum(v["Size"] for v in vols.values())
        rows.append((f"EBS volumes ({len(vols)}, {size} GB)", f"{gb_h:.0f} GB-h", cost))
        hourly += size * PRICE["gp3_gb_month"] / HOURS_PER_MONTH

    print(f"Cloud run cost estimate, {now:%Y-%m-%d %H:%M} UTC, region {REGION}, cluster {NAME}\n")
    if not rows:
        print("Nothing from the run is running. (After a destroy, confirm with make cloud-leftovers.)")
    width = max([len(r[0]) for r in rows] + [10])
    for what, qty, cost in rows:
        print(f"  {what:<{width}}  {qty:>12}  ${cost:6.2f}")
    total = sum(r[2] for r in rows)
    print(f"  {'':<{width}}  {'':>12}  -------")
    print(f"  {'This run so far (estimate)':<{width}}  {'':>12}  ${total:6.2f}")
    print(f"\n  Burn rate now: ${hourly:.2f}/h. Left of the ${BUDGET:.0f} budget: ${BUDGET - total:.2f}"
          + (f", about {(BUDGET - total) / hourly:.1f} h at this rate." if hourly else "."))
    print("  Not counted: earlier runs this month, KMS key (at most ~$1/month), CloudWatch logs, S3 storage (cents).")


if __name__ == "__main__":
    try:
        main()
    except AwsError as e:
        sys.exit(f"aws error: {e}")
