# PR #54479 @ 5c8ba69 on RTX 5080 Laptop 16 GB, vLLM v0.33.0, Qwen3-8B-FP8, --max-model-len 8192, --gpu-memory-utilization 0.85

Median [min-max] over repeats. Cold = empty torch.compile cache; warm = cache written by the preceding cold boot.

| arm | boot | n ok | KV tokens (each run) | KV GiB | peak activation GiB | torch.compile s | engine init s | ready s | free at startup GiB |
|---|---|---|---|---|---|---|---|---|---|
| unpatched | cold | 3/3 | 21,024, 21,024, 21,024 | 2.89 [2.89-2.89] | 1.58 [1.58-1.58] | 20.3 [20.2-20.4] | 143.0 [141.8-144.0] | 187.8 [186.9-191.2] | 14.61 [14.61-14.61] |
| unpatched | warm | 3/3 | 25,824, 25,824, 25,824 | 3.55 [3.55-3.55] | 0.92 [0.92-0.92] | 0.2 [0.1-0.2] | 89.9 [89.8-90.5] | 128.1 [127.1-130.5] | 14.61 [14.61-14.61] |
| patched | cold | 3/3 | 25,824, 25,824, 25,824 | 3.55 [3.55-3.55] | 0.92 [0.92-0.92] | 20.2 [20.1-20.5] | 140.7 [140.3-144.2] | 187.0 [187.0-191.3] | 14.61 [14.61-14.61] |
| patched | warm | 3/3 | 25,824, 25,824, 25,824 | 3.55 [3.55-3.55] | 0.92 [0.92-0.92] | 0.1 [0.1-0.1] | 90.2 [90.2-92.5] | 128.4 [126.4-131.0] | 14.61 [14.61-14.61] |

- Engine init cost of the warmup pass, cold boots: -2.3 s (-1.6%) median vs unpatched.
- Engine init cost of the warmup pass, warm boots: +0.3 s (+0.3%) median vs unpatched.
- KV parity unpatched: cold [21024] vs warm [25824]
- KV parity patched:   cold [25824] vs warm [25824]
