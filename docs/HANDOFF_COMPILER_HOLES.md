# Handoff: Compiler Hole Sprint

**For:** the next Claude Code session, starting fresh
**Last session ended:** Apr 13 2026 ~15:30, commit `0e6087bb`
**State at handoff:** tree clean, fixpoint 2257 functions, smoke tests green, all today's session work committed

---

## Read this first

The previous session shipped the API unification sprint end-to-end (Phases 6, 7, 8, 9, 10) and audited the Apr 12 triage tail (closed 9 stale entries, 1 real fix). Three new compiler bugs were discovered and filed during the work but **not** fixed because each is deeper than fits in a single autonomous slot. **This handoff is about closing those three holes.**

The bugs are sequenced by impact and effort:

| Bug                          | Effort | Reproducer  | Unblocks                                       |
|------------------------------|--------|-------------|-----------------------------------------------|
| **MULTI-CLAUSE-1**           | 2-4h   | 6-line .qz  | `expr_eval.qz` smoke test (16 more PASS lines), pattern-matched function defs  |
| **MAP-NEW-DECLARE-MISSING**  | 1-2h   | one fn      | `group_by` in stdlib, any prelude-level `Map<Int,V>` use      |
| **UNKNOWN-VARIANT-MATCH**    | 30m-1h | 8-line .qz  | safety net catching enum typos before runtime |

Total: 3-7 hours quartz-time, one focused session.

If you finish all three, the bonus item is **the Iterable trait redesign** — a design discussion that needs user input before any code, sketched at the bottom of this doc.

---

## State at handoff

- **Branch**: `trunk`
- **HEAD**: `0e6087bb` — MULTI-CLAUSE-1 investigation findings + rebuild
- **Fixpoint**: verified at 2257 functions
- **Smoke tests**: `quake smoke` passes — brainfuck 4/4, expr_eval matches baseline (14 lines through MULTI-CLAUSE-1 crash)
- **Working tree**: clean
- **Backups in `self-hosted/bin/backups/`**:
  - `quartz-001`, `quartz-002`, `quartz-prev` — deep fossils, do not delete
  - `quartz-golden` — rolling state, managed by `quake guard`, do not touch
  - `quartz-pre-multi-clause-fix-golden` — from prior session's failed MULTI-CLAUSE-1 attempt; can be deleted after this session if MULTI-CLAUSE-1 lands
  - `quartz-pre-{any-all-predicate-suffix,emit-deps,range-ufcs,unified-cache,verb-pair-ufcs}-golden` — from earlier today, also deletable
- **Smoke test discipline**: run `quake smoke` after every guard. The baseline at `spec/snapshots/expr_eval_baseline.txt` is the 6 PASS lines + crash that the current binary produces. Update via `quake smoke:update` only when MULTI-CLAUSE-1 is fixed.

---

## Files to read first in order

1. **`docs/ROADMAP.md` lines 543-580** — the "Open compiler issues" table. Three entries to fix:
   - `MULTI-CLAUSE-1` — has the full investigation findings from the prior session
   - `MAP-NEW-DECLARE-MISSING` — has reproducer + suspected root cause
   - (third bug, **UNKNOWN-VARIANT-MATCH**, is mentioned in commit `7cb8d241` body but not yet filed — file it during this session)
2. **`self-hosted/resolver.qz` lines 564-755** — `resolve_build_clause_arm` and `resolve_merge_clauses`. This is where multi-clause defs get desugared into a synthetic match expression. The MULTI-CLAUSE-1 bug lives somewhere in this region or downstream of it.
3. **`self-hosted/middle/typecheck_expr_handlers.qz` lines 820-905** — `tc_expr_match` arm typechecking. The "Match arm type mismatch" error comes from line 880. Understanding the line/col attribution is critical: `body_line = ast::ast_get_line(ast_storage, body)` reads from the AST node, but the error reporter prints the user's filename — that's why MULTI-CLAUSE-1 errors say `/tmp/min_fib3.qz:161` even though the file is 6 lines long.
4. **`std/prelude.qz` lines 157-191** — `result_and_then` and `option_and_then`, the two functions that fail typecheck under MULTI-CLAUSE-1. Both share the same shape: first arm is `f(v)` (a generic call), second arm is a constructor. The compiler thinks `f(v)` returns Int while the constructor returns Result/Option, hence the mismatch.
5. **`spec/qspec/collection_stubs_spec.qz`** — the 20-passing-1-pending spec that's blocked on MAP-NEW-DECLARE-MISSING. The `group_by` test is the canary.

