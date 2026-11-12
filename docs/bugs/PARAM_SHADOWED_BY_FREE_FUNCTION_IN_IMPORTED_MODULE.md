# A function parameter resolves to a same-named free function's VALUE (not the param) when the module is imported

**Filed:** 2026-06-08, while building B.10 Phase-4 N0 (`niche.qz`, MEMORY_MODEL_V3 §14).
**Severity:** silent miscompile — a code address is substituted for a parameter value, no diagnostic. Footgun: any param named like a free function in the same module.
**Status:** ✅ FIXED `2bd1b1cc` (verified 2026-07-07). The imported-module repro below now prints `2` (the parameter wins over the same-named free function in bareword position, in the cross-module compile path). Fix option (1) — innermost binding wins — landed. Left in place because `docs/design/MEMORY_MODEL_V3.md` §N0 references this file; the workaround note below is now historical.

## Symptom

In a module that is **imported** by another file, a function whose parameter name
collides with a same-module top-level `def` has that bareword, inside the function
body, resolve to the **function's value** (a function pointer / code address)
instead of the parameter. The wrong value is silently used — e.g. stored into a
`Vec` and read back as a garbage ~`0x1_04xx_xxxx` pointer.

Critically, **it only manifests in the cross-module (imported) compilation path.**
The same code compiled as a standalone `def main()` program resolves correctly
(the parameter wins). So it hides until the code is factored into an imported
module — exactly where most real code lives.

## Reproduction (minimal, ~10 lines)

`smod.qz` (an imported module):
```qz
def niche_start(n: Vec): Int = n[0]                 # a free function
def take(kind: Int, niche_start: Int, used: Int): Vec = [kind, niche_start, used]
                                                    # ^ param collides with the fn above
def check(): Int
  var l = take(1, 2, 7)
  return l[1]                                        # expect 2
end
```
`main.qz`:
```qz
import smod
def main(): Int
  puts("#{smod::check()}")                           # prints a garbage pointer, NOT 2
  return 0
end
```
```
quartz -I . main.qz | llc … && clang … && ./a.out
# via module: 4345294760     (expected: 2)
```
- Toggle: rename the `niche_start` **param** to `start` → prints `2` (correct).
  Deterministic both ways — confirmed causation by toggling only the param name.
- The garbage value is in the code/data address range and varies per build → it is
  the **address of the `niche_start` function**, substituted for the param.
- Standalone (inline the bodies into `def main()`): resolves correctly. Only the
  **imported-module** path is wrong.

## What does NOT trigger it (narrowing)

- Standalone program with the same collision → correct.
- A single colliding param + a 1-element `Vec` → correct (standalone).
- The bug needs **all** of: (a) the colliding free function and the param in the
  same module, (b) the param referenced as a bareword in the body, (c) the module
  compiled via the **import** path (not as the entry `main`).

## Likely cause (hypothesis — not yet confirmed in code)

Bareword name resolution in the module-compilation path consults the module's
top-level `def` table **before** (or instead of) the current function's parameter
scope. Per `CLAUDE.md` the bareword rule is "bareword `foo` (no receiver) is the
function value, never an auto-call" — that rule is being applied **even when a
local parameter of the same name is in scope**, so the param is shadowed by the
function rather than the other way around. Correct lexical scoping requires the
**innermost binding (the parameter) to win**; the function value should only be
selected when no local of that name is in scope. The divergence between the
standalone and imported paths suggests two different resolver entry points, only
one of which checks param scope first.

Suspect areas: the resolver's bareword/identifier lowering (`resolver.qz`) and the
per-function local/param scope it threads in the imported-module vs entry-module
paths. Find where a bareword chooses "function value" vs "local load" and confirm
param scope is checked first in **both** paths.

## Fix options

1. **Make the parameter (innermost local) always win over a same-named free
   function** in bareword position, in *every* compilation path. Correct lexical
   scoping; matches every mainstream language. Verify it does not break the
   intended "bareword = function value" feature (which should only apply when no
   local shadows the name).
2. **Diagnostic:** error/warn when a parameter name shadows a same-module free
   function (QZ0xxx). Cheap, prevents the silent miscompile, but punts the scoping
   question and annoys legitimate shadowing.

Recommend **(1)** — this is a scope-precedence correctness bug, not a style nit.
A param must shadow an outer function name; anything else is a silent miscompile.

## Workaround (in place)

`self-hosted/backend/niche.qz` `enum_layout_new` params were renamed off the
colliding `niche_start`/`dataless_used` names (→ `start`/`used`). General rule
until fixed: **do not name a parameter the same as any free function in the
module.** Hard to audit by eye — hence option (1) is the real fix.
