# `.qzmod` — Quartz Module Artifact Format

> **Status:** Design document. Supersedes `INCREMENTAL_COMPILATION_PLAN.md` (Feb 2026).
> **Date:** 2026-05-12
> **Motivating problem:** Every `quartz` invocation re-parses, re-typechecks, re-MIR-lowers, and re-codegens ALL imported stdlib modules from scratch. ~90% of the 5s/compile wall is stdlib redo. The qspec suite is ~24 min at 464 specs as a direct consequence.
> **Prior path:** `5.0f.d.*` attempted to share live `TcRegistry` state across compiles within a long-running worker. Abandoned after `5.0f.d.2.b2` surfaced multiple classes of per-compile-scoped state masquerading as per-process state (stale AST handles, stale intern IDs, stale default-value handles). The current monolithic compiler architecture cannot be retrofitted with cross-compile state sharing in place; the right answer is to give the compiler module-level compilation artifacts, the same way Rust, Swift, Scala, OCaml, GHC, and Lean all do.

---

## 1. Goals and Non-Goals

**Goals:**

1. Stdlib compiles once per `quake guard` cycle; importers load signatures + selected bodies in milliseconds.
2. The qspec suite drops from ~24 min to a target of **<3 min** for a clean run; **<30s** for the common case (no compiler change, one spec edited).
3. The artifact format is **stable enough for cross-machine sharing in v2** without re-architecture, even if v1 is local-only.
4. Self-hosted bootstrap stays clean: a new `quartz` binary auto-invalidates the cache, no version field to forget to bump.
5. The format serves the compiler today and a future LSP / doc generator / reflective metaprogramming layer without redesign.

**Non-goals (v1):**

1. Cross-compiler-version compatibility. Quartz is pre-launch, single-consumer; we don't need a Swift-style textual interface yet.
2. Persisted Salsa-style query DAGs. Per-module artifacts capture most of the win for stdlib redo; query persistence is a P2 follow-up if measurement proves it pays.
3. Content-addressed cache sharing across machines. Local cache only in v1; the design preserves the option to layer CAS on later.
4. Cross-module inlining beyond signatures + monomorphization-required generic bodies. `@inline` annotation lands in v2.

---

## 2. The Architectural Shape

The four production languages closest to Quartz's situation converge on **the same skeleton**, with small variations. Quartz adopts it:

```
┌─────────────────────────────────────────────────────────────┐
│  PRODUCER (compile foo.qz)                                  │
│  parse → resolve → typecheck → MIR → codegen → LLVM IR      │
│                          │                                  │
│                          ▼                                  │
│  emit .qzmod  ◀── (signatures + effect rows + selected MIR) │
│  emit foo.o   ◀── (object code, unchanged from today)       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  CONSUMER (compile bar.qz which imports foo)                │
│  parse bar → resolve(foo: load .qzmod) → typecheck → ...    │
│                                  │                          │
│  .qzmod gives signatures, types, │                          │
│  effect rows for foo without     │                          │
│  re-parsing or re-typechecking.  │                          │
└─────────────────────────────────────────────────────────────┘
```

**This is the Rust `.rmeta` + `.rlib` split, the OCaml `.cmi` + `.cmx` split, the GHC `.hi` + `.o` split, the Swift `.swiftmodule` + object split.** Every mainstream typed compiled language did this independently. The pattern is not a research result; it's the default architecture.

What's different for Quartz:

- **Effects ride inside the type pickler.** A `can Throws | State` row pickles as `RowExtend(Throws, [], RowExtend(State, [], RowVar(α)))` — same machinery as any other type. (Koka pattern.)
- **Self-host bootstrap is solved by the existing `.fixpoint` discipline.** The compiler binary's content hash is already pinned per commit. We reuse it as the cache version key — no new mechanism. (ccache `compilercheck=content` pattern.)
- **TASTy-style sectioned, versioned binary** so the format can evolve additively without breaking readers. Scala 3 production-proves this; we copy it.

---

## 3. Design Principles (the north stars)

Each ties back to a specific finding from the research.

1. **Compiler binary content hash IS the cache version.** Never embed a `format_version: N` integer. The `.fixpoint` stamp's compiler binary hash transitively covers every codegen-affecting change. When `quake guard` produces a new binary, the hash changes and every `.qzmod` is auto-invalidated. *(Source: agent 4 — ccache `compilercheck=content`; bootstrap recipe.)*

