#!/usr/bin/env python3
"""Tiny stdlib load generator for the alert tests: N workers send completions for D seconds."""
import argparse, json, threading, time, urllib.request

p = argparse.ArgumentParser()
p.add_argument("--url", default="http://localhost:8000")
p.add_argument("--concurrency", type=int, default=8)
p.add_argument("--duration", type=int, default=180, help="seconds")
p.add_argument("--max-tokens", type=int, default=64)
a = p.parse_args()

model = json.load(urllib.request.urlopen(f"{a.url}/v1/models"))["data"][0]["id"]
body = json.dumps({"model": model, "prompt": "Explain how Kubernetes schedules GPU workloads.",
                   "max_tokens": a.max_tokens, "ignore_eos": True}).encode()
stop = time.time() + a.duration
ok = err = 0
lock = threading.Lock()

def worker():
    global ok, err
    while time.time() < stop:
        req = urllib.request.Request(f"{a.url}/v1/completions", body, {"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=600).read()
            with lock: ok += 1
        except Exception:
            with lock: err += 1
            time.sleep(1)

threads = [threading.Thread(target=worker, daemon=True) for _ in range(a.concurrency)]
print(f"load: {a.concurrency} workers x {a.duration}s, max_tokens={a.max_tokens}, model={model}", flush=True)
for t in threads: t.start()
for t in threads: t.join()
print(f"load done: {ok} ok, {err} errors", flush=True)
