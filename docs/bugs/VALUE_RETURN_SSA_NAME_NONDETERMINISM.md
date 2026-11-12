# Value-return-by-pointer SSA names embed a heap address → non-deterministic IR

**Filed:** 2026-07-08 (surfaced by the diag-quality-finish inertness smoke check)
**Severity:** MED — reproducibility wart; latent guard-fixpoint-flake risk. Not a miscompile (semantics are correct; only the SSA *names* differ).
**Status:** OPEN, pre-existing (NOT caused by any 2026-07-08 diagnostics work).

## Symptom

Compiling a program that returns a value-type struct via the "return-by-pointer"
extraction path produces IR whose temp names differ **run-to-run for the same binary**:

```
# run A:  %ret.bp.105553156600832 = inttoptr i64 %v1 to ptr
# run B:  %ret.bp.105553127504640 = inttoptr i64 %v1 to ptr
```

Confirmed with `examples/style_demo.qz`: two `--no-cache` compiles by the *same*
binary differ in exactly these `%ret.bp.<N>` / `%ret.bg<N>_k` / `%ret.bl<N>_k` /
`%ret.ba<N>_k` temp names (10 lines for style_demo). After normalizing the 12+‑digit
suffix (`sed -E 's/[0-9]{12,}/ADDR/g'`), the IR is byte-identical. `examples/brainfuck.qz`
is unaffected (it never hits the value-return-by-pointer path).

## Root cause

`self-hosted/backend/codegen_instr.qz:3576` — the temp-name uniquifier is
`var bn = str_from_int(block)`, and `block` here carries a **heap pointer value**
(the observed suffixes `105553156600832` = `0x6000_0B4A_0000`-range are macOS heap
addresses), not a stable sequential id. That address is rendered directly into the
LLVM SSA name at lines 3583/3590/3597/3643 (`%ret.bp.` / `%ret.bg` / GEP operands).
ASLR moves the address each run → non-reproducible names.

## Why guard fixpoint still passes (and the latent risk)

Guard's gen1==gen2 fixpoint is empirically stable, so the compiler's OWN self-compile
either doesn't exercise this narrow-struct value-return path or `block` is stable for
those cases. **But this is a latent intermittent-fixpoint-flake hazard:** the first
compiler function that returns a narrow value-type struct through this path could make
`quake guard` fail nondeterministically (gen1 address ≠ gen2 address). Worth fixing
before it bites.

## Fix direction (attended — hot codegen)

Replace the address-derived `block` uniquifier with a deterministic per-function
monotonic counter (or a hash of stable MIR ids), so `%ret.bp.<N>` names are
reproducible. Localized to `codegen_instr.qz` around the value-return extraction
(3576–3650). Needs a guard cycle + a determinism check (compile a value-return program
twice, assert byte-identical). Not gate-1-inert (changes emitted IR for real programs),
so **attended**.

## Repro

```bash
./self-hosted/bin/quartz --no-cache examples/style_demo.qz > /tmp/a.ll
./self-hosted/bin/quartz --no-cache examples/style_demo.qz > /tmp/b.ll
diff /tmp/a.ll /tmp/b.ll   # 10 lines differ, only in %ret.bp.<addr> suffixes
```
