#!/usr/bin/env python3
"""Summarise Prometheus API JSON from stdin: `targets` or `alerts` (used by make monitoring-status)."""
import json, sys

mode, raw = sys.argv[1], sys.stdin.read()
if not raw.strip():
    sys.exit("no answer from Prometheus: is its pod Running and Ready? kubectl -n monitoring get pods")
data = json.loads(raw)["data"]
if mode == "targets":
    for t in data["activeTargets"]:
        job = t["labels"].get("job", "")
        if "vllm" in job or "gpu" in job:
            print(f"target {job:28} {t['health']:7} {t['scrapeUrl']} {t.get('lastError', '')}")
elif mode == "alerts":
    alerts = [a for a in data["alerts"] if a["labels"]["alertname"].startswith("VLLM")]
    for a in alerts:
        print(f"alert  {a['labels']['alertname']:28} {a['state']}")
    if not alerts:
        print("alert  no VLLM* alerts pending or firing")
