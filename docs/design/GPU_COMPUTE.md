# Phase G: GPU Compute for Quartz

> **Status**: Design document — no compiler changes
> **Author**: Design session, March 2026
> **Target**: Post-v6.0.0 (research/moonshot phase)

---

## 1. Motivation

Quartz already has SIMD intrinsics (`F32x4`, `F32x8`, `I32x4`, `F64x2`) for data-parallel computation on CPU vector units. GPU compute extends this to thousands of parallel threads.

The goal is to let Quartz programs offload massively parallel work to GPUs — matrix operations, particle simulations, image processing, neural network inference — without requiring users to write CUDA/OpenCL manually.

### What GPU Compute Would Enable

```quartz
# Direct GPU kernel
@gpu def vector_add(a: GpuBuffer<F32>, b: GpuBuffer<F32>, out: GpuBuffer<F32>): Void
  idx = gpu_thread_id()
  out[idx] = a[idx] + b[idx]
end

# High-level parallel map
result = gpu_map(data, x -> x * x + 1.0)
```

---

## 2. Prior Art

### 2.1 LLVM NVPTX Backend

**What it is**: LLVM's native backend for NVIDIA GPUs. Emits PTX (Parallel Thread Execution) virtual assembly, which NVIDIA's `ptxas` compiles to native SASS machine code.

**Key mechanisms**:
- **Address spaces**: 0=generic, 1=global, 3=shared, 4=constant, 5=local (stack)
- **Kernel marking**: Functions with `ptx_kernel` calling convention are entry points callable from host
- **Thread ID intrinsics**: `@llvm.nvvm.read.ptx.sreg.tid.x` etc.
- **libdevice**: LLVM bitcode library for GPU math (sin, cos, exp, etc.)
- **Memory model**: Explicit address space annotations on all pointers; generic space for polymorphic access

**Strengths**: LLVM-native — Quartz already uses LLVM for codegen. No external tools needed beyond CUDA toolkit.

**Weaknesses**: NVIDIA-only. Requires CUDA toolkit for `ptxas`.

### 2.2 LLVM AMDGPU Backend

**What it is**: LLVM's backend for AMD GPUs. Similar architecture to NVPTX but targets AMDGCN ISA.

**Key differences from NVPTX**:
- `amdgpu_kernel` calling convention (instead of `ptx_kernel`)
- Different address space numbering (1=global, 3=local/shared, 4=constant, 5=private/stack)
- Requires ROCm runtime for kernel launch
- Work-item/work-group terminology (vs. thread/block)

### 2.3 SPIR-V

**What it is**: Khronos standard intermediate representation for GPU shaders and compute kernels. Target for Vulkan compute, OpenCL 2.0+.

**Key properties**:
- Vendor-neutral — works on NVIDIA, AMD, Intel, ARM Mali
- LLVM can emit SPIR-V via `spirv-llvm-translator`
- More restrictive than PTX (no arbitrary memory access patterns, structured control flow required)

**Relevance for Quartz**: Long-term portability target. SPIR-V support would enable Vulkan compute on any GPU.

### 2.4 Futhark

**Approach**: Pure functional data-parallel language. Generates C code with embedded GPU kernels (OpenCL or CUDA). Does NOT use LLVM for GPU codegen directly.

**Key design decisions**:
- **SOACs** (Second-Order Array Combinators): `map`, `reduce`, `scan`, `filter` — sequential semantics, compiled to parallel GPU code
- **Uniqueness types**: Enable in-place array modification while preserving functional purity
- **No general recursion**: All parallelism comes from bulk array operations
- Compiler handles all GPU memory management (allocations, transfers, kernel launches)
- User never writes explicit kernels — compiler derives them from functional code

**Lesson for Quartz**: High-level parallel primitives (`gpu_map`, `gpu_reduce`) can be extremely effective. Users shouldn't need to think about thread blocks.

### 2.5 Halide

**Approach**: DSL for image/array processing with **algorithm/schedule separation**. The algorithm says *what* to compute; the schedule says *how* (tiling, parallelism, vectorization, GPU mapping).