2. **Per-declaration fingerprinting from day one.** Each exported decl carries a SHA-256 over its normalized signature + transitive signature dependencies. Downstream recompile triggers off the *intersection* of "what I import" and "what changed" — not the whole module. Retrofitting this is much harder than designing it in. *(Source: agent 2 — GHC `.hi` per-decl fingerprints; agent 1 — `DefPath`.)*

3. **Output-fingerprint-based invalidation, with backdating.** Hash the *post-typecheck* output (signatures, types, effect rows), not the source text. Whitespace edits, comment changes, and reformatting don't cascade. If a recompile produces byte-identical output, downstream consumers stay green. *(Source: agent 4 — Salsa red-green + backdating; Nix ca-derivations.)*

4. **Sectioned, versioned, additively extensible.** Magic + major/minor versions + named sections with a TOC. Readers skip unknown sections. New sections land in minor releases without breaking older readers. *(Source: agent 3 — TASTy.)*

5. **Default: ship signatures only. Cost-bounded MIR-for-inlining is opt-in.** Most stdlib functions don't need cross-module inlining; shipping all MIR explodes artifact size and inverts the codegen cost curve (cf. abandoned `-Zmir-only-rlibs`). Annotate inlinable bodies with `@inline_export`; let the cost-checker decide for unannotated small leaf functions. *(Source: agent 1 — rustc `cross_crate_inline`; agent 2 — Swift `@inlinable`.)*

6. **The cache is advisory. Always cross-check at load. Fall back silently to from-scratch.** rustc's incremental-compilation ICE history is the warning: cache corruption *will* happen at scale. Mismatch = log loudly + recompile, not abort. *(Source: agent 4 — rustc incremental's deployed pain points.)*

7. **Pickle effects via the type pickler, not via separate machinery.** Effect rows are types; they ride inside function signatures, which ride inside the existing pickle path. No "effects section" — just the types section, which already accounts for effects. *(Source: agent 3 — Koka.)*

8. **Lazy decoding.** Sections are TOC'd by offset + length. Individual declarations within a section are also TOC'd: stay as `(offset, length)` blobs until first lookup, then materialize. A 2000-fn stdlib that an importer reads 30 functions from should decode 30 functions, not 1970. *(Source: agent 3 — Idris 2 `ContextEntry`.)*

---

## 4. File Format

### 4.1 Naming and layout

| Extension | Role | Source of truth? |
|---|---|---|
| `.qzmod` | Per-module binary cache (compiler-version-tied). Holds typecheck output + optional MIR. | No (regenerable from source) |
| `.o` | Per-module object code. Already emitted by `quake build:separate`. | No |
| `.qz` | Source. | **Yes** |

`.qzmod` lives at:

```
.quartz-cache/<compiler_hash>/<module_path>.qzmod
```

Where `<compiler_hash>` is the first 16 hex chars of the compiler binary's SHA-256, and `<module_path>` is the resolver's canonical module name with `/` → `__` replacement (so `std/sync/channel` → `std__sync__channel.qzmod`). Sharding by compiler hash keeps multiple in-flight compiler versions (a working copy + a known-good golden) from clobbering each other — important during `quake guard` cycles.

### 4.2 On-disk layout — multi-file directory (v1)

**Pragmatic refinement from the original "single binary file with section TOC" design**, made 2026-05-12 once we mapped existing infrastructure. The build_cache infrastructure already includes `vec_save(vec, path)` / `vec_load(path)` / `strvec_save` / `strvec_load` intrinsics that round-trip `Vec<Int>` and `Vec<String>` losslessly to/from `.bin` files. `cache_save_ast` (`self-hosted/shared/build_cache.qz:355`) already uses this pattern for per-module AST caching. Reusing it for `.qzmod` saves ~1000 LOC of from-scratch varint/byte-stream encoding and uses already-tested infrastructure.

**Logical design unchanged** — sectioned, versioned, advisory + fallback, lazy-decode-friendly. **Physical layout is a directory of `.bin` files plus a `header.txt`**, one directory per module:

