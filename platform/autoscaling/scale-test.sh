#!/usr/bin/env bash
# Drive vLLM past its queue threshold and watch KEDA scale 1 -> 2 -> 1.
#   make scale-test            (LOAD_SECONDS=360 CONCURRENCY=512 by default)
# Prints one line every 10 s: replicas wanted/ready, requests waiting and running.
# Load comes from a short-lived in-cluster Job (platform/monitoring/loadgen.py).
# Keep `make grafana` open alongside for the dashboard view of the same run.
set -euo pipefail
: "${RELEASE:?}" "${NAMESPACE:?}" "${MON_NS:?}" "${VLLM_IMAGE:?}"
LOAD_SECONDS=${LOAD_SECONDS:-360}
CONCURRENCY=${CONCURRENCY:-512}
SCALE_DOWN_WAIT=${SCALE_DOWN_WAIT:-420}
here=$(cd "$(dirname "$0")" && pwd)

q() { # instant Prometheus query -> number (or "-")
  "$here/../monitoring/prom-api.sh" "$MON_NS" "query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")" 2>/dev/null \
    | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "0")' 2>/dev/null || echo "-"
}
line() {
  read -r want ready < <(kubectl -n "$NAMESPACE" get deploy "$RELEASE" -o jsonpath='{.spec.replicas} {.status.readyReplicas}{"\n"}')
  sel="job=\"$RELEASE\",namespace=\"$NAMESPACE\""
  printf '%(%H:%M:%S)T  %-8s replicas %s/%s ready   waiting %-6s running %s\n' -1 "$1" "${want:-0}" "${ready:-0}" \
    "$(q "sum(vllm:num_requests_waiting{$sel})")" "$(q "sum(vllm:num_requests_running{$sel})")"
}

kubectl get scaledobject -n "$NAMESPACE" "$RELEASE" >/dev/null || { echo "no ScaledObject $RELEASE: make keda-up && make up-local"; exit 1; }
echo "allocatable nvidia.com/gpu: $(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}') (needs 2)"

# Load runs inside the cluster against the Service, so both replicas get traffic
# (a port-forward would pin every request to one pod). The Job reuses the vLLM image
# already imported into k3s, so nothing new is pulled.
kubectl -n "$NAMESPACE" create configmap "$RELEASE-loadgen" --from-file=loadgen.py="$here/../monitoring/loadgen.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" delete job "$RELEASE-loadgen" --ignore-not-found >/dev/null
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $RELEASE-loadgen
  namespace: $NAMESPACE
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      enableServiceLinks: false
      containers:
        - name: loadgen
          image: $VLLM_IMAGE
          imagePullPolicy: IfNotPresent
          command: ["python3", "/app/loadgen.py", "--url", "http://$RELEASE:8000",
                    "--concurrency", "$CONCURRENCY", "--duration", "$LOAD_SECONDS", "--max-tokens", "512"]
          resources:
            requests: {cpu: 200m, memory: 256Mi}
          volumeMounts: [{name: app, mountPath: /app}]
      volumes: [{name: app, configMap: {name: $RELEASE-loadgen}}]
YAML
trap 'kubectl -n "$NAMESPACE" delete job "$RELEASE-loadgen" --ignore-not-found >/dev/null 2>&1 || true' EXIT

line before
end=$(( $(date +%s) + LOAD_SECONDS + 20 ))
while (( $(date +%s) < end )); do sleep 10; line load; done
kubectl -n "$NAMESPACE" logs "job/$RELEASE-loadgen" --tail=2 2>/dev/null || true

echo "load stopped; waiting up to ${SCALE_DOWN_WAIT}s for scale-down (HPA stabilisation window)"
stop=$(( $(date +%s) + SCALE_DOWN_WAIT ))
while (( $(date +%s) < stop )); do
  sleep 15; line cooldown
  [ "$(kubectl -n "$NAMESPACE" get deploy "$RELEASE" -o jsonpath='{.spec.replicas}')" = "1" ] && { echo "back to 1 replica"; exit 0; }
done
echo "still above 1 replica after ${SCALE_DOWN_WAIT}s: kubectl describe hpa -n $NAMESPACE"