**Key design decisions**:
- Generates LLVM IR for both CPU and GPU targets
- GPU schedules specify `gpu_blocks`/`gpu_threads` mapping for loop dimensions
- Autoschedulers can derive optimal GPU schedules automatically
- Supports CUDA, OpenCL, Metal, DirectX compute

**Lesson for Quartz**: Schedule/algorithm separation is powerful for domain experts but overkill for a general-purpose language. The autoscheduler concept (compiler picks parallelization) is relevant.

### 2.6 Julia CUDA.jl

**Approach**: `@cuda` macro triggers GPU compilation of ordinary Julia functions. Uses GPUCompiler.jl to retarget Julia's LLVM backend to NVPTX.

**Key design decisions**:
- **Kernel = regular function**: No special kernel syntax beyond `@cuda` at the call site
- **Runtime compilation**: JIT compiles GPU kernels on first use via Julia → LLVM IR → PTX → ptxas → SASS
- CUDA arrays (`CuArray`) handle data transfer transparently
- `Adapt.jl` converts data types for GPU compatibility

**Lesson for Quartz**: The `@cuda` / `@gpu` annotation approach is ergonomic. Implicit data transfer via GPU-aware arrays reduces boilerplate. JIT compilation of kernels is natural for languages with LLVM backends.

### 2.7 Synthesis

| Dimension | NVPTX | AMDGPU | Futhark | Halide | Julia |
|-----------|-------|--------|---------|--------|-------|
| User writes kernels? | Yes | Yes | No | No | Yes |
| LLVM-based? | Yes | Yes | No | Yes | Yes |
| Vendor-specific? | NVIDIA | AMD | No | No | No* |
| Abstraction level | Low | Low | **High** | High | Medium |
| Data transfer | Explicit | Explicit | Automatic | Automatic | Semi-auto |

**Best fit for Quartz**: Start with LLVM NVPTX (Quartz already uses LLVM). Provide both low-level `@gpu def` kernels (Julia-style) AND high-level `gpu_map`/`gpu_reduce` primitives (Futhark-inspired). Add AMDGPU and SPIR-V later.

---

## 3. SIMD-to-GPU Extension Path

Quartz already has:
- `F32x4`, `F32x8`, `I32x4`, `F64x2` SIMD types
- Vectorized operations: `f32x4_add`, `f32x4_mul`, `f32x4_fma`
- `shuffle`, `extract`, `insert` lane operations

### How SIMD Maps to GPU

| SIMD Concept | GPU Equivalent |
|-------------|----------------|
| `F32x4` (4 lanes) | 4 threads in a warp/wavefront |
| `f32x4_add(a, b)` | `a[tid] + b[tid]` across threads |
| Vector lanes | SIMT threads |
| Vector register | Register per thread |
| `shuffle` | Warp shuffle intrinsics |

The mental model: **SIMD is GPU-lite** (4–8 lanes on CPU vs. 32–64 threads per warp on GPU). The same data-parallel patterns apply at different scales.

### Proposed Extension

```quartz
# CPU SIMD (today)
simd_result = f32x4_add(a_vec, b_vec)

# GPU (future) — same pattern, massive scale
@gpu def add_arrays(a: GpuBuffer<F32>, b: GpuBuffer<F32>, out: GpuBuffer<F32>): Void
  idx = gpu_thread_id()
  out[idx] = a[idx] + b[idx]
end
```

---

## 4. Kernel Launch Syntax

### Proposal A: `@gpu def` (Recommended)

```quartz
# Define a GPU kernel
@gpu def saxpy(a: F32, x: GpuBuffer<F32>, y: GpuBuffer<F32>, out: GpuBuffer<F32>): Void
  idx = gpu_thread_id()
  if idx < x.size
    out[idx] = a * x[idx] + y[idx]
  end
end

# Launch from host
var x = gpu_alloc<F32>(n)
var y = gpu_alloc<F32>(n)
var out = gpu_alloc<F32>(n)
gpu_copy_to(x, host_x)
gpu_copy_to(y, host_y)

gpu_launch(saxpy, n, 256, 1.5, x, y, out)  # (kernel, grid, block, args...)

gpu_copy_from(out, host_out)
gpu_free(x)
gpu_free(y)
gpu_free(out)
```