```
.quartz-cache/<compiler_hash[:16]>/<module>/
  header.txt              Text header — version, hashes, dep table.
  strings.bin             Vec<String> — module-local interned string pool. (strvec)
  types_tag.bin           Vec<Int>  — type tag per entry (struct/enum/fn/row/var/...).
  types_arg1.bin          Vec<Int>  — first arg per entry (struct→struct_idx, fn→param_count, row→label_id, ...).
  types_arg2.bin          Vec<Int>  — second arg per entry.
  types_args_blob.bin     Vec<Int>  — flat blob for variable-length type arg lists (referenced by types_arg1/arg2).
  structs_name.bin        Vec<Int>  — string index per exported struct.
  structs_fields_blob.bin Vec<Int>  — flat blob: [n_fields, name0, type0, ann0, default0, n_fields1, ...].
  enums_name.bin          Vec<Int>  — string index per exported enum.
  enums_variants_blob.bin Vec<Int>  — flat blob: [n_variants, name0, payload_count0, payload0_0, ...].
  funcs_name.bin          Vec<Int>  — string index per exported function.
  funcs_sig_blob.bin      Vec<Int>  — flat blob: [param_count, return_type, fx_row_idx, param0_type, ...].
  traits_name.bin         Vec<Int>  — string index per trait.
  traits_methods_blob.bin Vec<Int>  — flat blob.
  impls_blob.bin          Vec<Int>  — flat blob: [trait_name_id, for_type_id, ...].
  effects_name.bin        Vec<Int>  — string index per effect decl.
  effects_ops_blob.bin    Vec<Int>  — flat blob: ops + their param/return types.
  consts_name.bin         Vec<Int>  — string index per const.
  consts_type.bin         Vec<Int>  — type per const.
  globals_name.bin        Vec<Int>  — string index per global.
  globals_type.bin        Vec<Int>  — type per global.
  newtypes_name.bin       Vec<Int>  — string index per newtype.
  newtypes_wrapped.bin    Vec<Int>  — wrapped-type id per newtype.
  type_aliases_name.bin   Vec<Int>  — string index per alias.
  type_aliases_target.bin Vec<Int>  — target type id per alias.
  binary_dsl_blob.bin     Vec<Int>  — binary{}/packed struct synthesized signatures.
  decl_fingerprints.bin   Vec<Int>  — (Phase 2) per-declaration content hash.
  mir_bodies.bin          Vec<Int>  — (v2)     inline-exported MIR.
  source_positions.bin    Vec<Int>  — (tooling) line/col per decl.
  doc_strings.bin         Vec<String> — (tooling) doc comments.
```

A "section" is now a related set of `.bin` files (e.g. STRUCTS = `structs_name.bin` + `structs_fields_blob.bin`). Missing files = section absent (skippable behavior preserved). Each section's hash is recomputable from its constituent files.

`header.txt` is the single source of truth for versioning + dep coherence:

```
QZMOD-V1
1                              # MAJOR
0                              # MINOR
0                              # EXPERIMENTAL
<compiler_hash:16hex>          # FNV-1a of self-hosted/bin/quartz binary content
<source_hash:16hex>            # FNV-1a of canonical source bytes (this module)
<output_hash:16hex>            # FNV-1a over all section .bin file contents (this module)
<canonical_flags:string>       # target triple, opt level, etc.
<n_deps:int>
<dep_module_name>|<dep_interface_hash:16hex>  # one line per transitive dep
<dep_module_name>|<dep_interface_hash:16hex>
...
```

The `output_hash` is the **declaration of "what consumers depend on."** It's the FNV-1a over the concatenation of every section file's contents in canonical order. Two `.qzmod` directories produced from semantically-equivalent source (different whitespace, reordered private fns) hash identically — backdating property holds.

**v2 collapse to single-file binary** (the original design) becomes a fixed engineering exercise once Phase 6 measurement says it matters. Logical design carries over unchanged; just the physical layout shifts.

### 4.2.1 Hash algorithm note

The design doc originally specified SHA-256. Existing `std/content_hash.qz` is FNV-1a 64-bit (16-char hex output). **v1 uses FNV-1a** to reuse existing infrastructure. Upgrade to SHA-256 deferred to the CAS phase (P2), when cross-machine cache sharing demands cryptographic-grade hashing. FNV-1a collision probability is ~50% at 2^32 entries — fine for local single-user cache, insufficient for shared CAS.

### 4.3 Section tags (v1)

