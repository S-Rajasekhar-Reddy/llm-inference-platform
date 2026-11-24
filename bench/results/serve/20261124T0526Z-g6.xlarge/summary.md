# vllm bench serve: Qwen/Qwen3-8B-FP8 on g6.xlarge (20261124T0526Z)

GPU: NVIDIA L4, 23034 MiB, 580.178.04. Image `vllm/vllm-openai:v0.33.0`. Random prompts, 512 input / 128 output tokens (ignore_eos), 50-prompt warm-up discarded, 3 run(s) per level, median [min-max]. Client: in-cluster Job on the server's node. Every run is in runs.jsonl; conditions in meta.json.

| concurrency | runs | failed | output tok/s | req/s | TTFT p50 (ms) | TTFT p99 (ms) | TPOT p50 (ms) | ITL p99 (ms) | $ per 1M output tokens |
|---|---|---|---|---|---|---|---|---|---|
| 8 | 3 | 0 | 158 [158-180] | 1.23 [1.23-1.41] | 955 [303-981] | 1560 [1418-1631] | 38.4 [36.8-38.5] | 235.3 [37.9-236.7] | 1.42 [1.24-1.42] |
| 32 | 3 | 0 | 326 [324-327] | 2.54 [2.53-2.55] | 1987 [1960-1989] | 5971 [5783-6179] | 83.0 [83.0-83.2] | 823.2 [808.0-829.9] | 0.69 [0.68-0.69] |
| 64 | 3 | 0 | 381 [381-385] | 2.97 [2.97-3.01] | 2555 [2514-2582] | 11983 [11874-12097] | 148.5 [147.3-148.6] | 864.9 [862.2-869.2] | 0.59 [0.58-0.59] |

Cost per 1M output tokens = 0.8048 USD/h / (output tok/s x 3600) x 1e6, at full load on one GPU.