**Rationale**: Clean separation of kernel definition (with `@gpu`) from launch site. Similar to Julia's `@cuda` but as a definition attribute rather than call-site annotation.

### Proposal B: `parallel_gpu` Expression

```quartz
# Inline GPU parallel region
parallel_gpu(n, 256) do idx ->
  out[idx] = a * x[idx] + y[idx]
end
```

**Rationale**: No separate kernel definition needed. Good for one-off parallel operations. But harder to compile (must outline the body into a separate LLVM module).

### Proposal C: `gpu_map` / `gpu_reduce` (High-Level)

```quartz
# Functional GPU operations — compiler generates kernels
out = gpu_map(data, x -> x * x + 1.0)
total = gpu_reduce(data, 0.0, (acc, x) -> acc + x)
filtered = gpu_filter(data, x -> x > threshold)
```

**Rationale**: Highest abstraction level. Users never see threads or blocks. Compiler handles all parallelization. Futhark-inspired. But limits expressiveness — can't express stencils, reductions with shared memory, etc.

### Recommendation

Provide **all three** at different abstraction levels:
1. **`@gpu def`** for explicit kernels (power users)
2. **`parallel_gpu`** for inline GPU regions (convenience)
3. **`gpu_map`/`gpu_reduce`** for functional operations (simplicity)

Start with `@gpu def` (Phase G.1), add high-level operations later (Phase G.3+).

---

## 5. Data Transfer Model

### 5.1 Explicit Transfer (Phase G.1)

```quartz
# Allocate on GPU
var gpu_data = gpu_alloc<F32>(1024)

# Copy host → device
gpu_copy_to(gpu_data, host_array)

# Launch kernel (operates on GPU memory)
gpu_launch(my_kernel, grid, block, gpu_data)

# Copy device → host
gpu_copy_from(gpu_data, host_result)

# Free GPU memory
gpu_free(gpu_data)
```

**Intrinsics needed**: `gpu_alloc<T>(size)`, `gpu_copy_to(gpu, host)`, `gpu_copy_from(gpu, host)`, `gpu_free(gpu)`, `gpu_launch(kernel, grid, block, args...)`

### 5.2 Unified Memory (Phase G.3+)

```quartz
# @unified allocates in unified memory (accessible from both CPU and GPU)
@unified var data = vec_new<F32>()
for i in 0..1024
  data.push(f32_from_int(i))
end

# No explicit copy — CUDA/HSA manages page migration
gpu_launch(my_kernel, grid, block, data)
gpu_sync()  # Wait for kernel completion

# Read results directly (no copy)
result = data[0]
```

**Relies on**: CUDA Unified Memory (`cudaMallocManaged`) or HSA (for AMD). Simpler API but less control over performance.

### 5.3 Design Decision: GpuBuffer vs. CuArray

| Approach | Pros | Cons |
|----------|------|------|
| `GpuBuffer<T>` (opaque handle) | Clean separation; explicit control | Verbose transfer code |
| `CuArray<T>` (smart array) | Transparent; auto-sync | Hides latency; surprising perf |
| Unified memory pointer | Simplest API | Driver overhead; not always available |

**Recommendation**: Start with `GpuBuffer<T>` (explicit, predictable). Add unified memory as opt-in later.

---

## 6. LLVM Backend Strategy

### 6.1 Dual-Module Compilation

The core architectural requirement: **two separate LLVM modules** per compilation unit.

```
Source (.qz with @gpu)
    │
    ├── Host Module (default target: x86_64-apple-darwin)
    │   ├── main(), other host functions
    │   ├── gpu_launch() calls (CUDA runtime API)
    │   └── Data transfer intrinsics
    │
    └── Device Module (target: nvptx64-nvidia-cuda)
        ├── @gpu kernel functions
        ├── ptx_kernel calling convention
        ├── Address space 1 (global) for buffer pointers
        └── llvm.nvvm.read.ptx.sreg.* intrinsics
```

### 6.2 Changes to Codegen Pipeline

```
Current:  codegen.qz → single LLVM module → llc → binary

Proposed: codegen.qz → host LLVM module  → llc → host.o
                      → device LLVM module → llc --march=nvptx64 → kernel.ptx
                                           → ptxas → kernel.cubin
          link: host.o + CUDA runtime → binary (kernel.cubin embedded as data)
```