| Tag | Name | Mandatory? | Content |
|---|---|---|---|
| 0x0001 | `STRINGS` | ✅ | Interned string pool. All other sections reference into this by index. |
| 0x0002 | `TYPES` | ✅ | Type IDs + pointed-to type definitions. Includes effect rows. |
| 0x0003 | `STRUCTS` | ✅ | Exported struct definitions: name, type params, fields, linearity. |
| 0x0004 | `ENUMS` | ✅ | Exported enum definitions: name, type params, variants + payloads. |
| 0x0005 | `TRAITS` | ✅ | Exported trait definitions: name, type params, method signatures, super-traits. |
| 0x0006 | `IMPLS` | ✅ | Exported `impl Trait for Type` entries. |
| 0x0007 | `FUNCS` | ✅ | Exported function signatures: name, params, return, effect row, generics. |
| 0x0008 | `EFFECT_DECLS` | ✅ | Exported `effect Foo` declarations (the names + op signatures). |
| 0x0009 | `CONSTS` | ✅ | Exported `const` declarations. |
| 0x000A | `GLOBALS` | ✅ | Exported `var` declarations. |
| 0x000B | `NEWTYPES` | ✅ | `newtype N = Wrapped`. |
| 0x000C | `TYPE_ALIASES` | ✅ | `type Alias = ...`. |
| 0x000D | `BINARY_DSL` | ✅ | `binary {}` / `packed struct` definitions + synthesized methods. |
| 0x0010 | `DECL_FINGERPRINTS` | ✅ | Parallel array: SHA-256 per exported declaration. Indexed by `(section_tag, decl_index)`. |
| 0x0020 | `MIR_BODIES` | ⚠️ skippable | Optional. MIR for `@inline_export`-annotated or cost-bounded-small functions. |
| 0x0030 | `SOURCE_POSITIONS` | ⚠️ skippable | Line/column for each decl. Tooling-only. |
| 0x0031 | `DOC_STRINGS` | ⚠️ skippable | `##` doc comments per decl. Tooling-only. |
| 0x0040 | `LANG_SERVER` | ⚠️ skippable | Hover/completion data. Reserved for future LSP. |

**Skippable** means: the compiler can complete a compilation without reading these. They're for tooling (IDE, doc gen) and optional cross-module optimizations.

### 4.4 Encoding primitives

In the multi-file layout, encoding primitives are inherited from `vec_save`/`vec_load`/`strvec_save`/`strvec_load`. These intrinsics already round-trip Vec<Int> and Vec<String> losslessly in a stable binary form. The design uses them as the only byte-level encoders.

- **Strings** are *always* referenced by index into `strings.bin`; never inlined into another `.bin`. Deduplicates type names that appear in many signatures.
- **Type IDs** are indexes into the per-module `types_*.bin` triple, which is self-contained — a TYPES entry can recursively reference earlier TYPES entries.
- **Variable-length structures** (struct field lists, function parameter lists) are encoded as flat blobs with explicit length prefixes inline. E.g. `structs_fields_blob.bin` = `[n_fields0, name0_0, type0_0, ann0_0, default0_0, name0_1, ..., n_fields1, ...]`. An auxiliary `structs_fields_off.bin: Vec<Int>` records the start offset per struct so individual struct field lists can be located in O(1) without scanning.
- **No timestamps, no PIDs, no absolute paths.** Strict determinism — required for content hashing. The string interner index ordering is content-determined, not insertion-order-determined.

---

## 5. Cache Key Derivation (the bootstrap-safe recipe)

For a module `foo.qz` whose imports are `{bar, baz, ...}`:

```
cache_key(foo) = SHA-256(
    canonical_source_hash(foo.qz)
    || compiler_hash                           # SHA-256 of self-hosted/bin/quartz
    || sort_concat( output_hash(b) for b in transitive_imports(foo) )
    || canonical_flags                         # target-triple, -O level, etc.
)
```

The path entry for finding a cached `.qzmod` is:

```
.quartz-cache/<compiler_hash[:16]>/<module_path>.qzmod
```

On load, the consumer verifies:

1. The file's magic + major version match.
2. The file's `compiler_hash` in the header matches the running compiler's binary hash.
3. The file's transitive dep table's `interface_hash` values match the currently-loaded versions of those deps.

Any mismatch ⇒ log loudly, treat as cache miss, recompile from source.

### 5.1 Why the compiler binary hash is the cache version

Three failure modes the alternative ("`cache_format_version: N` field") suffers from, that this approach avoids:

1. Someone changes the encoding subtly (e.g. a struct field gets a new type), forgets to bump `N`, downstream caches silently miscompile. Has happened in every language with this pattern.
2. Quartz's MIR or codegen layer changes — same risk.
3. Bootstrap Island repeats: silent drift between source intent and binary output.

