#!/usr/bin/env bash
# Measure vLLM cold start: wall-clock time from `docker run` until /health returns 200.
#
# Usage:
#   bench/coldstart.sh <label> <model> [extra vLLM args...]
#
# Environment overrides:
#   IMAGE       vLLM image (default: vllm/vllm-openai:v0.33.0)
#   OFFLINE=1   set HF_HUB_OFFLINE=1 (no Hugging Face network calls at startup)
#   VLLM_CACHE=0  do NOT mount ~/.cache/vllm (compile cache); default mounts it
#   KEEP=1      leave the server running after the measurement
#
# Writes the full server log and appends one JSON line per run to
# bench/results/coldstart/results.jsonl.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <label> <model> [extra vLLM args...]" >&2
  exit 2
fi

LABEL=$1
MODEL=$2
shift 2

IMAGE=${IMAGE:-vllm/vllm-openai:v0.33.0}
NAME=vllm-coldstart
OUT=bench/results/coldstart
mkdir -p "$OUT"
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG="$OUT/${TS}-${LABEL}.log"

ENV_ARGS=()
[ "${OFFLINE:-0}" = "1" ] && ENV_ARGS+=(-e HF_HUB_OFFLINE=1)

VOL_ARGS=(-v "$HOME/.cache/huggingface:/root/.cache/huggingface")
if [ "${VLLM_CACHE:-1}" = "1" ]; then
  mkdir -p "$HOME/.cache/vllm"
  VOL_ARGS+=(-v "$HOME/.cache/vllm:/root/.cache/vllm")
fi

docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "[$LABEL] starting $MODEL ($IMAGE)"
START=$(date +%s.%N)
docker run -d --name "$NAME" --gpus all --ipc=host -p 8000:8000 \
  "${ENV_ARGS[@]}" "${VOL_ARGS[@]}" \
  "$IMAGE" --model "$MODEL" "$@" >/dev/null

until [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:8000/health || true)" = "200" ]; do
  if [ -z "$(docker ps -q --filter "name=^${NAME}$")" ]; then
    docker logs "$NAME" >"$LOG" 2>&1 || true
    echo "[$LABEL] container exited before becoming healthy; log: $LOG" >&2
    exit 1
  fi
  sleep 1
done
END=$(date +%s.%N)

docker logs "$NAME" >"$LOG" 2>&1
READY=$(awk -v s="$START" -v e="$END" 'BEGIN { printf "%.1f", e - s }')

# Pull phase timings out of the vLLM log (empty if a line is absent).
grab() { grep -oP "$1" "$LOG" | head -n1 || true; }
DOWNLOAD=$(grab 'Time spent downloading weights for \S+: \K[0-9.]+')
LOAD=$(grab 'Loading weights took \K[0-9.]+')
COMPILE=$(grab 'torch.compile took \K[0-9.]+')
INIT=$(grab 'init engine \(profile, create kv cache, warmup model\) took \K[0-9.]+')
KV_TOKENS=$(grab 'GPU KV cache size: \K[0-9,]+' | tr -d ',')

num() { [ -n "$1" ] && echo "$1" || echo null; }

printf '{"ts":"%s","label":"%s","model":"%s","image":"%s","offline":%s,"vllm_cache_mounted":%s,"extra_args":"%s","ready_s":%s,"download_s":%s,"load_weights_s":%s,"torch_compile_s":%s,"engine_init_s":%s,"kv_cache_tokens":%s,"log":"%s"}\n' \
  "$TS" "$LABEL" "$MODEL" "$IMAGE" \
  "$([ "${OFFLINE:-0}" = "1" ] && echo true || echo false)" \
  "$([ "${VLLM_CACHE:-1}" = "1" ] && echo true || echo false)" \
  "$*" "$READY" "$(num "$DOWNLOAD")" "$(num "$LOAD")" "$(num "$COMPILE")" \
  "$(num "$INIT")" "$(num "$KV_TOKENS")" "$(basename "$LOG")" \
  | tee -a "$OUT/results.jsonl"

echo "[$LABEL] ready in ${READY}s"

if [ "${KEEP:-0}" != "1" ]; then
  docker rm -f "$NAME" >/dev/null
fi
