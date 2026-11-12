# QSpec

QSpec is the native test framework. The aggregate corpus is currently red and
contains normal, excluded, quarantined, pending, and skipped categories; use
`STATUS.md` for exact dated counts. Skeleton:

```qz
import * from qspec

def main(): Int
  describe("my feature") do ->
    it("does something") do ->
      assert_eq(1 + 1, 2)
    end

    it("prints output") do ->
      assert_output("hello\n", print_hello)
    end

    it_pending("todo: not yet implemented")
  end

  return qspec_main()
end

# CRITICAL: Use named helper functions for assert_output, NOT inline closures
def print_hello(): Void = puts("hello")
```

API: `describe(name) do -> ... end` and `it(name) do -> ... end` take no ctx parameter (pre-2026 form used ctx; current runner uses module-level state). Canonical signatures: `std/qspec.qz:65-74`.

Key assertions: `assert_eq` (Int), `assert_eq_str` (String), `assert_output` (stdout capture — use named helpers), `assert_output_contains`, `it_pending`.

## Caveat

Spec authoring, `go fn()` inside qspec lambdas: Inside `describe`/`it` lambda bodies (or any async-target context), `go fn()` desugars to `Future_X$new + $poll` polled inline on the calling thread, NOT a real worker-thread spawn. The worker-blocks-then-cancel pattern can't be expressed in qspec — main is blocked inside the inline poll. Workaround: standalone smoke tests in `spec/qz/` using `def main()` directly (real worker spawn). Examples: `spec/qz/sched_wake_interrupts_sleep_smoke.qz`, `spec/qz/scope_active_wake_smoke.qz`.
