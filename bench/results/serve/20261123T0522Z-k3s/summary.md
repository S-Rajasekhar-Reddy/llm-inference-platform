# vllm bench serve: Qwen/Qwen3-8B-FP8 on k3s (20261123T0522Z)

GPU: NVIDIA GeForce RTX 5080 Laptop GPU, 16303 MiB, 621.14. Image `vllm/vllm-openai:v0.33.0`. Random prompts, 512 input / 128 output tokens (ignore_eos), 50-prompt warm-up discarded, 3 run(s) per level, median [min-max]. Client: in-cluster Job on the server's node. Every run is in runs.jsonl; conditions in meta.json.

| concurrency | runs | failed | output tok/s | req/s | TTFT p50 (ms) | TTFT p99 (ms) | TPOT p50 (ms) | ITL p99 (ms) |
|---|---|---|---|---|---|---|---|---|
| 8 | 3 | 0 | 396 [395-398] | 3.10 [3.09-3.11] | 304 [304-305] | 490 [467-623] | 17.5 [17.2-17.5] | 53.0 [52.9-53.0] |
| 32 | 3 | 0 | 1006 [1005-1010] | 7.86 [7.85-7.89] | 435 [435-436] | 1563 [1370-1623] | 28.2 [28.0-28.3] | 182.5 [181.1-183.0] |
| 64 | 3 | 0 | 1077 [1075-1079] | 8.42 [8.40-8.43] | 1677 [1676-1688] | 6106 [5929-6138] | 36.0 [36.0-36.1] | 191.7 [191.4-191.8] |
