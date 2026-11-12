# `state.loop_metadata_ids` accumulates duplicates from cached fragment headers

> **Filed**: 2026-05-05 during TUI Phase 7. Surfaced when the SSA
> numbering shifted under the per-signum `signal_on_flag` table
> change; latent before that.
> **Status**: CLOSED 2026-05-05 — dedup added at emit site
> (`cg_emit_loop_metadata`, `codegen_util.qz`). Linear scan + skip
> in the per-id loop; `tui_confirm_spec` and the rest of the suite
> compile cleanly with the cache warm. Quake guard verified.
> **Impact at filing**: low (one spec affected at filing time,
> `tui_confirm_spec.qz`), latent (bound to surface again as the
> codebase grew). The error aborted `llc`, so any spec / program
> where the cached metadata header parsed into duplicates couldn't
> run.

## Reproducer

The `tui_confirm_spec.qz` build pipeline:

```bash
./self-hosted/bin/quartz spec/qspec/tui_confirm_spec.qz > /tmp/cf.ll
llc -filetype=obj /tmp/cf.ll -o /tmp/cf.o
# llc: error: Metadata id is already used
#   !88577 = !{!"llvm.loop.vectorize.enable", i1 1}
```

Two identical metadata-definition triplets emitted at
`/tmp/cf.ll:171241` and `:171289` (~48 lines apart):

```
!88576 = distinct !{!88576, !88577}
!88577 = !{!"llvm.loop.vectorize.enable", i1 1}
!88578 = distinct !{!88578, !88579}
```

`--no-cache` makes the duplicate go away — only triggered when the
separate-compilation cache is warm.

## Cause

`self-hosted/backend/codegen_separate.qz` parses cached fragment
headers of the form `META:id1,id2,...\n---\n<IR>` and pushes each
parsed id back into `state.loop_metadata_ids`:

```be
# codegen_separate.qz:209
state.loop_metadata_ids.push(str_to_int(md_parts[mi]))
```

If the same module's fragment is loaded twice (which can happen
under the per-module fragment caching scheme), the same metadata
ids get pushed twice. At the end of compilation,
`cg_emit_loop_metadata` in `codegen_util.qz:553-570` iterates the
array and emits one definition per element — so duplicate ids
produce duplicate definitions.

## Fix sketch

Either:

1. **At push site** (`codegen_separate.qz:209`): dedup before push.
   Linear scan over `state.loop_metadata_ids` — if id already
   present, skip. O(N²) but the array stays small.

2. **At emit site** (`codegen_util.qz:553-570`): dedup the array
   before iteration. `vec_unique` or hand-rolled set-build.

Option 2 is more conservative (catches all duplicate sources, not
just the cached-fragment one). Option 1 is more localised.

The dedup should preserve order — metadata ids are referenced by
name, not position, but order-preserving keeps diffs stable across
clean / cached builds.

## What works

- `--no-cache` flag avoids the cached-fragment header parse path.
- Specs other than `tui_confirm_spec` don't reproduce. Suggests the
  duplicate is a function of which modules are in the cache and the
  order they're loaded.

## Confirmation steps

1. Warm the cache via any spec build (e.g. `tui_help_spec`).
2. Build `tui_confirm_spec`. Expect the `Metadata id is already used`
   error from llc on the resulting `.ll`.
3. Add `--no-cache` to the quartz invocation. Expect success.