**Key changes**:
1. `codegen.qz` needs `emit_gpu_module()` that outputs a separate LLVM module
2. `@gpu def` functions are emitted to the device module, not the host module
3. In the host module, `@gpu def` functions are replaced with launch stubs
4. Build system (Quake) needs to orchestrate multi-target compilation

### 6.3 Address Space Mapping

```llvm
; Global memory (buffer data) — address space 1
define ptx_kernel void @vector_add(float addrspace(1)* %a,
                                    float addrspace(1)* %b,
                                    float addrspace(1)* %out) {
  %tid = call i32 @llvm.nvvm.read.ptx.sreg.tid.x()
  %a_ptr = getelementptr float, float addrspace(1)* %a, i32 %tid
  %b_ptr = getelementptr float, float addrspace(1)* %b, i32 %tid
  %av = load float, float addrspace(1)* %a_ptr
  %bv = load float, float addrspace(1)* %b_ptr
  %sum = fadd float %av, %bv
  %out_ptr = getelementptr float, float addrspace(1)* %out, i32 %tid
  store float %sum, float addrspace(1)* %out_ptr
  ret void
}
```

### 6.4 Quartz Existential Model Challenge

> [!CAUTION]
> Quartz's `i64` existential model creates a fundamental tension with GPU computing.

GPUs achieve peak performance with typed data: `float*`, `double*`, `int*`. Quartz represents everything as `i64`, which means:

1. **No float operations on GPU**: Quartz `F32` values stored as `i64` must be bitcast to `float` for GPU math
2. **Memory bandwidth waste**: Quartz stores `F32` in 8 bytes (i64) instead of 4 bytes, halving effective bandwidth
3. **No vectorization**: GPU warps can't auto-vectorize `i64` operations into `float4`

**Mitigation strategies**:
- **GPU buffer types are typed**: `GpuBuffer<F32>` allocates `float*` memory, not `i64*`
- **Kernel codegen uses native types**: Inside `@gpu def`, the compiler emits typed LLVM IR (float, double, i32) instead of i64
- **Implicit conversion at transfer boundary**: `gpu_copy_to` handles i64→float conversion

This means GPU kernels would be a **special case** in codegen — they don't use the existential model internally. This is both a simplification (typed GPU code) and a complexity (different codegen path).

---

## 7. Feasibility Assessment

### What's Feasible with Current Architecture

| Capability | Feasibility | Why |
|-----------|-------------|-----|
| Emit NVPTX IR | ✅ Easy | LLVM already supports `nvptx64` target |
| `@gpu def` parsing | ✅ Easy | Same as `@cfg`/`@derive` annotation |
| Device function outlining | ✅ Medium | Extract `@gpu` bodies into separate module |
| `gpu_launch` intrinsic | ⚠️ Medium | Needs CUDA runtime linking (`libcuda.so`) |
| Typed GPU codegen | ⚠️ Medium | Requires non-existential codegen path for kernels |
| Shared memory | ⚠️ Hard | Needs address space 3 support and `__shared__` allocation |
| AMDGPU backend | ✅ Easy | Same LLVM mechanism, different target triple |
| SPIR-V output | ⚠️ Medium | Needs `spirv-llvm-translator` or LLVM's SPIR-V backend |
| `gpu_map` auto-kernelization | ❌ Hard | Compiler must derive thread-safe kernels from lambdas |
| Unified memory | ⚠️ Medium | CUDA Managed Memory API, but driver-dependent |

### What Requires New Infrastructure

1. **Dual-module codegen**: `codegen.qz` currently emits one module. Need to split into host + device.
2. **Typed kernel codegen**: GPU kernels should use native float/int types, not i64. This requires a separate codegen path or mode flag.
3. **Build system integration**: Quake needs `llc --march=nvptx64`, `ptxas`, and multi-artifact linking.
4. **Runtime library**: Need a thin C shim for CUDA API calls (cuLaunchKernel, cuMemAlloc, etc.) — similar to how TLS uses OpenSSL via FFI.

---

## 8. Phased Implementation Plan

### Phase G.0: NVPTX Backend Probe (1 day)

