#!/usr/bin/env bash
# Query the Prometheus HTTP API: prom-api.sh <namespace> <path>, e.g. "alerts".
# Port-forwards straight to the Prometheus pod for the one request. (The image is
# distroless, so there is no wget/curl to exec, and the Service proxy path proved
# unreliable on k3s.) PROM_PORT picks the local port (default 19090).
set -euo pipefail
ns=${1:?namespace}; path=${2:?api path}; port=${PROM_PORT:-19090}
pod=$(kubectl -n "$ns" get pod -l app.kubernetes.io/name=prometheus -o name | head -1)
[ -n "$pod" ] || { echo "no Prometheus pod in namespace $ns (make monitoring-up)" >&2; exit 1; }
kubectl -n "$ns" port-forward "$pod" "$port:9090" >/dev/null 2>&1 &
pf=$!; trap 'kill $pf 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -sf "localhost:$port/-/ready" >/dev/null && break; sleep 0.5; done
curl -sf "localhost:$port/api/v1/$path"
