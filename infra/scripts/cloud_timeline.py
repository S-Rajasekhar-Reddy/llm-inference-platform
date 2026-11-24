#!/usr/bin/env python3
"""Cold-start timeline of the vLLM pod on EKS: GPU node launch -> weights -> model loaded.

  python3 infra/scripts/cloud_timeline.py <namespace> <release>   (make up-cloud runs it)

Reads timestamps Kubernetes and Karpenter already record (pod conditions, container states,
NodeClaim conditions), so it costs nothing extra. Seconds are counted from pod creation.
"""
import datetime as dt
import json
import subprocess
import sys


def kubectl(*args):
    return json.loads(subprocess.run(["kubectl", *args, "-o", "json"], capture_output=True, text=True, check=True).stdout)


def ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def main():
    ns, release = sys.argv[1], sys.argv[2]
    pods = kubectl("-n", ns, "get", "pods", "-l", f"app.kubernetes.io/instance={release},app.kubernetes.io/name=vllm")["items"]
    if not pods:
        sys.exit("no vLLM pod")
    pod = max(pods, key=lambda p: p["metadata"]["creationTimestamp"])
    t0 = ts(pod["metadata"]["creationTimestamp"])
    events = [("pod created (pending: no GPU node yet)", t0)]

    node = pod["spec"].get("nodeName")
    if node:
        claims = [c for c in kubectl("get", "nodeclaims")["items"] if c.get("status", {}).get("nodeName") == node]
        if claims:
            c = claims[0]
            events.append((f"NodeClaim created ({c['metadata']['name']})", ts(c["metadata"]["creationTimestamp"])))
            for cond in c.get("status", {}).get("conditions", []):
                if cond["type"] in ("Launched", "Registered", "Initialized") and cond["status"] == "True":
                    events.append((f"GPU node {cond['type'].lower()}", ts(cond["lastTransitionTime"])))

    conds = {c["type"]: ts(c.get("lastTransitionTime")) for c in pod["status"].get("conditions", []) if c["status"] == "True"}
    if "PodScheduled" in conds:
        events.append(("pod scheduled on the GPU node", conds["PodScheduled"]))
    for ic in pod["status"].get("initContainerStatuses", []):
        term = ic.get("state", {}).get("terminated") or ic.get("lastState", {}).get("terminated") or {}
        if term:
            events.append((f"init '{ic['name']}' started (image pulled)", ts(term.get("startedAt"))))
            events.append((f"init '{ic['name']}' done (weights on local disk)", ts(term.get("finishedAt"))))
    for cs in pod["status"].get("containerStatuses", []):
        run = cs.get("state", {}).get("running") or {}
        if run:
            events.append((f"'{cs['name']}' started (image pulled)", ts(run.get("startedAt"))))
    if "Ready" in conds:
        events.append(("pod Ready (model loaded, serving)", conds["Ready"]))

    events = sorted((e for e in events if e[1]), key=lambda e: e[1])
    print("\nCold-start timeline (seconds from pod creation):")
    for what, t in events:
        print(f"  {(t - t0).total_seconds():7.0f}s  {what}")
    try:
        log = subprocess.run(["kubectl", "-n", ns, "logs", pod["metadata"]["name"], "-c", "weights"],
                             capture_output=True, text=True).stdout.strip().splitlines()
        if log:
            print(f"  weights copy: {log[-1]}")
    except OSError:
        pass


if __name__ == "__main__":
    main()
