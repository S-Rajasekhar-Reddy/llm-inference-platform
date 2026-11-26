"""Backport vllm-project/vllm PR #54479 (commit 5c8ba69) onto vLLM v0.33.0.

The PR adds one block to Worker.determine_available_memory() in vllm/v1/worker/gpu_worker.py:
a warmup profile_run() before the measured one, so torch.compile's one-off JIT memory is not
counted as activation memory on a cold boot. v0.33.0 already has every name the block uses
except the _MAX_SPLIT_SIZE_MB constant (main: 21); v0.33.0's own profiling pass uses 20, so the
backport uses 20 to keep both passes identical, as they are in the PR.

Usage: python3 patch_pr54479.py [path/to/gpu_worker.py]   (default: the installed vLLM's file)
"""
import sys

ANCHOR = "        # Execute a forward pass with dummy inputs to profile the memory usage\n"
BLOCK = '''        # When torch.compile is enabled, run an initial pass to trigger JIT compilation
        # inside the active vLLM config and split-limited allocator context.
        if self.vllm_config.compilation_config.mode != CompilationMode.NONE:
            with (
                set_current_vllm_config(self.vllm_config),
                self._scoped_allocator_max_split(max_split_size_mb=20),
            ):
                self.model_runner.profile_run(
                    randomize_inputs=self.randomize_dummy_inputs
                )
            torch.accelerator.synchronize()

'''
MARK = "run an initial pass to trigger JIT compilation"

if len(sys.argv) > 1:
    path = sys.argv[1]
else:
    import vllm.v1.worker.gpu_worker as m
    path = m.__file__

src = open(path).read()
if MARK in src:
    sys.exit(f"{path}: already patched")
if src.count(ANCHOR) != 1:
    sys.exit(f"{path}: anchor found {src.count(ANCHOR)} times, expected 1 (not v0.33.0?)")
for name in ("CompilationMode", "set_current_vllm_config", "def _scoped_allocator_max_split",
             "def randomize_dummy_inputs", "\nimport torch\n"):
    if name not in src:
        sys.exit(f"{path}: missing {name.strip()!r}, the backport would not run")
open(path, "w").write(src.replace(ANCHOR, BLOCK + ANCHOR))
print(f"patched {path}")
