#!/usr/bin/env bash
# Does a second vLLM replica on the SAME GPU add throughput?
#   make bench-replicas            (about 20 min; KEDA is paused and restored at the end)
#
# Three configurations of the same model under the same load, each measured from
# Prometheus over a fixed window after a warm-up:
#   1x-small : 1 replica,  --gpu-memory-utilization 0.4, KV cache pinned 1.5 GiB (the per-pod budget used for 2 replicas)
#   2x-small : 2 replicas, same per-pod settings, both on one time-sliced GPU
#   1x-full  : 1 replica,  --gpu-memory-utilization 0.85, KV cache sized by vLLM (the whole GPU for one instance)
# Output: a Markdown table + CSV in bench/results/replicas/<timestamp>.{md,csv}
set -euo pipefail
: "${RELEASE:?}" "${NAMESPACE:?}" "${CHART:?}" "${MON_NS:?}" "${VLLM_IMAGE:?}"
HELM_ARGS=${HELM_ARGS:-}
CONCURRENCY_LEVELS=${CONCURRENCY_LEVELS:-"64 256"}
WARMUP=${WARMUP:-30}       # seconds of load before the measured window
WINDOW=${WINDOW:-120}      # measured seconds
MAX_TOKENS=${MAX_TOKENS:-256}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%MZ)
out="$root/bench/results/replicas/$stamp"
mkdir -p "$(dirname "$out")"
sel="job=\"$RELEASE\",namespace=\"$NAMESPACE\""

q() { # instant Prometheus query -> first value (or "nan")
  "$root/platform/monitoring/prom-api.sh" "$MON_NS" \
    "query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")" \
    | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")'
}

deploy() { # $1 replicas, then extra --set args
  local replicas=$1; shift
  # shellcheck disable=SC2086
  helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" $HELM_ARGS \
    --set autoscaling.enabled=false --set replicaCount="$replicas" "$@" --wait --timeout 15m >/dev/null
  kubectl -n "$NAMESPACE" rollout status "deploy/$RELEASE" --timeout=15m >/dev/null
  echo "  $(kubectl -n "$NAMESPACE" get deploy "$RELEASE" -o jsonpath='{.status.readyReplicas}') ready"
}

load() { # $1 concurrency; runs WARMUP+WINDOW seconds in-cluster against the Service
  local c=$1
  kubectl -n "$NAMESPACE" delete job "$RELEASE-bench" --ignore-not-found --wait >/dev/null
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: {name: $RELEASE-bench, namespace: $NAMESPACE}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      enableServiceLinks: false
      containers:
        - name: loadgen
          image: $VLLM_IMAGE
          imagePullPolicy: IfNotPresent
          command: ["python3", "/app/loadgen.py", "--url", "http://$RELEASE:8000", "--concurrency", "$c",
                    "--duration", "$((WARMUP + WINDOW))", "--max-tokens", "$MAX_TOKENS"]
          resources: {requests: {cpu: 200m, memory: 256Mi}}
          volumeMounts: [{name: app, mountPath: /app}]
      volumes: [{name: app, configMap: {name: $RELEASE-loadgen}}]
YAML
  sleep $((WARMUP + WINDOW + 15))   # + one scrape interval so the last samples are in Prometheus
}

measure() { # $1 config, $2 replicas, $3 concurrency -> one CSV row
  local w="${WINDOW}s] offset 15s"   # the measured window ends when the load stops
  local tok req ttft50 ttft95 qt95 kv pre
  tok=$(q "sum(increase(vllm:generation_tokens_total{$sel}[$w)) / $WINDOW")
  req=$(q "sum(increase(vllm:request_success_total{$sel}[$w)) / $WINDOW")
  ttft50=$(q "histogram_quantile(0.5, sum by (le) (increase(vllm:time_to_first_token_seconds_bucket{$sel}[$w)))")
  ttft95=$(q "histogram_quantile(0.95, sum by (le) (increase(vllm:time_to_first_token_seconds_bucket{$sel}[$w)))")
  qt95=$(q "histogram_quantile(0.95, sum by (le) (increase(vllm:request_queue_time_seconds_bucket{$sel}[$w)))")
  kv=$(q "avg(avg_over_time(vllm:kv_cache_usage_perc{$sel}[$w))")
  pre=$(q "sum(increase(vllm:num_preemptions_total{$sel}[$w))")
  printf '%s,%s,%s,%.0f,%.2f,%.3f,%.3f,%.3f,%.2f,%.0f\n' "$1" "$2" "$3" "$tok" "$req" "$ttft50" "$ttft95" "$qt95" "$kv" "$pre"
}

restore() {
  echo "restoring the committed release (KEDA back on)..."
  kubectl -n "$NAMESPACE" delete job "$RELEASE-bench" --ignore-not-found >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" $HELM_ARGS --wait --timeout 15m >/dev/null && echo "restored"
}
trap restore EXIT

kubectl -n "$NAMESPACE" create configmap "$RELEASE-loadgen" --from-file=loadgen.py="$root/platform/monitoring/loadgen.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

csv="$out.csv"
echo "config,replicas,concurrency,output_tok_per_s,req_per_s,ttft_p50_s,ttft_p95_s,queue_time_p95_s,kv_cache_usage_avg,preemptions" > "$csv"

run_config() { # $1 name, $2 replicas, rest = --set args
  local name=$1 replicas=$2; shift 2
  echo "== $name: deploying $replicas replica(s)"
  deploy "$replicas" "$@"
  for c in $CONCURRENCY_LEVELS; do
    echo "  load: concurrency $c, ${WARMUP}s warm-up + ${WINDOW}s measured"
    load "$c"
    measure "$name" "$replicas" "$c" | tee -a "$csv"
  done
}

run_config 1x-small 1
run_config 2x-small 2
run_config 1x-full  1 --set model.gpuMemoryUtilization=0.85 --set model.kvCacheMemoryBytes=

{
  echo "# Same model, same GPU: 1 vs 2 replicas ($stamp)"
  echo
  echo "vLLM image \`$VLLM_IMAGE\`, model \`$(kubectl -n "$NAMESPACE" get deploy "$RELEASE" -o jsonpath='{.spec.template.spec.containers[0].args}' | python3 -c 'import sys,json;a=json.load(sys.stdin);print(a[a.index("--model")+1] if "--model" in a else a[0])' 2>/dev/null || echo '?')\`,"
  echo "GPU $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo '?'). Load: in-cluster, random"
  echo "short prompt, max_tokens=$MAX_TOKENS with ignore_eos, ${WARMUP}s warm-up then ${WINDOW}s measured from Prometheus."
  echo "\"small\" = --gpu-memory-utilization 0.4 + 1.5 GiB pinned KV cache per pod; \"full\" = 0.85, KV sized by vLLM."
  echo
  echo "| config | replicas | concurrency | output tok/s | req/s | TTFT p50 (s) | TTFT p95 (s) | queue p95 (s) | KV usage | preemptions |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  tail -n +2 "$csv" | awk -F, '{printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10}'
} > "$out.md"
echo; cat "$out.md"; echo; echo "saved: ${out#$root/}.{md,csv}"