The compiler binary's content hash transitively covers (a) parser source, (b) typechecker source, (c) MIR lowering source, (d) codegen source, (e) intrinsic registry, (f) any helper that touched any of those. **The entire compiler is the format spec.** This is the same reason `quake guard` exists.

### 5.2 What happens during `quake guard`

```
1. Backup current binary to backups/quartz-golden
2. Build new compiler (gen1)
3. Self-compile (gen2)
4. Verify gen1.ll == gen2.ll (fixpoint)
5. Write .fixpoint stamp
6. Stage binary + stamp
```

In v1 of `.qzmod`:

7. **(NEW)** Clear `.quartz-cache/<old_compiler_hash[:16]>/` after a guard cycle that produces a different binary hash than the previous one.

`.quartz-cache/<new_compiler_hash[:16]>/` is empty, so the next compile populates it fresh. Old caches stay disk-resident under their old hash directory until manually cleaned (or for one weekend). This protects against the "I `git checkout`'d an older commit" recovery case — the old binary's cache is still there.

---

## 6. Per-Declaration Fingerprinting

The `DECL_FINGERPRINTS` section is the engine of fine-grained invalidation.

Each exported declaration contributes one entry:

```
fingerprint(decl) = SHA-256(
    section_tag (u16)
    || decl_kind (u8: struct=1, enum=2, fn=3, trait=4, impl=5, …)
    || canonical_name (UTF-8)
    || canonical_signature_bytes        # see § 6.1
)
```

A consumer of `foo` records, for each `foo::name` it imports, the fingerprint of `name` at compile time. On the next compile, the consumer's `cache_key` includes those specific fingerprints, not `foo`'s whole-module hash.

### 6.1 Canonical signature bytes

For each decl kind, define a canonical byte representation that ignores:

