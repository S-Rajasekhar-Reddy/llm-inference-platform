#!/usr/bin/env bash
# Serving benchmark with `vllm bench serve`, run the same way on the laptop (k3s) and on EKS.
#   make bench                         # against whatever `make up-local` / `make up-cloud` deployed
#   REPEATS=5 CONCURRENCY_LEVELS="8 64" make bench
#   COST_PER_HOUR=0.8048 make bench    # adds cost per 1M output tokens at that hourly price
#
# One Job runs everything inside the cluster, on the same node as the vLLM pod (so the client
# sees the Service, not a port-forward, and no second copy of the image is pulled):
#   1. warm-up: WARMUP_PROMPTS requests at concurrency 8, discarded
#   2. for each concurrency level, REPEATS runs of random 512-token prompts / 128 output tokens
#      (ignore_eos), the same shape as the week-1 run, so the numbers compare
# Output: bench/results/serve/<stamp>-<label>/{runs.jsonl,summary.md,meta.json}
#   summary.md: median [min-max] per concurrency level; runs.jsonl: every `vllm bench serve` result.
set -euo pipefail
: "${RELEASE:?}" "${NAMESPACE:?}" "${VLLM_IMAGE:?}"
CONCURRENCY_LEVELS=${CONCURRENCY_LEVELS:-"8 32 64"}
REPEATS=${REPEATS:-3}
INPUT_LEN=${INPUT_LEN:-512}
OUTPUT_LEN=${OUTPUT_LEN:-128}
PROMPTS_PER_SLOT=${PROMPTS_PER_SLOT:-12}   # num_prompts = max(100, concurrency x this)
WARMUP_PROMPTS=${WARMUP_PROMPTS:-50}
COST_PER_HOUR=${COST_PER_HOUR:-}
LABEL=${LABEL:-}               # results folder suffix; default: the node's instance type, or "local"
TIMEOUT=${TIMEOUT:-3600}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
stamp=$(date -u +%Y%m%dT%H%MZ)
job="$RELEASE-bench-serve"

pod=$(kubectl -n "$NAMESPACE" get pod -l "app.kubernetes.io/instance=$RELEASE" \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
[ -n "$pod" ] || { echo "no running vLLM pod for release $RELEASE in $NAMESPACE"; exit 1; }
args_json=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.spec.containers[0].args}')
served=$(python3 -c '
import json, sys
a = json.loads(sys.argv[1])
pick = lambda f: a[a.index(f) + 1] if f in a else None
print(pick("--served-model-name") or pick("--model"))' "$args_json")
tokenizer=$served   # a Hugging Face id: the client downloads only the tokenizer
node=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.spec.nodeName}')
itype=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || true)
gpu=$(kubectl -n "$NAMESPACE" exec "$pod" -- nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
LABEL=${LABEL:-${itype:-local}}
out="$root/bench/results/serve/$stamp-$LABEL"
mkdir -p "$out"

echo "benchmarking $served on node $node (${itype:-local}), GPU: ${gpu:-unknown}"
echo "levels: $CONCURRENCY_LEVELS, $REPEATS run(s) each, ${INPUT_LEN} in / ${OUTPUT_LEN} out tokens"

# The loop that runs inside the Job. Each result is printed as one line: BENCH_JSON <json>.
read -r -d '' inner <<'SH' || true
set -eu
base="--backend openai --base-url http://$RELEASE:8000 --endpoint /v1/completions --model $SERVED --tokenizer $TOKENIZER
  --dataset-name random --random-input-len $INPUT_LEN --random-output-len $OUTPUT_LEN --ignore-eos --request-rate inf
  --percentile-metrics ttft,tpot,itl,e2el --metric-percentiles 50,95,99"
echo "warm-up: $WARMUP_PROMPTS prompts at concurrency 8 (discarded)"
vllm bench serve $base --num-prompts "$WARMUP_PROMPTS" --max-concurrency 8 >/dev/null
for c in $LEVELS; do
  n=$(( c * PER_SLOT )); [ "$n" -lt 100 ] && n=100
  for r in $(seq 1 "$REPEATS"); do
    echo "concurrency $c, run $r/$REPEATS, $n prompts"
    vllm bench serve $base --num-prompts "$n" --max-concurrency "$c" \
      --save-result --result-dir /tmp --result-filename "r.json" >/dev/null
    python3 -c "import json;d=json.load(open('/tmp/r.json'));d.update(run=$r,concurrency=$c);[d.pop(k,None) for k in ('latencies','queue_times','ttfts','itls','generated_texts','input_lens','output_lens','errors')];print('BENCH_JSON',json.dumps(d))"
    sleep 5
  done
done
echo BENCH_DONE
SH

kubectl -n "$NAMESPACE" delete job "$job" --ignore-not-found --wait >/dev/null
python3 - "$NAMESPACE" "$job" "$VLLM_IMAGE" "$RELEASE" "$inner" "$served" "$tokenizer" \
  "$INPUT_LEN" "$OUTPUT_LEN" "$WARMUP_PROMPTS" "$CONCURRENCY_LEVELS" "$PROMPTS_PER_SLOT" "$REPEATS" "$TIMEOUT" <<'PY' | kubectl apply -f - >/dev/null
import json, sys
ns, job, image, release, inner, served, tok, inp, outp, warm, levels, per, reps, timeout = sys.argv[1:]
env = dict(RELEASE=release, SERVED=served, TOKENIZER=tok, INPUT_LEN=inp, OUTPUT_LEN=outp,
           WARMUP_PROMPTS=warm, LEVELS=levels, PER_SLOT=per, REPEATS=reps)
print(json.dumps({
  "apiVersion": "batch/v1", "kind": "Job",
  "metadata": {"name": job, "namespace": ns},
  "spec": {"backoffLimit": 0, "activeDeadlineSeconds": int(timeout), "ttlSecondsAfterFinished": 600,
    "template": {"spec": {
      "restartPolicy": "Never", "enableServiceLinks": False,
      # same node as the server: the image is already there, and on EKS the GPU node is tainted
      "affinity": {"podAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [{
          "labelSelector": {"matchLabels": {"app.kubernetes.io/instance": release, "app.kubernetes.io/name": "vllm"}},
          "topologyKey": "kubernetes.io/hostname"}]}},
      "tolerations": [{"key": "nvidia.com/gpu", "operator": "Exists", "effect": "NoSchedule"}],
      "containers": [{"name": "bench", "image": image, "imagePullPolicy": "IfNotPresent",
        "command": ["bash", "-c", inner],
        "env": [{"name": k, "value": v} for k, v in env.items()],
        "resources": {"requests": {"cpu": "500m", "memory": "1Gi"}}}]}}}}))
