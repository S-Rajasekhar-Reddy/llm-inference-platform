#!/usr/bin/env bash
# Re-validate vllm-project/vllm PR #54479 at commit 5c8ba69 on an RTX 5080 Laptop (16 GB), vLLM v0.33.0, WSL2 + Docker.
# Answers the 24 Nov review questions with GPU evidence:
#   1. KV parity: does a cold boot (empty compile cache) now get the same KV cache as a warm boot?
#   2. Startup cost of the extra warmup pass, on cold AND warm boots, against unpatched v0.33.0.
#   3. Cache hits: the warmup is not skipped when the compile cache is warm; how much does that cost?
#
# Same method and flags as the 10 Nov validation (bench/coldstart.sh): Qwen3-8B-FP8, --max-model-len 8192,
# --gpu-memory-utilization 0.85, HF offline, timed from `docker run` to /health = 200.
#
#   bash validate-vllm-54479.sh                  # 3 repeats: ~12 boots, ~40 min
#   REPEATS=1 bash validate-vllm-54479.sh        # dry run: 4 boots, ~13 min
#
# For each repeat and each arm (unpatched, patched) it wipes that arm's compile cache, boots cold, then boots warm
# with the cache the cold boot just wrote. Arms alternate so laptop thermals or drift hit both equally.
# The k3s vLLM deployment is scaled to 0 for the test (it holds GPU memory) and restored at the end.
# Output: ~/oss/vllm-54479/<stamp>/{summary.md,results.jsonl,<boot>.log,patch.diff}
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
MODEL=${MODEL:-Qwen/Qwen3-8B-FP8}
BASE=${BASE:-vllm/vllm-openai:v0.33.0}
PATCHED=${PATCHED:-vllm-pr54479:5c8ba69}
HF_CACHE=${HF_CACHE:-$HOME/.cache/huggingface}
REPEATS=${REPEATS:-3}
PORT=${PORT:-18054}
TIMEOUT=${TIMEOUT:-900}
NS=${NAMESPACE:-default}
DEPLOY=${DEPLOY:-vllm}
ARGS=(--max-model-len 8192 --gpu-memory-utilization 0.85)
root=$HOME/oss/vllm-54479
stamp=$(date -u +%Y%m%dT%H%MZ)
out=$root/$stamp
mkdir -p "$out"