- Comments.
- Whitespace.
- Order of unordered fields (struct fields, enum variants — they're positional, so order matters; but `effect` op order is unordered, etc.).
- Source positions.

The canonical bytes are what `fingerprint` hashes. The encoder for `STRUCTS` etc. emits canonical-form first (used for fingerprinting), then re-emits the source-positions section if needed.

### 6.2 Decl-level recompile examples

| Edit in `foo.qz` | What changes in `foo.qzmod` | Consumers re-typecheck? |
|---|---|---|
| Add a comment | nothing (canonical-bytes unchanged) | No — backdating |
| Reformat whitespace | nothing | No |
| Rename a private function | the private function's fingerprint, but it's not in `DECL_FINGERPRINTS` (not exported) | No |
| Add a new exported fn | new entry in `DECL_FINGERPRINTS` | Only consumers who reference the new name; everyone else: no |
| Change exported `pub fn foo` body but not signature | `MIR_BODIES` section changes if `@inline_export` is set, else no change | Only inlining consumers; else no |
| Change exported `pub fn foo` signature | `foo`'s entry in `DECL_FINGERPRINTS` changes | Only consumers who reference `foo` |
| Add a new exported struct | new entry; old fingerprints unchanged | Only consumers who reference the new struct |
| Reorder unrelated exported functions | nothing if order is stable in canonical form | No |

This is the difference between "one-line edit, rebuild project" and "one-line edit, rebuild one consumer." It's the GHC / Swift-resilient win.

---

## 7. Effects in the Artifact

The Koka lesson: **effects don't need a separate serialization story.** They live inside function and trait signatures.

A row `can Throws | State` in source becomes, in the type IR:

```
RowExtend("Throws", [], RowExtend("State", [], RowEmpty))
```

(Or with a row variable: `RowExtend("Throws", [], RowVar(α))`.)

The `TYPES` section already needs to encode arbitrary types; we just add row-type variants. The function signature in `FUNCS` references a row's type ID. The pickle is a single recursive walk. No `EFFECTS` section — the `EFFECT_DECLS` section is just for `effect Foo` declarations themselves (analogous to `STRUCTS`); their use-sites are in the type encoding.

### 7.1 Effect handler bodies and inlining

A handler like:

```qz
with Throws { throw: my_handler } do -> body end
```

requires `my_handler`'s signature (for typechecking). The body is irrelevant cross-module unless the handler itself is exported and consumers need to inline. Same `@inline_export` opt-in.

### 7.2 Polymorphic effect functions

A function `def f<e>(...): ... can e` has a row variable. The row variable is fresh on each instantiation. The pickled signature carries the row variable's binding; consumers freshen at use site. This is mechanically the same as how regular type variables work, which the type pickler already handles.

---

## 8. MIR Bodies (Cross-Module Inlining, v2)

**v1 ships no MIR_BODIES section.** Default behavior: every cross-module call is an indirect dispatch. This is what Quartz does today anyway — the optimization isn't lost, it just isn't gained yet.

**v2 ships MIR_BODIES with two gates:**

1. **`@inline_export` annotation.** Author opts in explicitly. Pickles MIR. Consumers can inline.
2. **Cost-bounded auto-inline** (Rust `cross_crate_inline` heuristic): if a function has zero internal calls, no `throw`/`panic`, statement count under threshold N, automatically include MIR. Threshold tuned empirically.

Without either, the function ships with signature only. Consumers see it as a pure indirect call.

Generics that require monomorphization in the consumer (`def foo<T>(x: T)`) DO ship their MIR — the consumer doesn't have a choice, monomorphization can't happen without the body. Same as Rust.

### 8.1 What the MIR_BODIES section holds

For each "shippable" function:

- decl index (into `FUNCS`)
- compressed MIR bytecode (the same format `quake snapshots` already produces, which is already deterministic)
- decoded type-id table (consumer-local type IDs may differ; we ship producer-local IDs + a remapping)

Type-ID remapping is the tricky part. Producer's `TYPES` section is self-contained; consumer's loaded `.qzmod` types get remapped into the consumer's type table on import. The remapping happens once per import; cached.

---

## 9. Build System Integration

### 9.1 `quartz` (the compiler) changes

The current compile() does:

```
parse → resolve → typecheck → MIR → codegen → emit IR
```

The new compile() does:

```
parse main
resolve imports:
    for each import:
        if .qzmod exists and cache_key matches:
            load_qzmod(import)
            populate consumer's TcRegistry with imported sigs (decl-by-decl, lazy)
        else:
            recurse into compile(import.qz)
            after compile, emit_qzmod(import) to .quartz-cache/
typecheck main (signatures from imports already in registry)
MIR main
codegen main
emit main IR
emit main.qzmod
```

The win: stdlib imports' parse + typecheck + MIR are skipped entirely. We pay the cost of `.qzmod` deserialization (milliseconds) instead of full re-compilation (~5s for stdlib subset).

### 9.2 `quake` changes

- `quake build` — same surface; uses `.qzmod` cache implicitly.
- `quake guard` — extends to validate `.qzmod` consistency in stage 5.5 (after fixpoint check, before binary stage). If any `.qzmod` has stale `compiler_hash`, blow away its directory.
- `quake clean` — sweeps `.quartz-cache/`.
- `quake qspec` — benefits automatically: per-spec compiles read the same `.qzmod` for stdlib.

### 9.3 Backward compatibility

There isn't any. Quartz pre-launch, single consumer (the user). Per `CLAUDE.md`'s Project Reality Check: we delete `INCREMENTAL_COMPILATION_PLAN.md`'s tier-2 fragment cache machinery once `.qzmod` is in place. No deprecation period, no shim layer.

The existing `build_cache.qz` Tier 0/1/2 caching (whole-program LLVM IR cache, dep-graph-driven fragment cache) is **complementary** to `.qzmod`:

| Layer | Granularity | What's cached |
|---|---|---|
| `.qzmod` (NEW) | Per-module typecheck + MIR | Signatures, effects, optional MIR bodies |
| Build cache Tier 0 | Whole-program | Final LLVM IR, fast cache-hit short-circuit |
| Build cache Tier 1/2 | Per-module LLVM IR fragment | Object code for separate-build mode |

All three layers can coexist; they cache different stages of the pipeline.

---

## 10. Implementation Phases

Each phase is a single shippable increment with its own validation gate.

### Phase 1 — Format + emit + load (signature-only)

Land the bytes-on-disk story end to end. No optimization wins yet; this just makes everything work without breaking.

- Define encoding for STRINGS, TYPES, STRUCTS, ENUMS, FUNCS sections.
- Implement encoder in `self-hosted/backend/qzmod_emit.qz`.
- Implement decoder in `self-hosted/backend/qzmod_load.qz`.
- Wire `emit_qzmod()` into `compile()` after typecheck completes for each module.
- Wire `load_qzmod()` into `resolver` as an alternative to source parsing for an import.
- Cache key check: source hash + compiler hash + transitive interface hashes.
- **Unconditional.** No flag. The cache is advisory (Principle #6): hash mismatch or decode error falls back to from-scratch automatically. `rm -rf .quartz-cache/` is the rollback knob if needed; `quake guard`'s fixpoint check (gen1.ll == gen2.ll byte-identical) catches any cache that poisons output.
- Delete `qzi.qz` stub (per Decision #6 in §11).

**Acceptance:**
- `quake guard` passes; gen2.ll byte-identical to gen1.ll (fixpoint holds, proving `.qzmod` round-trip preserves semantics).
- Manual test: compile a small spec twice; second compile shows `.qzmod` cache hits in logs.
- `rm -rf .quartz-cache/` followed by `quake guard` produces the same binary as the cached run.

**Sized:** ~1-2 weeks traditional / ~3-5 days Quartz-time.

### Phase 2 — Per-declaration fingerprinting + cache key wiring

- Add DECL_FINGERPRINTS section.
- Consumers record per-decl dependency, not per-module.
- Cache key includes only fingerprints of imports actually referenced.

**Acceptance:**
- Edit one private function in `std/string.qz`. Recompile `spec/qspec/string_spec.qz`. Verify cache hit (no recompile of `std/string` or any other stdlib module).
- Edit one exported function's signature. Verify only direct consumers of that fn re-typecheck.

**Sized:** ~3-5 days.

### Phase 3 — Backdating + advanced invalidation

- Hash the canonical output (post-typecheck signatures + types), not source bytes.
- Comment-only / whitespace-only edits don't ripple.
- Wire into the decl-fingerprint compute.

**Acceptance:**
- Add a `## comment` to `std/string.qz`. No `.qzmod` files re-emit.
- Reformat whitespace in `std/io.qz`. Same.

**Sized:** ~2-3 days.

### Phase 4 — Effect declarations + row types

- Encode `effect Foo` declarations.
- Encode row types in TYPES section.
- Verify effect-typed cross-module call works end to end.

**Acceptance:**
- Spec importing `std/log` resolves its `Log` effect; `.qzmod` cache populated correctly.
- Effect-polymorphic function `def f<e>(): ... can e` cached and consumed across module boundaries.

**Sized:** ~3-5 days. (Most of this is exercising existing type-pickler code; row variants are the new bit.)

### Phase 5 — Quake integration polish

- `quake guard` validates `.qzmod` consistency.
- `quake clean` sweeps `.quartz-cache/`.
- `quake build:fresh` flag bypasses `.qzmod`.
- Documentation in `docs/QUAKE.md`.

**Acceptance:**
- `quake guard` after a `self-hosted/*.qz` edit produces fresh `.qzmod` files matching the new compiler.
- `quake clean && quake build` works from scratch.

**Sized:** ~1-2 days.

### Phase 6 — Qspec suite measurement and tuning

- Run full qspec suite cold (no cache) and warm (with `.qzmod`).
- Profile: where's the remaining time?
- Identify the next optimization target.

**Acceptance:**
- **Cold qspec run: <5 min** (target was <3, but cold case is the harder one).
- **Warm qspec run (one spec edited): <30s.** ✅ — 2.08s measured (INC.1.11).
- Time breakdown documented.
- **Suite correctness:** INC.1 introduced zero regressions — verified 2026-05-15 by IR-diffing all 809 specs against the pre-epic baseline (`quartz-pre-inc-1-1-golden`): 777 byte-identical, 2 differ only in an address-derived SSA register-name token, the rest fail identically on the baseline. Pre-existing qspec failures are tracked as ROADMAP **A.17**, not a Phase 6 gate.

**Sized:** ~2-3 days.

### Phase 7+ (deferred to next epic)

- MIR_BODIES section + `@inline_export` annotation.
- Cross-machine cache (CAS layer).
- Salsa-style per-query persistence (if Phase 6 measurement justifies).
- Textual `.qzmodi` interface (if cross-compiler-version compat ever becomes a goal).

**Total Phase 1-6 size: ~3-4 weeks.** In Quartz-time (per CLAUDE.md's D9 calibration), that's ~1 week.

---

## 11. Decision Log (closed)

Resolved with user 2026-05-12 before Phase 1 starts. Recorded here for audit.

1. **Cache directory: `.quartz-cache/<compiler_hash[:16]>/<module>.qzmod`.** Consistent with existing `.quartz-cache/` convention. ✅
2. **Unconditional rollout, no `--qzmod-cache` flag.** The cache is advisory (Principle #6); hash mismatch or decode error falls back to from-scratch automatically. `rm -rf .quartz-cache/` is the rollback knob; `quake guard`'s fixpoint check catches any cache that poisons output. Adding a flag would be the "for backward compat / to avoid breaking things" shortcut CLAUDE.md explicitly forbids pre-launch. ✅
3. **STRINGS dedup is per-`.qzmod` (not cross-module).** Each module's STRINGS loads into its own slot in the consumer's tc.registry; no runtime cross-module dedup win to justify the complexity. ✅
4. **MIR encoding reuses `quake snapshots` format.** Already deterministic and round-trip-proven; no reason to invent a second format. v2 may tighten if size becomes load-bearing. ✅
5. **MAJOR/MINOR semantics are SemVer-shaped.** MAJOR bumps break readers (renamed fields, changed encoding in mandatory sections); MINOR bumps are additive (new sections, new optional fields with defaults). Mirrors TASTy's major/minor split. ✅
6. **Delete the stale `qzi.qz` stub** from `INCREMENTAL_COMPILATION_PLAN.md` (Feb 2026). Anticipated a different design and is a stale-state liability. Delete in Phase 1's commit. ✅

---

## 12. References

The recommendations in this design synthesize the following research. Citations are inline so the reasoning is auditable.

### Rust ecosystem
- [Libraries and Metadata — rustc dev guide](https://rustc-dev-guide.rust-lang.org/backend/libs-and-metadata.html) — the `.rlib` / `.rmeta` split, pipelining.
- [`rustc_mir_transform::cross_crate_inline`](https://github.com/rust-lang/rust/blob/master/compiler/rustc_mir_transform/src/cross_crate_inline.rs) — the cost-bounded inline heuristic.
- [Incremental Compilation in Detail — rustc dev guide](https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation-in-detail.html) — the on-disk query cache, failure modes.
- [The Red-Green Algorithm — Salsa](https://salsa-rs.github.io/salsa/reference/algorithm.html) — backdating, durability tiers.

### ML family
- [GHC Inlining and Specialisation](https://wiki.haskell.org/Inlining_and_Specialisation), [Tweag: Recompilation avoidance](https://www.tweag.io/blog/2022-11-03-blog_recompilation/) — `.hi` fingerprints.
- [OCaml Native-Code Compilation](https://ocaml.org/manual/5.3/native.html), [`-opaque` flag discussion](https://github.com/ocaml/ocaml/issues/6389) — `.cmx` recompile-the-world cost.
- [Swift Library Evolution](https://www.swift.org/blog/library-evolution/) — dual binary + textual format, ABI vs module vs library stability axes.

### Modern compiled languages
- [TASTy Overview — Scala documentation](https://docs.scala-lang.org/scala3/guides/tasty-overview.html) — section + versioned-header model.
- [Lean 4 — Source Files and Modules](https://lean-lang.org/doc/reference/latest/Source-Files-and-Modules/) — `.olean` compacted mmap'd format.
- [Idris 2 Implementation Overview](https://idris2.readthedocs.io/en/latest/implementation/overview.html) — lazy `ContextEntry` decoding.
- [Koka: Programming with Row-polymorphic Effect Types (Leijen)](https://arxiv.org/pdf/1406.2061) — effect rows in module signatures.

### Build systems and caching
- [Build Systems à la Carte (Mokhov / Mitchell / Peyton Jones)](https://www.microsoft.com/en-us/research/wp-content/uploads/2018/03/build-systems.pdf) — scheduler × rebuilder taxonomy.
- [Bazel Remote Caching](https://bazel.build/remote/caching), [ccache Manual](https://ccache.dev/manual/latest.html) — content-addressed caches, `compilercheck=content`.
- [Nix RFC 062 — Content-Addressed Paths](https://github.com/NixOS/rfcs/blob/master/rfcs/0062-content-addressed-paths.md) — early-cutoff via output equality.

---

## 13. What This Replaces / Supersedes

- **`INCREMENTAL_COMPILATION_PLAN.md`** (Feb 2026) — superseded by this document. Its Option A/B/C analysis is informative but the recommendations have been overtaken by the production-language research. The existing `qzi.qz` stub should be removed (open question #6).
- **`5.0f.d.*` epic** — the live-state sharing approach is abandoned. The `.qzmod` artifact path replaces it.
- **`build_cache.qz` Tier 0/1/2** — preserved. `.qzmod` is a new layer above Tier 1; the three layers compose, they don't conflict.