---

## Bug 1: MULTI-CLAUSE-1 (do this first, biggest payoff)

### Reproducer

```be
def f(0): Int = 100
def f(n: Int): Int = n * 2

def main(): Int = 42
```

```bash
./self-hosted/bin/quartz --no-cache /tmp/repro.qz
```

Produces:
```
error[QZ0202]: Match arm type mismatch: expected 'Int', found 'Result' (first arm at line 160)
  --> /tmp/repro.qz:161:23
error[QZ0202]: Match arm type mismatch: expected 'Int', found 'Option' (first arm at line 188)
  --> /tmp/repro.qz:189:21
```

### Why the error attribution is misleading

The line numbers (161, 189) and the file path (`/tmp/repro.qz`) **don't agree**. The file is 6 lines. The line numbers come from `std/prelude.qz` at `result_and_then` and `option_and_then`. The compiler is printing the **user file name** with the **prelude AST line/col**.

This is itself a sub-bug worth fixing — the typecheck error reporter should honor the `ast_get_file` of the failing node, not the current compilation context's filename. Fixing it would surface the next investigator immediately to the right file.

### What the prior session learned (and why my fix attempt failed)

**Hypothesis 1 (wrong):** the resolver's `resolve_build_clause_arm` doesn't handle expression-bodied defs. Looking at line 647-651 of `resolver.qz`:

```be
var orig_stmts = ast::ast_get_children(ast_store, orig_body)
if orig_stmts > 0
  for si in 0..vec_size(orig_stmts)
    body_stmts.push(orig_stmts[si])
  end
end
```

For `def f(n) = n * 2` (expression body), `orig_body` is the binary expression `n * 2`, which has no `children` slot, so `orig_stmts == 0` and the arm body gets nothing pushed. The resulting arm body is just the let-bindings (or empty for arm 0). This **looked** like the bug — empty arm bodies should produce a typecheck error.

I added a wrapper: detect non-block `orig_body`, wrap in `ast::ast_return(ast_store, orig_body, line, col)`, push that. Built. Ran. **Same error**. Reverted (now in commit `0e6087bb`).

So the empty-arm-body issue may still be a real sub-bug worth fixing (it almost certainly explains the runtime SIGSEGV that follows when the typecheck error is bypassed via cache), but it's **not** the cause of the typecheck error itself.

**Hypothesis 2 (the real one, untested):** the resolver's multi-clause desugaring corrupts shared type state used by prelude's typecheck pass. The clue is that `result_and_then` and `option_and_then` both fail with the **same shape**: first arm is a generic `f(v)` call, second arm is a constructor. The typechecker thinks `f(v)` returns Int (where it should return `Result<U,E>` / `Option<U>`), while the constructor produces the proper enum type. Result: type mismatch.

The "Int" symptom suggests **existential-type stripping**: somewhere the typechecker is reading the underlying `i64` representation of `f(v)`'s return instead of the wrapping `Result<U,E>` ptype. This happens when the type ID for a generic Result instantiation gets reset or overwritten.

### Where to start the investigation

1. **Run with `--explain QZ0202`** to confirm the error code and any official guidance.
2. **Trace `tc_expr_call` on `f(v)`** in `result_and_then` when prelude is being typechecked. Specifically: what type does the call return when the user file has multi-clause defs vs when it doesn't? You can A/B this by running the compiler on `/tmp/no_mc.qz` (no multi-clause) vs `/tmp/just_mc.qz` (has multi-clause) and comparing — both with `--no-cache`.
3. **Look at `tc_check_function`** for how it typechecks the merged dispatch function. The merged function has return type Int (from `def f(0): Int`), and its body is the synthetic match. The typechecker walks the match, walks each arm, walks the let-bindings + (in the original code) the empty body_stmts. Somewhere in there the typechecker may be *registering* type IDs that then collide with prelude's Result/Option type IDs.
4. **Check `tc_make_ptype` / `tc_register_type`** for ptype assignment. Multi-clause desugaring may be calling these in a way that overwrites or shifts existing type entries.
5. **Try `--explain-cache`** to see what's in the cache. The bug only manifests with `--no-cache` because cached prelude typecheck reuses pre-computed type IDs that aren't affected by the multi-clause desugar.