- Verify LLVM can emit NVPTX IR: write a `.ll` file by hand, compile with `llc --march=nvptx64`
- Test `ptxas` compilation of the result
- Confirm thread ID intrinsics work
- Deliverable: documented proof that the LLVM toolchain works

### Phase G.1: Manual Kernel + Host Launch (3–5 days)

- Parse `@gpu` attribute on `def` declarations
- Emit `@gpu` functions into a separate device LLVM module with:
  - `ptx_kernel` calling convention
  - Address space 1 for pointer params
  - Thread ID intrinsics
- Emit host launch stubs using CUDA driver API
- Implement `gpu_alloc`, `gpu_copy_to`, `gpu_copy_from`, `gpu_free` as FFI intrinsics
- C runtime shim: `quartz_gpu_runtime.c` wrapping CUDA driver API
- Test: vector_add kernel end-to-end

### Phase G.2: `@gpu` Syntax + Data Transfer (3–5 days)

- Full `GpuBuffer<T>` type in type system
- Typed codegen for kernel bodies (float, double, i32 instead of i64)
- `gpu_sync()` barrier intrinsic
- Shared memory: `@shared var tile: Array<F32, 256>`
- Multiple kernel launches in sequence
- Grid/block dimension helpers

### Phase G.3: AMDGPU + SPIR-V + High-Level Ops (5–7 days)

- AMDGPU backend (same mechanism, different target triple + CC)
- SPIR-V output via `spirv-llvm-translator`
- `@target(gpu: "nvidia")` / `@target(gpu: "amd")` conditional compilation
- `gpu_map`, `gpu_reduce`, `gpu_scan` high-level operations
- Compiler generates kernels from lambda bodies

### Phase G.4: Auto-Parallelization + Unified Memory (5–7 days)

- `parallel_gpu(n, block_size) do idx -> ... end` inline GPU regions
- Unified memory (`@unified`) pointer types
- Automatic parallelization of `for..in` loops over GPU-mapped data
- Performance tuning: occupancy calculator, launch bounds
- Multi-GPU support (`@gpu(device: 1)`)

---

## 9. Genuine Tensions and Tradeoffs

### 1. Existential Model vs. GPU Performance

The i64 existential model is Quartz's defining feature but fundamentally at odds with GPU computing, which demands typed memory access. The proposed solution — typed codegen inside `@gpu` bodies — is pragmatic but creates two codegen paths. This is a **deliberate tradeoff**: GPU kernels are already a different execution model, so a different codegen path is acceptable.

### 2. NVIDIA-first vs. Vendor-neutral

Starting with NVPTX is pragmatic (largest ecosystem, best tooling) but creates vendor lock-in risk. The mitigation — same kernel syntax targeting different backends via `@target` — is architecturally sound but increases testing surface.

### 3. Explicit vs. Implicit Data Transfer

Explicit `gpu_copy_to`/`gpu_copy_from` is predictable but verbose. Implicit transfer (unified memory, auto-sync) is convenient but hides latency. Both should be supported, with explicit as the default and implicit as opt-in.

### 4. Compilation Model: AOT vs. JIT

Julia JIT-compiles kernels at runtime. Quartz is AOT. AOT GPU compilation requires knowing the target GPU architecture at compile time (e.g., `sm_80` for A100). This can be mitigated by emitting PTX (JIT-compiled by the CUDA driver at load time) rather than SASS.

---

## 10. References

- LLVM NVPTX Backend User Guide — llvm.org/docs/NVPTXUsage.html
- NVIDIA PTX ISA — docs.nvidia.com/cuda/parallel-thread-execution
- LLVM AMDGPU Backend — llvm.org/docs/AMDGPUUsage.html
- Futhark Language — futhark-lang.org; Henriksen et al., "Futhark: Purely Functional GPU-programming with Nested Parallelism and In-place Array Updates" (PLDI 2017)
- Halide — halide-lang.org; Ragan-Kelley et al., "Halide: A Language and Compiler for Optimizing Parallelism, Locality, and Recomputation" (PLDI 2013)
- Julia GPU Computing — juliagpu.org; Besard et al., "Effective Extensible Programming: Unleashing Julia on GPUs" (IEEE TPDS 2019)
- Khronos SPIR-V — khronos.org/spir