# ---- preflight ----
command -v docker >/dev/null || { echo "docker not found"; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable (start Docker Desktop / dockerd)"; exit 1; }
docker image inspect "$BASE" >/dev/null 2>&1 || { echo "$BASE not present locally; 'docker pull $BASE' first (~10 GB)"; exit 1; }
test -f "$here/patch_pr54479.py" || { echo "patch_pr54479.py must sit next to this script"; exit 1; }
test -d "$HF_CACHE/hub" || { echo "no HF cache at $HF_CACHE"; exit 1; }
! (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null || { echo "port $PORT busy; set PORT="; exit 1; }

# ---- free the GPU (k3s deployment), restore on exit ----
replicas=""
if command -v kubectl >/dev/null && kubectl config current-context 2>/dev/null | grep -qv llm-inference; then
  replicas=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
fi
restore() {
  docker rm -f vllm-54479 >/dev/null 2>&1 || true
  if [ -n "$replicas" ] && [ "$replicas" != "0" ]; then
    echo "restoring $DEPLOY to $replicas replica(s)"; kubectl -n "$NS" scale deploy "$DEPLOY" --replicas="$replicas" >/dev/null
  fi
}
trap restore EXIT
if [ -n "$replicas" ] && [ "$replicas" != "0" ]; then
  echo "scaling $DEPLOY to 0 to free the GPU (restored at the end)"
  kubectl -n "$NS" scale deploy "$DEPLOY" --replicas=0 >/dev/null
  kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/instance="$DEPLOY" --timeout=180s >/dev/null 2>&1 || true
fi
echo "GPU before the test:"; nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,temperature.gpu --format=csv,noheader | tee "$out/gpu-before.txt"

# ---- build the patched image: v0.33.0 + the PR's block, nothing else ----
ctx=$(mktemp -d)
cp "$here/patch_pr54479.py" "$ctx/"
cat > "$ctx/Dockerfile" <<EOF
FROM $BASE
COPY patch_pr54479.py /tmp/patch_pr54479.py
RUN f=\$(python3 -c "import vllm.v1.worker.gpu_worker as m; print(m.__file__)") && cp "\$f" /tmp/gpu_worker.orig.py \\
 && python3 /tmp/patch_pr54479.py "\$f" && python3 -m py_compile "\$f" \\
 && (diff -u /tmp/gpu_worker.orig.py "\$f" > /tmp/pr54479.diff || true)
EOF
echo "building $PATCHED from $BASE"
docker build -q -t "$PATCHED" "$ctx"
rm -rf "$ctx"
docker run --rm --entrypoint cat "$PATCHED" /tmp/pr54479.diff > "$out/patch.diff"
grep -q "run an initial pass to trigger JIT compilation" "$out/patch.diff" || { echo "patched image does not contain the PR block"; exit 1; }
echo "patch applied: $(grep -c '^+[^+]' "$out/patch.diff") added lines (see $out/patch.diff)"

# ---- one boot ----
boot() {  # $1 arm (unpatched|patched)  $2 cache (cold|warm)  $3 repeat
  local arm=$1 cache=$2 r=$3 image label log start end ready used
  image=$([ "$arm" = patched ] && echo "$PATCHED" || echo "$BASE")
  label="$arm-$cache-r$r"; log="$out/$label.log"
  used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
  echo "=== $label (GPU used before: ${used} MiB)"
  docker rm -f vllm-54479 >/dev/null 2>&1 || true
  start=$(date +%s.%N)
  docker run -d --name vllm-54479 --gpus all --ipc=host -p "$PORT:8000" -e HF_HUB_OFFLINE=1 \
    -v "$HF_CACHE:/root/.cache/huggingface" -v "$root/cache-$arm:/root/.cache/vllm" \
    "$image" --model "$MODEL" "${ARGS[@]}" >/dev/null
  ready=null
  while :; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "localhost:$PORT/health" || true)" = 200 ]; then
      end=$(date +%s.%N); ready=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.1f", e-s}'); break
    fi
    [ -n "$(docker ps -q --filter name=^vllm-54479$)" ] || { echo "  container exited before healthy"; break; }
    [ "$(awk -v s="$start" -v n="$(date +%s.%N)" 'BEGIN{print int(n-s)}')" -lt "$TIMEOUT" ] || { echo "  timeout"; break; }
    sleep 1
  done
  docker logs vllm-54479 > "$log" 2>&1 || true
  docker rm -f vllm-54479 >/dev/null 2>&1 || true
  python3 - "$log" "$label" "$arm" "$cache" "$r" "$ready" "$used" >> "$out/results.jsonl" <<'PY'
import json, re, sys
log, label, arm, cache, r, ready, used = sys.argv[1:]
t = open(log, errors="replace").read()
def g(p, f=float):
    m = re.search(p, t); return f(m.group(1).replace(",", "")) if m else None
print(json.dumps({"label": label, "arm": arm, "cache": cache, "repeat": int(r),
  "ready_s": None if ready == "null" else float(ready), "gpu_used_before_mib": int(used),
  "free_on_startup_gib": g(r"Free memory on device \(([0-9.]+)/"),
  "torch_compile_s": g(r"torch\.compile took ([0-9.]+) s"),
  "engine_init_s": g(r"init engine \(profile, create kv cache, warmup model\) took ([0-9.]+) s"),
  "kv_gib": g(r"Available KV cache memory: ([0-9.]+) GiB"),
  "kv_tokens": g(r"GPU KV cache size: ([0-9,]+) tokens", lambda s: int(s)),
  "peak_activation_gib": g(r"([0-9.]+) GiB for peak activation"),
  "error": (re.findall(r"(\w+Error: .{0,200})", t) or [None])[-1]}))
PY
  tail -1 "$out/results.jsonl" | python3 -c "import json,sys; d=json.load(sys.stdin); print('  ready %s s | engine init %s s | compile %s s | KV %s tokens (%s GiB) | peak act %s GiB | free %s GiB' % tuple(d[k] for k in ('ready_s','engine_init_s','torch_compile_s','kv_tokens','kv_gib','peak_activation_gib','free_on_startup_gib')))"
}

for r in $(seq 1 "$REPEATS"); do
  for arm in unpatched patched; do
    docker run --rm -v "$root:/w" --entrypoint rm "$BASE" -rf "/w/cache-$arm"   # cache files are root-owned
    mkdir -p "$root/cache-$arm"
    boot "$arm" cold "$r"
    boot "$arm" warm "$r"
  done
done
nvidia-smi --query-gpu=temperature.gpu,clocks.sm --format=csv,noheader > "$out/gpu-after.txt" || true

# ---- summary ----
python3 - "$out" <<'SUM'
import json, statistics as st, sys
out = sys.argv[1]
rows = [json.loads(l) for l in open(f"{out}/results.jsonl") if l.strip()]
def col(arm, cache, k):
    return [r[k] for r in rows if r["arm"] == arm and r["cache"] == cache and r.get(k) is not None]
def med(v, fmt="{:.1f}"):
    if not v: return "-"
    return fmt.format(st.median(v)) + (f" [{fmt.format(min(v))}-{fmt.format(max(v))}]" if len(v) > 1 else "")
L = ["# PR #54479 @ 5c8ba69 on RTX 5080 Laptop 16 GB, vLLM v0.33.0, Qwen3-8B-FP8, --max-model-len 8192, --gpu-memory-utilization 0.85", "",
     "Median [min-max] over repeats. Cold = empty torch.compile cache; warm = cache written by the preceding cold boot.", "",
     "| arm | boot | n ok | KV tokens (each run) | KV GiB | peak activation GiB | torch.compile s | engine init s | ready s | free at startup GiB |",
     "|---|---|---|---|---|---|---|---|---|---|"]
for arm in ("unpatched", "patched"):
    for c in ("cold", "warm"):
        n = len([r for r in rows if r["arm"] == arm and r["cache"] == c])
        ok = len(col(arm, c, "ready_s"))
        L.append(f"| {arm} | {c} | {ok}/{n} | {', '.join(f'{x:,}' for x in col(arm, c, 'kv_tokens'))} | {med(col(arm,c,'kv_gib'),'{:.2f}')} | "
                 f"{med(col(arm,c,'peak_activation_gib'),'{:.2f}')} | {med(col(arm,c,'torch_compile_s'))} | {med(col(arm,c,'engine_init_s'))} | "
                 f"{med(col(arm,c,'ready_s'))} | {med(col(arm,c,'free_on_startup_gib'),'{:.2f}')} |")
L.append("")
for c in ("cold", "warm"):
    u, p = col("unpatched", c, "engine_init_s"), col("patched", c, "engine_init_s")
    if u and p:
        d = st.median(p) - st.median(u)
        L.append(f"- Engine init cost of the warmup pass, {c} boots: {d:+.1f} s ({d / st.median(u) * 100:+.1f}%) median vs unpatched.")
kv = {(a, c): set(col(a, c, "kv_tokens")) for a in ("unpatched", "patched") for c in ("cold", "warm")}
L.append(f"- KV parity unpatched: cold {sorted(kv[('unpatched','cold')])} vs warm {sorted(kv[('unpatched','warm')])}")
L.append(f"- KV parity patched:   cold {sorted(kv[('patched','cold')])} vs warm {sorted(kv[('patched','warm')])}")
free = [r["free_on_startup_gib"] for r in rows if r.get("free_on_startup_gib")]
if free and max(free) - min(free) > 0.05:
    L.append(f"- WARNING: free memory at startup varied {min(free)}-{max(free)} GiB; KV comparisons are only valid at equal free memory.")
errs = [r for r in rows if r.get("ready_s") is None]
for r in errs: L.append(f"- FAILED {r['label']}: {r.get('error')}")
open(f"{out}/summary.md", "w").write("\n".join(L) + "\n")
print("\n".join(L))
SUM
echo; echo "saved: $out"
