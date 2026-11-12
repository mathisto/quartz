# Cache Effect — Design Memo

> **Filed:** 2026-05-01 (end of A.1+A.2-Phase-1 session, prior to A.3 work).
> **Sequencing:** Phase A.3 of the post-audit roadmap. Pre-requisite work
> already shipped (A.1 FileIo dogfood closure + A.2 Phase 1 prefix-check
> sweep). Pull-in trigger: user authorized overnight autonomous work on
> A.3 Phase 1.

## Motivation (why this effect exists)

Two recurring incidents in compiler history justify a Cache abstraction:

1. **OPEN-UFCS-HASH-SENSITIVITY UAF** (Apr 27, closed in Tier 3 #19):
   `with Alloc.in_arena(cg_arena) do -> cg_codegen ... end` left
   `_cg_last_string_pool` pointing into arena pages; `arena_destroy`
   munmapped them; the cache-write path then read through dangling
   pointers. Masked by `quake build/guard/qspec` all using `--no-cache`.
2. **`.quartz-cache/` cross-binary pollution**
   (project memory `feedback_quartz_cache_pollution.md`): cache
   populated by compiler v1 then reused by v2 produces QZ0603 +
   runtime panics on qspec/subprocess specs. Diagnostic: `rm -rf
   .quartz-cache` before cross-binary runs.

Both incidents share a root: cache I/O is mixed with the rest of file
I/O, has implicit global state (`cache_dir`, `_cache_explain`,
`_cache_enabled`), and lacks a hermetic-test escape hatch.
`with Cache.in_memory do … end` would have caught both at the spec
level instead of via cross-binary integration debugging.

Beyond bug closure, the value props the audit row promised:

- **`with Cache.in_memory do … end`** for hermetic spec tests (no
  real disk, no cross-spec pollution).
- **`with Cache.disabled do … end`** for scoped one-shot runs without
  global flag mutation.
- **`with Cache.tracing do … end`** for stderr-traced miss debugging
  (today users reach for `--cache-explain` global flag).

## Scope decisions (locked at filing time)

### Op shape: typed wrapper over existing API (not uniform key/bytes)

Existing API in `shared/build_cache.qz` has 13 typed functions including
`cache_lookup(module, hash) → String`, `cache_store(module, hash, ir)`,
`cache_save_ast(module, hash, storage, root)`, `cache_load_ast`,
`cache_save_string_pool(strings)`, `cache_load_string_pool()`, plus
state queries (`cache_is_enabled`, `cache_set_explain`, etc.).

The audit's idealized `Cache.save(key, bytes)` / `Cache.load(key) →
Option<bytes>` API would force every caller to serialize their typed
payload. AST cache uses bespoke binary format; string pool is `Vec<String>`.
Forcing serialization through bytes is a rewrite, not a migration.

**Decision: 6 effect ops mirroring the typed surface.** This matches
the FileIo precedent (4 typed ops: `fio_read`/`fio_write`/`fio_exists`/
`fio_list_dir`). Migration becomes mechanical (rename `cache_lookup` →
`cache_op_lookup`, default handler forwards to existing impl).

```quartz
effect Cache
  def cache_op_lookup(module: String, hash: String): String      # "" on miss
  def cache_op_store(module: String, hash: String, ir: String): Int
  def cache_op_save_pool(strings: Vec<String>): Int
  def cache_op_load_pool(): Vec<String>
  def cache_op_save_ast(module: String, hash: String, storage: AstStorage, root: Int): Int
  def cache_op_load_ast(module: String, hash: String): Vec<Int>   # empty on miss
end
```

State-query functions (`cache_is_enabled`, `cache_set_explain`,
`cache_get_explain`, `cache_open`, `cache_disable`, `cache_flush`,
`cache_clean`) stay outside the effect — they're build-driver
configuration, not cacheable I/O. `with Cache.disabled do … end` is
implemented as a handler that returns "" / -1 / empty for all six ops,
not by toggling `_cache_enabled`.

### Default handler shape: Quartz function + `uses_cache` gating (NOT inline IR)

FileIo's default handler is inline LLVM IR calling libc `fopen`/`fread`
directly (~80 lines). That works because filesystem ops have simple
libc-equivalent semantics.

Cache semantics are richer: hash-mismatch detection, optional
`--cache-explain` logging, `_cache_dir` global state, multi-format
payloads (string IR + serialized AST + Vec<String>). Inlining all of
this in LLVM IR per op = hundreds of lines of brittle string-built IR.

**Decision: write the default handler in Quartz**
(`@cache$cache_default_handler` in `std/cache.qz`), mirroring
`@intern$intern_default_handler` from P5.5.c. Forwards each op to its
existing `build_cache::cache_*` impl. Gated on a new `uses_cache`
compile-time flag, plumbed through the same `mir_lower_async_registry`
→ `cg_emit_effect_runtime` → `cg_emit_effect_install_defaults_fn`
chain that `uses_intern` uses today. Without gating, every program
would force-link `build_cache` + `dep_graph` + `content_hash` + their
transitive closure — bloats the freestanding/kernel build path.

### Why two fixpoint passes are mandatory

The two-pass dance protects gen0→gen1→gen2 fixpoint convergence under
new-effect introduction. Without it:

- Pass 1 ships relaxation + install + consumer migration in one commit.
- Gen0 (BEFORE binary) has no relaxation — it rejects the new
  `cache_op_lookup` calls as "missing `can Cache` row" and self-compile
  fails.

The split:

- **Pass 1:** declaration in std/cache.qz + blessed-relaxation in
  typecheck_expr_handlers.qz + Quartz default handler + uses_cache
  plumbing + install in cg_emit_effect_install_defaults_fn. Compiler
  source itself doesn't yet call any `cache_op_*`, so gen0 (without
  the relaxation) builds gen1 (with the relaxation) cleanly.
- **Pass 2:** migrate one consumer site. Gen1 (which has the
  relaxation) builds gen2 cleanly because it accepts the new calls.
- **Pass 3+:** migrate remaining 5 ops + their consumers, commit by
  commit.

Reference for the discipline: comments at `typecheck_expr_handlers.qz`
lines 1633-1645 (Intern P5.5.c) and 1640-1645 (Alloc A.3.a).

## Recipe — Pass 1 (effect mechanism, no consumer migration)

### File: `std/cache.qz` — new file

Mirror `std/intern.qz` shape. Three sections: docstring with usage
examples; effect declaration with 6 op signatures (see "Op shape"
above); single dispatching default handler.

```quartz
import build_cache

effect Cache
  # ... 6 ops as above ...
end

def cache_default_handler(op_name: Int, argc: Int, argv: Int): Int
  var op = as_string(op_name)
  if op == "cache_op_lookup"
    var module = as_string(load(argv, 0))
    var hash = as_string(load(argv, 1))
    return as_int(build_cache::cache_lookup(module, hash))
  end
  if op == "cache_op_store"
    var module = as_string(load(argv, 0))
    var hash = as_string(load(argv, 1))
    var ir = as_string(load(argv, 2))
    build_cache::cache_store(module, hash, ir)
    return 0
  end
  # ... other 4 ops ...
  return 0
end
```

### File: `self-hosted/backend/codegen_runtime.qz`

**Two edits in both linkonce + internal branches** (lines ~509 and
~535) add the effect-name + op-name string globals:

```llvm
@__qz_eff_name_cache = linkonce_odr unnamed_addr constant [6 x i8] c"Cache\00", align 1
@__qz_eff_op_cache_op_lookup = linkonce_odr unnamed_addr constant [16 x i8] c"cache_op_lookup\00", align 1
# ... 5 more op-name globals ...
```

**One edit at `cg_emit_effect_install_defaults_fn` (line ~1465)** —
copy the Intern install pattern:

```quartz
if uses_cache == 1
  codegen_util::cg_emit_line(out, "  %eff_cache_ptr = ptrtoint ptr @cache$cache_default_handler to i64")
  codegen_util::cg_emit_line(out, "  call void @__qz_effect_handle_install(ptr @__qz_eff_name_cache, i64 %eff_cache_ptr, i64 0, ptr null)")
end
```

**Plumbing edits** to thread `uses_cache` through:

- `cg_emit_effect_runtime` signature line 72: add `uses_cache: Int`
  parameter.
- `cg_emit_effect_install_defaults_fn` signature line 1442: same.
- `cg_emit_effect_main_prelude` signature line 1428: same.
- All callers updated.

### File: `self-hosted/middle/typecheck_expr_handlers.qz`

**One edit at line 1648** adding `Cache` to the blessed-relaxation OR
chain:

```quartz
if _c3_eff_name.eq("Throws") or _c3_eff_name.eq("Log") or _c3_eff_name.eq("FileIo") or _c3_eff_name.eq("Intern") or _c3_eff_name.eq("Alloc") or _c3_eff_name.eq("Cache")
  _c3_covered = true
end
```

Mirror the comment pattern at lines 1637-1645 explaining why the
two-pass fixpoint protects this addition.

### File: `self-hosted/backend/mir_lower_async_registry.qz`

**Add cache op detection.** Find where `uses_intern` is set (search
for `mir_record_uses_intern` or similar — pattern is "MIR walks
function bodies, sees an op call to an Intern op name, sets the flag").
Mirror for the 6 cache_op_* names.

### Verification

1. `./self-hosted/bin/quake guard` — fixpoint must hold (2,428 → ?
   functions; expect +1-3 for `cache_default_handler` and possibly
   helper closures).
2. `./self-hosted/bin/quartz examples/style_demo.qz | …` smoke
3. Existing FileIo specs (`file_io_effect_p54a` 5/5,
   `file_io_build_cache_p54b` 3/3) still green.
4. New `spec/qspec/cache_effect_pass1_spec.qz` — proves the effect is
   declared + relaxation works (a `cache_op_lookup("foo", "bar")`
   call typechecks without `can Cache` row, and at runtime forwards to
   the default handler which returns "" because the cache file
   doesn't exist).

### Commit shape

Single commit `[a3/cache] Phase 1: Cache effect mechanism (pass 1
infrastructure)`. Title MUST include "pass 1 infrastructure" so the
two-pass dance is obvious in `git log`.

Approximate diff size:
- `std/cache.qz`: ~80 lines new
- `codegen_runtime.qz`: ~30 lines added (string globals × 14 lines × 2
  branches + 4 lines install + signature plumbing)
- `typecheck_expr_handlers.qz`: ~3 lines (1 OR clause + 2 comment lines)
- `mir_lower_async_registry.qz`: ~10 lines (op-name registry)
- callers of changed signatures: 2-3 sites

## Recipe — Pass 2 (single-consumer migration)

### File: `self-hosted/quartz.qz` line 504

Replace the one consumer call:

```quartz
# Before
var cached_ir = build_cache::cache_lookup(filename, cache_key)

# After
import file_io        # already imported
import cache          # NEW

var cached_ir = cache_op_lookup(filename, cache_key)
```

### Verification

1. `./self-hosted/bin/quake guard` — fixpoint stamp updates, new
   `uses_cache` flag fires for self-compile.
2. Smoke as above.
3. New `spec/qspec/cache_effect_pass2_spec.qz` — installs a custom
   handler `with Cache { cache_op_lookup: my_mock } do -> compile(…)
   end`, asserts the mock fires + receives the expected (module, hash)
   args. This validates the test-handler value prop end-to-end.

### Commit shape

Single commit `[a3/cache] Phase 1: migrate cache_lookup callsite to
Cache.cache_op_lookup (pass 2 consumer)`.

## Hazard map

- **Mangled-symbol guess for default handler.** Quartz mangles
  `cache$cache_default_handler` for `def cache_default_handler` in
  `std/cache.qz`. Verify via `grep "@cache\$cache_default_handler"
  /tmp/main.ll` after first build; the inline-IR install site
  references this exact symbol.
- **`as_string(op_name)` decoding.** The handler ABI is `(op_name:
  Int, argc: Int, argv: Int): Int` — `op_name` is a String i64 handle,
  not a raw Int. Decode with `as_string(op_name)` (already imported
  from std prelude). Same convention as FileIo's `cstr_eq` dispatch,
  but in Quartz code.
- **`build_cache` import in `std/cache.qz`** introduces a stdlib →
  compiler-internal dependency. Verify this doesn't break standalone
  user programs that `import std/cache` — they need `build_cache`
  too. Likely fine (build_cache itself only depends on `file_io`,
  `string_intern`, `dep_graph` — all already importable).
  **If circular:** flatten by inlining the cache_lookup body into
  `cache_default_handler` (path construction + fio_read).
- **`uses_cache` plumbing must fire on cache_op_* calls, not on
  cache_lookup calls.** The MIR walk needs to recognize the EFFECT OP
  names as the trigger. Easy to confuse with the IMPL function names.
- **Two-pass fixpoint regression:** if pass 1 ships and gen1 build
  fails (gen0 doesn't know cache_op_lookup yet), the relaxation alone
  isn't enough — the OP NAMES need to be recognized as effect ops by
  the typechecker. Mirror Intern's recognition path, which is what
  `mir_record_uses_intern` ties together.
- **Don't run RAM-heavy bug repros to verify a fix** (project memory
  `feedback_dont_run_ram_heavy_repros.md`): fixpoint + targeted spec
  is the verification path.

## Pass 3+ (deferred — pull-in conditional)

If Phase 1 lands clean, the remaining 5 ops migrate by op-name across
~30 callsites in quartz.qz / resolver.qz / codegen_separate.qz. Order
by callsite density:

- `cache_op_store` (paired with cache_op_lookup at the same call site)
- `cache_op_save_pool` / `cache_op_load_pool` (string pool round-trip)
- `cache_op_save_ast` / `cache_op_load_ast` (resolver AST roundtrip)

Each op gets a single commit (or paired with its inverse). Final
commit migrates the direct `fio_write(".quartz-cache/whole_program.ll",
…)` writes — though arguably those stay as FileIo since they're plain
file I/O, not hash-keyed cache ops.

## Test handler examples (post-Phase-1 deliverables)

`std/cache.qz` should ship three handler factories alongside the
default:

```quartz
# In-memory cache for hermetic tests. Returns "" on every lookup
# unless populated via cache_op_store first.
def cache_in_memory_handler(...): Int = ...

# Disabled cache: every op returns sentinel-miss. Equivalent to
# --no-cache but scoped to a `with` block.
def cache_disabled_handler(...): Int = ...

# Tracing wrapper: logs each (op, args) tuple to stderr, then forwards
# to a wrapped handler. Useful for miss-debugging.
def cache_tracing_handler(wrapped: Int): Fn = ...
```

Spec coverage: one `it` per handler × 6 ops = 18 tests at the
`cache_effect_handlers_spec.qz` level once all 6 ops migrate.

## Calibration note

The audit row claimed "28 cache touchpoints, ~1-2 quartz-days." Reality
at HEAD: ~30 callsites (close enough), but the work is meaningfully
larger than 1-2 days because the Intern-shape default handler + uses_cache
plumbing is non-mechanical work plus a 2-pass fixpoint dance. Realistic
sizing: **Phase 1 (mechanism + 1-op consumer) = 4-6 hours real /
1 quartz-day**; **Phase 2 (5 remaining ops + ~30 callsites) = 1-2
quartz-days**. The original "1-2 quartz-day" framing rolled the two
together optimistically — it's two distinct phases, sequenced.
