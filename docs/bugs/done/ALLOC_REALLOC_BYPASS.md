# Vec/String realloc paths bypass the Alloc effect wrapper

**Status**: ✅ FIXED 2026-04-27 in Phase A.3.d.
**First observed**: 2026-04-27, during Phase B.2 spec authoring.
**Closed by**: Phase A.3.d (this same day) — emit `@__qz_realloc(ptr old, i64 old_bytes, i64 new_bytes) -> ptr` wrapper in `codegen_runtime.qz`, decompose on routing path into `alloc(new) + memcpy(min) + dealloc(old)` via the existing two-op Alloc surface (no third op added — D1 minimal preserved). 13 emit sites migrated across `codegen_runtime.qz` (3), `cg_intrinsic_sb.qz` (4), `cg_intrinsic_vec.qz` (3), `cg_intrinsic_conc_task.qz` (2), `cg_intrinsic_regex.qz` (1). The bug doc undercounted (said 3, actually 13). Acceptance spec at `spec/qspec/alloc_realloc_a3d_spec.qz` (5 tests). Fixpoint 2347 functions byte-identical (+1 from B.5's 2346 = the new wrapper).
**Affected sites (historical)**: 13 `@realloc` emit sites across 5 codegen files.

## Summary

Phase A.3.c migrated ~178 raw `@malloc`/`@free` emit sites in the codegen layer to the unified `@__qz_alloc`/`@__qz_dealloc` runtime wrapper, restoring the "compiler dogfood is one `with Alloc` block away" invariant claimed by the design memo. The migration sweep missed three `@realloc` sites:

- `qz_vec_push_impl` (line ~6482) — Vec growth on push past current capacity.
- A second realloc site at line ~6609 — likely Vec or String related.
- A third realloc site at line ~7070 — likely String or buffer growth.

Effect: when a user installs a custom `with Alloc { ... } do body end` (or any of B.1–B.4's call-form sugars: `Alloc.in_arena(ar)`, `Alloc.deny_all()`, `Alloc.with_budget(N)`, `with TestAlloc do ... end`), Vec/String operations that grow via `realloc` SILENTLY BYPASS the user handler. The first-allocation path through `vec_new` / `qz_str_new` correctly routes through the wrapper (so the user handler observes the initial buffer); subsequent growth via `realloc` does not.

In the B.2 TestAlloc context, this manifests as a SIGABRT when `Vec.push` triggers growth: the original buffer is arena-allocated (via the wrapper → arena_alloc handler), but the `@realloc` call invokes libc's `realloc` directly — which is undefined behavior on a non-libc-malloc'd pointer (libc's realloc walks malloc metadata that the arena pointer doesn't have).

## Reproducer (smaller-than-spec form)

```quartz
import std/alloc
import std/memory

def main(): Int
  with TestAlloc do ->
    var v = vec_new<Int>()
    var i = 0
    while i < 16  # crosses the cap-doubling threshold
      v.push(i)
      i += 1
    end
    puts("size=" + str_from_int(v.size))
  end
  return 0
end
```

Compile + run: SIGABRT (rc=134) the moment `v.push` triggers a `realloc(arena_ptr, ...)`.

A version with only 3 pushes (cap=4 initial) does not realloc and runs fine, because the very first push hits `realloc(NULL, 32)` which libc treats as `malloc(32)` — the original buffer comes from libc, never from the user's arena.

## Why the dogfood story still holds for non-Vec workloads

User code that allocates via `alloc(N)` directly (not through Vec/String/Map) routes correctly. Manual struct allocation, raw byte buffers via `mem_alloc`, `arena_alloc` calls, `Foo { ... }` struct heap allocation, channel/mutex/cond construction — all go through `@__qz_alloc`. Only the `realloc`-based growth of dynamic containers slips through.

## Fix shape

Mirror the A.3.c.1 pattern:

1. Emit a `@__qz_realloc(ptr old, i64 new_bytes) -> ptr` runtime wrapper in `codegen_runtime.qz`. Body:
   - Bypass-flag check on `@__qz_alloc_in_handler` (same as `@__qz_alloc`).
   - On bypass: direct `call ptr @realloc(ptr %old, i64 %new_bytes)`.
   - On routing: `__qz_effect_perform(@__qz_eff_name_alloc, @__qz_eff_op_realloc, 2, &args, ...)` — but this requires adding a third op to the Alloc effect: `realloc(ptr: CPtr, new_size: Int): CPtr`. OR collapse to "alloc new + memcpy + dealloc old" if the user handler doesn't have a realloc op (cleaner; works for arena-style handlers where the old pointer's bytes are still valid in the arena, just unreferenced).
2. Migrate the three `@realloc` sites in `codegen_runtime.qz` to call the wrapper.
3. Add a 4th op to the `Alloc` effect (`std/alloc.qz`): `realloc(p: CPtr, n: Int): CPtr`. The default handler forwards to `@realloc`. Arena handlers do "alloc new, memcpy, return new" (don't free old — arena bulk-frees). Counter handlers track the delta. Tracking handlers count it as a separate op.
4. Handle the `realloc(NULL, N)` case: forward to alloc.
5. Handle the `realloc(p, 0)` case: forward to dealloc.

Roughly **A.3.c-shaped work** — half a quartz-day for the wrapper + audit + migrate, plus another half for the spec coverage and Alloc-effect surface extension.

## Related

- The A.3.c session log explicitly enumerates the 18 codegen files covered. `codegen_runtime.qz` was migrated for `@malloc`/`@free` but the `@realloc` audit was missed.
- ALLOC_EFFECT_PLAN.md "Phase B followups" — file this there as a pull-in trigger when a real user pattern needs Vec/String routing through Alloc.
- Phase D (compiler arena dogfood) is partly blocked by this: the compiler's own Vec usage won't route through phase arenas until @realloc is wrappered.

## Workaround (today)

In specs and user code that need to demonstrate `with Alloc {...} do body end` coverage of dynamic containers, allocate manually via `alloc(N)` instead of using Vec.push / String.concat in the body. The Phase B.2 acceptance spec uses this workaround for its multi-alloc routing test.