### Definition of done for MULTI-CLAUSE-1

1. The reproducer above compiles cleanly with `--no-cache`.
2. `expr_eval.qz` runs to completion, all 22 PASS lines (not just the first 6).
3. `tools/smoke_test.sh --update` regenerates the baseline to the full 22-line output.
4. `stress_pattern_matching_spec` and `cross_defer_safety_spec` both still pass (regression check).
5. `quake guard` passes, fixpoint verified.
6. `quake smoke` passes with the new baseline.
7. ROADMAP MULTI-CLAUSE-1 entry marked `~~RESOLVED~~` with commit reference.

### Backup discipline for this fix

This is a deep compiler change. **Take a fix-specific backup before the first edit:**

```bash
cp self-hosted/bin/quartz self-hosted/bin/backups/quartz-pre-multi-clause-fix-golden-v2
```

(The `-v2` because there's already a `quartz-pre-multi-clause-fix-golden` from the prior failed attempt.)

---

## Bug 2: MAP-NEW-DECLARE-MISSING

### Reproducer

Add this function to `std/prelude.qz` and try to compile any program:

```be
def repro_map_dispatch(): Int
  var result: Map<Int, Vec<Int>> = map_new()
  result.set(1, vec_new())
  return result.size
end
```

Compile any program that imports prelude (which is all of them):

```bash
./self-hosted/bin/quartz examples/brainfuck.qz > /tmp/x.ll 2>/dev/null
llc -filetype=obj /tmp/x.ll -o /tmp/x.o
```

Produces:
```
llc: error: use of undefined value '@hashmap_new'
  %v = call i64 @hashmap_new()
```

The IR contains exactly **one** reference to `@hashmap_new` (the call) and **zero** declarations.

### What's already known

- The same `map_new()` pattern works at the **top level** of a QSpec test. Only fails when `map_new()` is called from inside a stdlib function (specifically a function in prelude that's then inlined into user code).
- With or without an explicit `Map<Int, Vec<Int>>` type annotation on the binding.
- The Map dispatch table at `typecheck_expr_handlers.qz` lines 1487-1571 routes Int-key maps to intmap and String-key maps to hashmap. With Int keys it should be emitting `@intmap_new()`, not `@hashmap_new()`. So there are actually TWO bugs here:
  1. The Map dispatch isn't seeing the Int key annotation in this context, so it falls back to hashmap (string-key default).
  2. The FFI declaration emission for `hashmap_new` doesn't fire when the call is in an inlined-from-prelude function.

### Investigation path

1. **Trace `slot2` reading in codegen.** The unification work stores the key type in `slot2` of the call instruction. For `map_new()` called from a prelude function, what does `slot2` contain when codegen emits the call?
2. **Check the inliner.** `egraph_opt.qz` `eg_inline_call` — does it preserve `slot2` when inlining? The CMP-MAP-FOLLOWUP fix (already landed) addressed this for `map_*` calls in general, but `map_new` specifically may not be covered.
3. **Check FFI declaration dedup.** `codegen_runtime.qz` (or wherever `declare i64 @hashmap_new()` should be emitted). The dedup pass fixed in commit `e8efa41a` may be excluding hashmap_new in this context.
4. **Quick win:** if the dispatch correctly routes to `@intmap_new()` and that declaration IS emitted (because intmap is the correct path for Int keys), the second bug disappears. So fixing the slot2 propagation may be sufficient.

### Definition of done for MAP-NEW-DECLARE-MISSING

1. The `group_by` function I had written gets restored to `std/prelude.qz`:
   ```be
   def group_by(v: Vec<Int>, key_fn: Fn(Int): Int): Map<Int, Vec<Int>>
     var result: Map<Int, Vec<Int>> = map_new()
     var i = 0
     while i < v.size
       var x = v[i]
       var k = key_fn(x)
       if result.has(k)
         var bucket: Vec<Int> = result.get(k).unwrap()
         bucket.push(x)
       else
         var bucket = vec_new<Int>()
         bucket.push(x)
         result.set(k, bucket)
       end
       i += 1
     end
     return result
   end
   ```
2. The `it_pending` block in `spec/qspec/collection_stubs_spec.qz` (around line 235-238) becomes a real test:
   ```be
   describe("group_by") do ->
     it("groups elements by key function") do ->
       var v = [10, 21, 30, 41, 50]
       var groups = group_by(v, (x: Int) -> x % 2)
       var evens: Vec<Int> = groups.get(0).unwrap()
       var odds: Vec<Int> = groups.get(1).unwrap()
       assert_eq(evens.size, 3)
       assert_eq(odds.size, 2)
     end
   end
   ```
3. `collection_stubs_spec`: 21/21 green (currently 20 + 1 pending).
4. ROADMAP MAP-NEW-DECLARE-MISSING entry marked `~~RESOLVED~~`.

---

## Bug 3: UNKNOWN-VARIANT-MATCH (file + fix)

### Background

This bug was discovered while auditing the Apr 12 triage tail (commit `7cb8d241`). It's noted in that commit body but **not yet filed** in the ROADMAP "Open compiler issues" table. **Step 1 is to file it.**

### Reproducer

```be
enum MyEnum
  Foo(value: Int)
  Bar
end

def main(): Int
  var x = MyEnum::Foo(42)
  match x
    NotAReal(v) => return v
    AlsoFake => return 0
  end
end
```

The match references `NotAReal` and `AlsoFake` — neither exists in `MyEnum`. The compiler should produce a typecheck error like `QZ02xx: pattern 'NotAReal' is not a variant of MyEnum`. Instead, it emits LLVM IR that llc rejects with some downstream error (or, depending on the codegen path, produces a binary that runs to undefined behavior).

### Why this matters

This is a quiet correctness hole. Users with typos in match arm patterns (e.g. autocomplete suggesting `Some` from Option when they meant `MySome` from MyOption) get bad IR / runtime crashes instead of a clear error message. The previous session hit exactly this — `stress_pattern_matching_spec` had `match x with MySome(v) => ...` against an enum declaring `Some(v)`, and the symptom was `llc failed`, not a typecheck error.

### Investigation path

1. **Find where match arm patterns get validated.** Likely `tc_check_match_pattern` or `tc_bind_pattern_variables` in `typecheck_expr_handlers.qz`. Check how unqualified variant patterns (`Foo` vs `MyEnum::Foo`) get resolved against the subject's enum type.
2. **The fix is probably one of:**
   - Add an "unknown variant" check after pattern binding fails to find the variant in the subject's enum.
   - Reject the pattern at parse time if the variant doesn't appear in any enum in scope.
   - Emit `tc_error(...)` instead of returning a default type when the variant lookup fails.
3. **Test that legitimate unqualified variants still work** — `Some(v) => ...` against an Option subject should still resolve correctly via the existing variant lookup mechanism.

### Definition of done

1. ROADMAP entry filed in the "Open compiler issues" table with the reproducer above.
2. The reproducer compiles to a clean QZ02xx typecheck error (not bad IR).
3. New regression spec at `spec/qspec/match_unknown_variant_spec.qz` with at least 3 cases:
   - Unknown unqualified variant
   - Unknown qualified variant (`MyEnum::NotReal`)
   - Variant from a different enum (`Option::Some` against a `Result` subject)
4. `quake guard` passes, fixpoint verified.
5. `quake smoke` passes (no regression in existing match-using specs).

---

## Bonus item (only if Bugs 1-3 are done): Iterable trait redesign

**Do not start this without user input.** The trait shape is a design decision.

### Background

`std/traits.qz:130-137` has a thin `Iterable<T>` trait with a single `iter(): Int` method that returns 0 by default. It's basically unused — collections work via the compiler's `$iter`/`$next` protocol, not via the trait. The previous session deferred a redesign in commit `29bb785d` (Phase 8 Container) because it needs design discussion.

### Open design questions

1. **Existential vs concrete return type for `iter()`.** Current: `iter(): Int` (existential — concrete iterator type erased to i64). Alternative: parameterize over the iterator type (`iter(): impl Iterator<T>`). The existential approach is simpler but less expressive; the concrete approach is more useful for bounded generics but requires `impl Trait` return types which Quartz may or may not have today.
2. **Methods on the trait.** Container has `size`/`is_empty`/`clear`. Iterable needs at least `iter`. Should it ALSO have `each`, `to_vec`, `size`, `empty?`, etc.? If yes, there's overlap with Container — should Iterable extend Container? Or should the methods be distinct?
3. **Auto-satisfaction via empty `impl Iterable for X end`** — currently works for Container. Same model for Iterable, or different?
4. **Which collections get explicit impls?** All user collections in `std/collections/` already define `iter()` returning a concrete iterator struct (StackIter, PQIter, etc.). Adding `impl Iterable<Int> for Stack end` etc. is mostly a documentation/discoverability move.

### What the next session should do (if Bugs 1-3 finish first)

1. Read `std/traits.qz`, `std/iter.qz`, and the 6 user collection files in `std/collections/`.
2. Sketch 2-3 trait-shape options with tradeoffs.
3. **Stop and present to user for decision.** Do not implement until the user picks a shape.

---

## What NOT to do this session

- **Don't skip `quake smoke`.** Run it after every guard. The discipline is: edit → build → test → guard → smoke → commit. If smoke fails (anything diverges from the baseline), stop and investigate before committing.
- **Don't bypass `--no-cache` when reproducing MULTI-CLAUSE-1.** The bug only manifests without cache. Cached runs lie.
- **Don't take the fix-specific backup AFTER you've already started editing.** The Apr 11 incident lost a week of work because the rolling golden got overwritten mid-debugging. The fix-specific backup is your escape hatch — take it before the first source edit, never overwrite it until the fix is committed.
- **Don't assume my MULTI-CLAUSE-1 hypothesis is correct.** I tested the expression-body wrapping fix and it didn't help. The real bug is somewhere else, probably in how prelude is typechecked relative to user code. Read the investigation findings in `0e6087bb` and the ROADMAP entry, but treat them as starting hints, not gospel.
- **Don't try to do MULTI-CLAUSE-1 + Iterable redesign in the same session.** The redesign needs user-in-the-loop. Either finish the bug fixes and stop, or finish them and move to a fresh prompt for the design discussion.

---

## What TO do, in order

1. **Take fix-specific backups** for any compiler-touching work:
   - `cp self-hosted/bin/quartz self-hosted/bin/backups/quartz-pre-multi-clause-fix-golden-v2`
2. **Fix MULTI-CLAUSE-1.** See bug 1 above. This is the biggest win.
3. **Run `quake guard` + `quake smoke`** after the fix lands. The smoke baseline should now show 22 PASS lines for expr_eval, not 6. Update with `quake smoke:update` and commit alongside the fix.
4. **Fix MAP-NEW-DECLARE-MISSING.** See bug 2. Restore `group_by` to prelude. Update `collection_stubs_spec` to remove the `it_pending` placeholder.
5. **File and fix UNKNOWN-VARIANT-MATCH.** See bug 3. ROADMAP entry first, then fix, then regression spec.
6. **Final guard + smoke + commit.**
7. **(If time) Read the 4 files in the Iterable redesign section** and sketch 2-3 options. Stop and present to user.
8. **Update this handoff doc** with what landed (mark items DONE) before the session ends.

---

## Estimated quartz-time

| Task                          | Estimate  | Confidence |
|-------------------------------|-----------|------------|
| MULTI-CLAUSE-1 investigation  | 1-2h      | Medium — could be deeper |
| MULTI-CLAUSE-1 fix             | 1-2h      | Medium — depends on root cause |
| MAP-NEW-DECLARE-MISSING       | 1-2h      | High — clear path |
| UNKNOWN-VARIANT-MATCH         | 30m-1h    | High — small surface |
| Iterable sketch (no impl)      | 30m       | High |
| **Total**                      | **4-7h**  | One focused session |

If MULTI-CLAUSE-1 turns out to be a 6-hour rabbit hole, prioritize getting the OTHER two bugs fixed and committed first (so you ship something), then come back to MULTI-CLAUSE-1 with a clean tree.

---

## Open question for the user

**The MULTI-CLAUSE-1 file-attribution bug** is itself worth fixing as a sub-task: errors should print the *correct* file name, not whatever the current compilation context happens to be. Fixing this would make the rest of the MULTI-CLAUSE-1 investigation immediately easier (the error would point at `std/prelude.qz:160` instead of `/tmp/min_fib3.qz:161`). Should the next session fix the file-attribution bug FIRST, then use the better error messages to find the real MULTI-CLAUSE-1 cause? Or fix MULTI-CLAUSE-1 directly and accept the misleading errors? My instinct is "fix the file attribution first, ~30 minutes, then the rest is easier" but it's a judgment call.

Ask the user when you start the session.
