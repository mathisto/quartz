# `can E` on tiny standalone programs SIGSEGVs with "index out of bounds: index 0, size 0"

> **Filed**: 2026-04-30 during Phase B of the Sched-effect work
> (`docs/design/SCHED_EFFECT_THREAD_SAFETY.md`).
> **Resolution**: 2026-05-02. Root cause was unrelated to `can E` —
> top-level `def f` was being directly dispatched at `f(self.frame)`
> inside `std/gen.qz` `Stream.next`, where `f` is a local var bound
> to `self.step`. `mir_lower_call` looked up the function name
> globally without first checking local-variable scope. Same hazard
> applied to function parameters: `def caller(f: Fn(): Int) = f()`
> collided with any top-level `def f`. Fix: shadow check at the top
> of `mir_lower_call` — if the call name resolves to a local var,
> emit indirect call instead. The `Sched.__marker` workaround in
> `std/sched.qz` is removed; `effect Sched end` (no ops) is the
> intended shape.
>
> **Update 2026-05-02 (A.10 investigation):** Surface is broader than
> the original repros showed AND is **NOT actually `can E`-specific**.
> Trigger pattern is `auto-stdlib-include + a top-level def named
> specifically "f" beyond main`. With `--stdlib-path /nonexistent` (no
> auto-prelude), every repro compiles clean. With auto-prelude, only
> `def f`-named user functions crash; `def g` / `def h` / `def x` /
> `def foo` / `def zzzzz_unique_name` etc. all compile clean. The
> common factor: `std/gen.qz:85` declares `var f = self.step` inside
> `Stream.next`, and the user's top-level `def f(): Int = 1` is the
> only name that collides. This is **the intrinsic-name-shadow class**
> from `feedback_intrinsic_name_shadow.md` extended to stdlib local
> variables — not just intrinsics. The `can E` repros in the original
> doc happened to use `def f` but the `can E` was incidental. Bug
> mechanism: name collision in some downstream registry/pass that
> reads index 0 of an empty Vec when the symbol is double-registered
> or shadowed across the prelude→user boundary. **Likely fix target**:
> resolver or typecheck pass that builds the global function table —
> either reject the collision with QZ04xx or scope-isolate the local
> `f` (probably the latter; `var` bindings inside a function body
> should never leak into the top-level symbol table).
>
> The `can E` programs in the original repro list crash via the same
> mechanism — they all use `def f`. Replacing `f` with `g` makes the
> `can E` programs compile clean. So **`Sched`'s `__marker` op
> workaround is unnecessary if `std/sched.qz` were renamed away from
> shadow risk**, but the cleaner fix is at the compiler — same name
> trigger affects every effect, not just Sched.

## Reproducer

Any of these tiny programs SIGSEGV with `index out of bounds: index 0, size 0`
during `--no-cache` compile:

```be
def f(): Void can Sched
  puts("a")
end

def main(): Int
  return 0
end
```

```be
def f(): Void can Async   # any effect, declared or not
  puts("a")
end

def main(): Int
  return 0
end
```

```be
def f(): Int can L = 1    # endless-def shape from effect_func_row_spec
def main(): Int = f()
```

```be
import std/throws

def f(): Int can Throws
  return 0
end

def main(): Int
  f()
  return 0
end
```

## What works

- Programs without any `can E` annotation compile fine
  (`/tmp/min.qz`, `examples/style_demo.qz`).
- The compiler source itself is full of `can Diag` / `can Async` /
  `can Throws` annotations and self-builds + fixpoints byte-identical.
- `spec/qspec/effect_func_row_spec.qz` uses similar `can L` shapes
  *inside* `assert_compile_succeeds` heredocs (subprocess compiles
  via `subprocess_compile_with_flags`) and passes.

## Symptom

```
$ ./self-hosted/bin/quartz --no-cache -I … <repro>.qz
[mem] resolve_pass1: 3 MB, 2 modules
[mem] resolve_pass2: 3 MB
index out of bounds: index 0, size 0
exit=139  (SIGSEGV)
```

No DiagnosticReports archive landed for this on the test machine —
the panic-trap message + SIGSEGV imply a Vec[0] access on a 0-size
Vec somewhere downstream of typecheck.

## Hypotheses

1. **Default-handler install path.** The crash triggers between
   typecheck (resolve_pass2 prints) and codegen prelude — likely
   in the runtime-blessed-default install where `cg_emit_effect_install_defaults`
   iterates ops or `effect_decl_op_starts[i]` for each known effect
   in the prelude set. A function carrying `can E` in a tiny program
   that doesn't `import std/<E>` may leave the registry in a state
   where the install loop reads past the end of one of the parallel
   vecs.

2. **MIR lowering of an unused `can`-annotated function.** The
   compiler's `mir_lower_*` paths for `can E` functions assume the
   effect's op count > 0 somewhere. The compiler source's functions
   all use effects whose decls have ops; these tiny test programs
   might exercise the kind=0 / "no ops" pathway that real code
   doesn't.

3. **Cache state from a prior compile.** Already ruled out: the
   crash reproduces with `--no-cache` + `rm -rf .quartz-cache`.

## Why Phase B works around rather than fixes

Phase B's verification path is the spec/qspec suite + the
self-build, both of which work fine. The tiny-program crash only
matters for users who write a `can Sched` annotation in a one-file
program with no other effect imports. Until someone hits it
organically, the workaround (keeping a `__marker` op on the
`Sched` effect declaration in `std/sched.qz`) is sufficient. When
this is fixed, drop the `__marker` op — the design intent is for
`Sched` to have **no** ops, since the effect carries pure marker
semantics.

## Next steps when picking this up

1. lldb the compiler binary on `/tmp/sched_pos.qz`-shaped repro;
   `b __vec_index_out_of_bounds` (or wherever the panic-trap lives)
   to catch the SIGSEGV in the act.
2. Compare resolve_pass2 / pre-codegen state between a working
   tiny program (no `can`) and a crashing one (with `can`).
3. Check `_mir_lower_default_handler_install` and the prelude
   `cg_emit_effect_install_defaults` for op-count-required loops.

## Cross-refs

- `feedback_quartz_module_quirks.md` lists similar latent crashes
  (Vec<T>-element-type-loss, NODE_FOR.extra-ptype-id, etc.)
- The Phase B Sched-effect work landed despite this; PSQ-6 closure
  still proceeds via the planned Phase C → D rewrite of `std/progress`.
