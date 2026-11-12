---
title: Locals declared in a `match` arm are not saved across a suspend nested in that arm — silent miscompile of async bodies
severity: High (valid IR, WRONG runtime result / SIGSEGV; hits any `async`/`go` body that declares a `var` or binds an enum payload inside a match arm and suspends within the same arm)
surfaced: 2026-06-05 (full qspec triage: tls_async_spec 2/6, deterministic standalone; A.44 run #3)
status: ✅ RESOLVED 2026-06-05 — added the missing NODE_MATCH case to mir_collect_generator_locals. Fixpoint 2688.
related: docs/bugs/done/POLL_BODY_WB_PRETOP_DOMINANCE.md, docs/bugs/done/POLL_BODY_WB_RESULT_SLOT_DOMINANCE.md (siblings — also "value live across a suspend"; those were invalid-IR/dominance, this one produces VALID IR but wrong runtime state)
---

# Summary

The `$poll` coroutine transform saves/restores a fixed set of locals across
every suspend point (`mir_emit_async_suspend_point_raw`, mir_lower_gen.qz:305
— stores each `_gen_local_names[i]` into the frame before `ret`, reloads after
resume). That set is collected up-front by `mir_collect_generator_locals`
(mir_lower_gen.qz:671), which walked NODE_LET / NODE_BLOCK / NODE_FOR /
NODE_FOR_AWAIT / NODE_WHILE / NODE_IF — **but had no NODE_MATCH case**.

So any local declared inside a `match` arm — a `var`, or an enum-payload
pattern binding — was invisible to the collector. It got a stack alloca but
was never written to / read from the generator frame. When the body suspends
inside that arm, the `$poll` function returns and its C stack frame is
destroyed; on resume the alloca holds garbage. Using the local after the
suspend reads that garbage → wrong value or SIGSEGV. **The IR is valid**
(the alloca is hoisted to fn_entry and dominates), so `llc`/`opt` accept it;
the bug is purely a missing save/restore → silent.

# Minimal reproducer (no TLS, no openssl)

```
enum Outer
  Has(value: Int)
  Nope(code: Int)
end
enum Res
  Ok(value: Int)
  Err(code: Int)
end
def outer_sync(x: Int): Outer = Outer::Has(x)
def a1(ch: Int): Res
  var v = recv(ch)
  return Res::Ok(v)
end
def worker(done: Int, ch1: Int): Void
  match outer_sync(1)
    Has(n) =>
      var keep = 987654321           # local declared INSIDE a match arm
      match a1(ch1)                  # suspends (channel recv parks) INSIDE the arm
        Ok(v) => atomic_store(done, 5)
        Err(e) => atomic_store(done, 2)
      end
      atomic_store(done, keep)       # use AFTER the nested suspend
    Nope(c) => atomic_store(done, 9)
  end
end
def main(): Int
  sched_init(0)
  var done = atomic_new(0)
  var ch1 = channel_new(1)
  var t = go worker(done, ch1)
  var i = 0
  while i < 1000           # let the worker park on recv before we send
    sched_yield()
    i = i + 1
  end
  send(ch1, 7)
  while atomic_load(done) == 0
    sched_yield()
  end
  await t
  puts(str_from_int(atomic_load(done)))   # pre-fix: garbage (e.g. 1780466121648395). post-fix: 987654321
  return 0
end
```

The original surfacing was `tls_async_spec`: the async TLS server does
`var tls_ctx = make_server_ctx()` inside a `ListenResult::Ok(listener)` arm,
then `match tls_accept_async(tls_ctx, fd)` (suspends), then `tls_ctx_free(tls_ctx)`
after. Backtrace: `SSL_CTX_free` EXC_BAD_ACCESS on `0xa5` ← `tls$tls_ctx_free`
← `__Future_server$poll`. `listener` (an enum-payload pattern binding used at
`close(listener.fd)` after the suspend) was lost the same way.

# Root cause (block-precise)

`mir_collect_generator_locals` returned without recursing into match arms.
In the broken `__Future_worker$poll` IR, `cl_suspend7`/`cl_resuspend9` store
only params + the await-future frame slot to `self`; there is no
`load %tls_ctx`/`store ... frame` pair. The `%tls_ctx` alloca is written once
at the install and read once after the match join — across a `ret`/re-entry
boundary it never survives.

# Fix

Added a NODE_MATCH case to `mir_collect_generator_locals` (mir_lower_gen.qz)
that, for each arm:
* collects enum-constructor payload bindings via `ast_get_bound_names` on the
  arm pattern (NODE_ENUM_ACCESS) — e.g. `listener`, `stream`;
* collects the wildcard-arm binding name (`ast_get_str1` on the arm, guarded
  by NODE_WILDCARD);
* recurses into the arm body (right child) for NODE_LET locals — e.g. `tls_ctx`.

This is purely additive (collect more names to save) and mirrors how NODE_LET
locals already work: the pre-pass binding is later overwritten by the arm's
dynamic bind (NODE_LET always re-`alloc_slot`s; pattern bindings go through
`apply_pending_bind`), while save/restore uses the current name→slot mapping
with the fixed name→frame-offset — so the extra collection is consistent and
harmless when a collected name isn't actually live across a suspend.

# Verification

* Minimal repro → `987654321` (pre-fix: garbage); `local_res`/`keep` now
  emit `load %local_res` + frame store at `cl_suspend7`/`cl_resuspend9`.
* `tls_async_spec` 6/6 (was 2/6 — `SIGSEGV` standalone, deterministic;
  A/B-proven pre-existing: identical 2/6 on the pre-pretop golden binary,
  so NOT introduced by the pretop fix).
* Fixpoint 2688 held — the compiler has no async-match-suspend body, so its
  own codegen is unchanged.
* No regressions across the async/match/effect sweep: concurrency 57,
  async_channel, spawn_await, scheduler, sync_primitives, await_nonasync,
  colorblind_async 13, async_iterator 27, generator 23,
  match_binding_shadows_method 7, semaphore 5, nested_poll_recv_park 3,
  async_rwlock_batch_wake 3, graceful_shutdown 6, scoped_async_yield_resume 1,
  effect_reader_p2b 7, effect_state_p2a 8, effect_unwind_f3b 10.
* Rule-2 smokes (style_demo, brainfuck) green.

# Scope note

Deterministic (fails standalone). Distinct from the A.44 pool-contention
cluster. Any nested control-flow form not walked by the collector is a
potential sibling — NODE_MATCH was the gap; the others (block/for/while/if/
for-await) are covered. A future hardening pass could replace the hand-rolled
recursion with a generic "walk all child statements" traversal so a new
node kind can't silently reintroduce this class.
