"""Small helpers shared by the cloud-run scripts: call the AWS CLI, read the run's settings."""
import json
import os
import subprocess
import sys

REGION = os.environ.get("AWS_REGION_RUN") or os.environ.get("REGION") or "us-east-1"
NAME = os.environ.get("CLUSTER_NAME") or "llm-inference"
PROJECT = os.environ.get("PROJECT_TAG") or "llm-inference-platform"


class AwsError(RuntimeError):
    pass


def aws(*args, region=REGION, check=True):
    """Run `aws <args> --output json` and return parsed JSON (None for empty output)."""
    cmd = ["aws", *args, "--output", "json"]
    if region:
        cmd += ["--region", region]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        if check:
            raise AwsError(p.stderr.strip() or f"aws {' '.join(args)} failed")
        return None
    out = p.stdout.strip()
    return json.loads(out) if out else None


def require_cli():
    try:
        aws("sts", "get-caller-identity")
    except FileNotFoundError:
        sys.exit("missing: aws CLI v2")
    except AwsError as e:
        sys.exit(f"AWS credentials not working: {e}")
