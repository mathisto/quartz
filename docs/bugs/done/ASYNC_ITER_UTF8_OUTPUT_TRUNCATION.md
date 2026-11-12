# async_iter + UTF8 helper → IR output truncates at ~2210 lines

## Status: FIXED 2026-04-22

Fixed incidentally by the `impl AsyncIterator generic-param-loss` patch pair
(typecheck `c53d4d9f` + mir-lower `b5403a56`, 2026-04-21). Once the generator
return-type annotation flowed through `mir_lower_generator` /
`mir_lower_async_generator` correctly, the downstream codegen corruption that
was manifesting as silent truncation inside the second `@__qz_utf8_validate`
emission disappeared.

Verification 2026-04-22:
- Original memo repro (`for n in iter` over `impl AsyncIterator<Int>`) compiles
  to 7028 lines of clean IR, llc accepts it, binary runs correctly
  (`1\n2\n3\n`, exit 0).
- Test #9 from `async_iterator_spec.qz` (`async generator via variable`)
  compiles + runs identically.

Remaining `async_iterator_spec` failures (tests 9-14 kill at subprocess
timeout) are runtime hangs in the scheduler, not IR truncation. Those are
tracked separately under `GO_SCHED_BLOCKING_MUTEX_HANG.md` and
`PIEZO_KIND3_CONCURRENT_PIPE_FLAKE.md`.

---

## Symptom

Any program using `impl AsyncIterator<T>` + `for n in iter` produces
truncated LLVM IR. `llc` fails with `error: expected type` on a
mid-line truncated `getelementptr` instruction (e.g.
`%p4.3 = getelementptr i8, p` — cut off at the `p`).

Reproduces on:
- `/tmp/iter_test.qz`:
  ```
  def numbers(): impl AsyncIterator<Int>
    yield 7
    yield 8
    yield 9
  end
  def main(): Int
    var iter = numbers()
    for n in iter
      puts(n.to_s())
    end
    return 0
  end
  ```
- `spec/qspec/async_iterator_spec.qz` — 27 subprocess tests, most
  hang/timeout because their child compiles produce truncated IR that
  llc rejects.

## Reproduction

```bash
./self-hosted/bin/quartz --no-cache -I self-hosted/frontend ... \
  /tmp/iter_test.qz > /tmp/it.ll
wc -l /tmp/it.ll          # 2210 (should be ~6000+)
tail -1 /tmp/it.ll        # "  %p4.3 = getelementptr i8, p" — truncated
llc -filetype=obj /tmp/it.ll -o /tmp/it.o
# error: expected type
#   %p4.3 = getelementptr i8, p
```

## Root-cause analysis — in progress

- The truncation point is inside the **second** emission of the UTF8
  validation helper `@__qz_utf8_validate` (codegen_runtime.qz:7121).
  The same helper emits correctly at line 1755 of the output (first
  emission — from an earlier helper-emit pass).
- **Deterministic**: byte-exact same truncation every run. 2210 lines
  × exactly the same boundary (`= getelementptr i8, p`).
- **Pre-existing**: reproduces with `quartz-pre-p3e-runtime-golden`
  (Apr 21 2026, pre-this-session binary). Not caused by Piezo work.
- Minimal programs (`def main(): Int = 0`) produce full ~6500-line IR
  correctly. So the issue is triggered by async iterator use —
  specifically the IR prefix that gets emitted before the second UTF8
  helper. Something in the async-iter lowering path may be writing to
  the output stream in a way that causes later emits to be silently
  dropped (buffer flush race? partial write? `__qz_module_init`
  interference?).

## Investigation next steps

1. Check if `@__qz_utf8_validate` is being **emitted twice** deliberately
   (duplicate registration), or if it's being accidentally re-emitted by
   a second codegen pass triggered by AsyncIterator.
2. Diff the IR up to line 2200 between minimal and iter_test to find
   what async-iter emission is inserting that somehow corrupts the
   output stream.
3. Run the compiler under lldb and break at the emission site to see
   if stdout/write system call returns a partial-write without retry.

## Impact

- async_iterator_spec (27 tests) cannot be run end-to-end under current
  compiler — tests using AsyncIterator hang subprocesses at compile time
  because llc rejects their truncated IR.
- Any user program using `for` over `impl AsyncIterator<T>` is broken.

## Not caused by

- Piezo P3.E-runtime changes (verified: pre-golden reproduces identically)
- P3.D (same)
- Recent Piezo work in general — the duplicate utf8 helper emission
  pattern predates the Piezo epic.

## Workaround

None currently. Avoid `for n in iter` on `impl AsyncIterator<T>` — use
explicit `iter.next()` loop + Option-match instead.

## Priority

Medium-high. AsyncIterator + for-in is a documented language feature;
the silent truncation is a severe correctness issue. But it's
localized to one shape of program, so not blocking Phase 3 work.
