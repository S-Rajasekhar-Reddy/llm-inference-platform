#!/usr/bin/env bash
# Force one of the three vLLM alerts to fire, then put the real thresholds back.
#   make alert-test ALERT=ttft|queue|idle
# Lowers that alert's threshold/duration with a helm upgrade (the vLLM pod is not
# restarted: only the PrometheusRule changes), drives load if needed, and polls
# Prometheus until the alert is firing. The trap restores the committed values.
set -euo pipefail
ALERT=${1:?usage: alert-test.sh ttft|queue|idle}
: "${RELEASE:?}" "${NAMESPACE:?}" "${CHART:?}" "${MON_NS:?}" "${LOCAL_PORT:=8000}"
HELM_ARGS=${HELM_ARGS:-}
TIMEOUT=${TIMEOUT:-900}

case "$ALERT" in
  ttft)  NAME=VLLMTimeToFirstTokenHigh
         OVERRIDES="--set monitoring.alerts.ttft.sloSeconds=0.001 --set monitoring.alerts.ttft.for=1m"
         LOAD="--concurrency 8 --duration 300 --max-tokens 64" ;;
  queue) NAME=VLLMOutOfCapacity
         # More concurrent requests than vLLM's default max_num_seqs (256), so some must wait.
         # With KEDA on, it fires once the second replica is up and requests still wait.
         OVERRIDES="--set monitoring.alerts.queue.threshold=0.5 --set monitoring.alerts.queue.for=30s"
         LOAD="--concurrency 512 --duration 300 --max-tokens 512" ;;
  idle)  NAME=VLLMIdleGPU
         OVERRIDES="--set monitoring.alerts.idle.window=1m --set monitoring.alerts.idle.for=2m"
         LOAD="" ;;
  *) echo "ALERT must be ttft, queue or idle"; exit 1 ;;
esac

prom() { "$(dirname "$0")/prom-api.sh" "$MON_NS" "$1"; }

restore() {
  echo "restoring the committed alert thresholds..."
  # shellcheck disable=SC2086
  helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" $HELM_ARGS >/dev/null && echo "restored"
  [ -n "${PF:-}" ] && kill "$PF" 2>/dev/null || true
  [ -n "${LG:-}" ] && kill "$LG" 2>/dev/null || true
}
trap restore EXIT

echo "lowering $NAME thresholds: $OVERRIDES"
# shellcheck disable=SC2086
helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" $HELM_ARGS $OVERRIDES >/dev/null

if [ -n "$LOAD" ]; then
  kubectl -n "$NAMESPACE" port-forward "svc/$RELEASE" "$LOCAL_PORT:8000" >/tmp/"$RELEASE"-alert-pf.log 2>&1 &
  PF=$!
  for _ in $(seq 1 15); do curl -sf "localhost:$LOCAL_PORT/health" >/dev/null && break; sleep 1; done
  # shellcheck disable=SC2086
  python3 "$(dirname "$0")/loadgen.py" --url "http://localhost:$LOCAL_PORT" $LOAD &
  LG=$!
fi

start=$(date +%s)
echo "waiting for $NAME to fire (rule reload takes ~1 min; timeout ${TIMEOUT}s)..."
while :; do
  state=$(prom alerts | python3 -c "import sys,json; a=[x for x in json.load(sys.stdin)['data']['alerts'] if x['labels']['alertname']=='$NAME']; print(a[0]['state'] if a else 'inactive')")
  printf '%(%H:%M:%S)T  %s\n' -1 "$state"
  if [ "$state" = firing ]; then
    prom alerts | python3 -c "import sys,json; [print(json.dumps(x, indent=2)) for x in json.load(sys.stdin)['data']['alerts'] if x['labels']['alertname']=='$NAME']"
    echo "PASS: $NAME fired after $(( $(date +%s) - start ))s"
    exit 0
  fi
  if (( $(date +%s) - start > TIMEOUT )); then echo "FAIL: $NAME did not fire within ${TIMEOUT}s"; exit 1; fi
  sleep 15
done
