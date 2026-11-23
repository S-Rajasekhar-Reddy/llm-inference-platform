#!/usr/bin/env python3
"""After `terraform destroy`: list anything from the run that still exists (and may still bill).

  make cloud-leftovers       # right after destroy, and again the next morning

Terraform only deletes what is in its state. Karpenter launches the GPU node and its volume,
creates an instance profile, and Kubernetes can create load balancers; none of those are in
the state. This checks them by name and by tag. Exits 1 if anything billable is left.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from awscli import NAME, PROJECT, REGION, AwsError, aws, require_cli  # noqa: E402

billable, info = [], []


def tagged_filters():
    return (f"Name=tag:project,Values={PROJECT}", f"Name=tag:karpenter.sh/discovery,Values={NAME}",
            f"Name=tag:eks:cluster-name,Values={NAME}")


def main():
    require_cli()
    account = aws("sts", "get-caller-identity")["Account"]

    if NAME in aws("eks", "list-clusters")["clusters"]:
        billable.append(f"EKS cluster {NAME} ($0.10/h)")

    seen = set()
    for f in tagged_filters():
        res = aws("ec2", "describe-instances", "--filters", f,
                  "Name=instance-state-name,Values=pending,running,stopping,stopped")
        for r in res["Reservations"]:
            for i in r["Instances"]:
                if i["InstanceId"] not in seen:
                    seen.add(i["InstanceId"])
                    billable.append(f"instance {i['InstanceId']} {i['InstanceType']} {i['State']['Name']}")

    vols = set()
    for f in tagged_filters():
        for v in aws("ec2", "describe-volumes", "--filters", f)["Volumes"]:
            if v["VolumeId"] not in vols:
                vols.add(v["VolumeId"])
                billable.append(f"EBS volume {v['VolumeId']} {v['Size']} GB {v['State']}")

    for n in aws("ec2", "describe-nat-gateways", "--filter", f"Name=tag:project,Values={PROJECT}",
                 "Name=state,Values=pending,available,deleting")["NatGateways"]:
        billable.append(f"NAT gateway {n['NatGatewayId']} {n['State']}")

    for a in aws("ec2", "describe-addresses", "--filters", f"Name=tag:project,Values={PROJECT}")["Addresses"]:
        billable.append(f"Elastic IP {a['PublicIp']} ($0.005/h)")

    vpcs = [v["VpcId"] for v in aws("ec2", "describe-vpcs", "--filters", f"Name=tag:project,Values={PROJECT}")["Vpcs"]]
    for vpc in vpcs:
        info.append(f"VPC {vpc} still exists (free, but blocks a clean destroy if something is attached)")
    lbs = aws("elbv2", "describe-load-balancers")["LoadBalancers"]
    for lb in lbs:
        if lb["VpcId"] in vpcs or NAME in lb["LoadBalancerName"]:
            billable.append(f"load balancer {lb['LoadBalancerName']} ({lb['Type']})")

    queues = (aws("sqs", "list-queues", "--queue-name-prefix", f"Karpenter-{NAME}", check=False) or {}).get("QueueUrls", [])
    info += [f"SQS queue {q} (free at this volume)" for q in queues]

    groups = aws("logs", "describe-log-groups", "--log-group-name-prefix", f"/aws/eks/{NAME}")["logGroups"]
    billable += [f"log group {g['logGroupName']} ({g.get('storedBytes', 0) / 1e6:.1f} MB stored)" for g in groups]

    alias = aws("kms", "describe-key", "--key-id", f"alias/eks/{NAME}", check=False)
    if alias:
        state = alias["KeyMetadata"]["KeyState"]
        (info if state == "PendingDeletion" else billable).append(f"KMS key alias/eks/{NAME}: {state}")

    profiles = aws("iam", "list-instance-profiles", region=None)["InstanceProfiles"]
    info += [f"IAM instance profile {p['InstanceProfileName']} (free; Karpenter-created)"
             for p in profiles if NAME in p["InstanceProfileName"]]

    bucket = f"{NAME}-weights-{account}"
    if aws("s3api", "get-bucket-location", "--bucket", bucket, check=False):
        info.append(f"S3 bucket {bucket} (infra/billing keeps it on purpose; cents per month)")

    print(f"Leftovers check, region {REGION}, cluster {NAME}, tag project={PROJECT}\n")
    for line in billable:
        print(f"  [BILLS] {line}")
    for line in info:
        print(f"  [info]  {line}")
    if not billable:
        print("  Nothing billable left from the cluster stack." if not info else
              "\n  Nothing billable left from the cluster stack.")
        return
    print("\nDelete these (or re-run terraform destroy), then run this again.")
    sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except AwsError as e:
        sys.exit(f"aws error: {e}")