PY

echo "job started; following its log (Ctrl+C stops following, not the job)"
for _ in $(seq 1 60); do
  kubectl -n "$NAMESPACE" get pod -l "job-name=$job" -o jsonpath='{.items[0].status.phase}' 2>/dev/null \
    | grep -qE 'Running|Succeeded|Failed' && break
  sleep 5
done
kubectl -n "$NAMESPACE" logs -f "job/$job" | tee "$out/job.log" | grep -v '^BENCH_JSON' || true
kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$job" --timeout=60s >/dev/null 2>&1 \
  || { echo "job did not complete; see $out/job.log"; exit 1; }
grep '^BENCH_JSON ' "$out/job.log" | cut -d' ' -f2- > "$out/runs.jsonl"

python3 - "$out" "$served" "$VLLM_IMAGE" "$node" "${itype:-local}" "${gpu:-unknown}" "$args_json" \
  "$CONCURRENCY_LEVELS" "$REPEATS" "$INPUT_LEN" "$OUTPUT_LEN" "$WARMUP_PROMPTS" "$COST_PER_HOUR" "$stamp" <<'PY'
import json, statistics, sys
out, model, image, node, itype, gpu, args, levels, reps, inp, outp, warm, cph, stamp = sys.argv[1:]
runs = [json.loads(l) for l in open(f"{out}/runs.jsonl")]
meta = dict(date_utc=stamp, model=model, image=image, node=node, instance_type=itype, gpu=gpu,
            server_args=json.loads(args), concurrency_levels=levels.split(), repeats=int(reps),
            input_len=int(inp), output_len=int(outp), warmup_prompts=int(warm),
            cost_per_hour_usd=float(cph) if cph else None, client="vllm bench serve, in-cluster Job on the server's node")
json.dump(meta, open(f"{out}/meta.json", "w"), indent=2)

cols = [("output_throughput", "output tok/s", "{:.0f}"), ("request_throughput", "req/s", "{:.2f}"),
        ("median_ttft_ms", "TTFT p50 (ms)", "{:.0f}"), ("p99_ttft_ms", "TTFT p99 (ms)", "{:.0f}"),
        ("median_tpot_ms", "TPOT p50 (ms)", "{:.1f}"), ("p99_itl_ms", "ITL p99 (ms)", "{:.1f}")]
def cell(vals, f):
    vals = [v for v in vals if v is not None]
    if not vals: return "n/a"
    m = f.format(statistics.median(vals))
    return m if len(vals) == 1 else f"{m} [{f.format(min(vals))}-{f.format(max(vals))}]"
lines = [f"# vllm bench serve: {model} on {itype} ({stamp})", "",
         f"GPU: {gpu}. Image `{image}`. Random prompts, {inp} input / {outp} output tokens (ignore_eos), "
         f"{warm}-prompt warm-up discarded, {reps} run(s) per level, median [min-max]. "
         "Client: in-cluster Job on the server's node. Every run is in runs.jsonl; conditions in meta.json.", ""]
hdr = ["concurrency", "runs", "failed"] + [c[1] for c in cols] + (["$ per 1M output tokens"] if cph else [])
lines += ["| " + " | ".join(hdr) + " |", "|" + "---|" * len(hdr)]
for c in sorted({r["concurrency"] for r in runs}):
    g = [r for r in runs if r["concurrency"] == c]
    row = [str(c), str(len(g)), str(sum(r.get("failed", 0) for r in g))]
    row += [cell([r.get(k) for r in g], f) for k, _, f in cols]
    if cph:
        row.append(cell([float(cph) / (r["output_throughput"] * 3600) * 1e6 for r in g if r.get("output_throughput")], "{:.2f}"))
    lines.append("| " + " | ".join(row) + " |")
if cph:
    lines += ["", f"Cost per 1M output tokens = {cph} USD/h / (output tok/s x 3600) x 1e6, at full load on one GPU."]
open(f"{out}/summary.md", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
echo; echo "saved: ${out#$root/}/{summary.md,runs.jsonl,meta.json,job.log}"
