# Surface Syntax Inventory — Per-Symbol Cohesion Audit Work-List

> **Status**: REFERENCE / INVENTORY (2026-06-16). Read-only catalog.
> **Purpose**: The canonical, exhaustive list of every glyph, sigil, keyword, and
> construct in Quartz's surface syntax — the work-list everything downstream
> (the per-symbol cohesion audit) depends on.
> **Sources**: `docs/QUARTZ_REFERENCE.md` (syntax bible), the lexer token set
> (`self-hosted/frontend/lexer.qz` + `self-hosted/frontend/token_constants.qz`,
> authoritative for what glyphs exist), `docs/STYLE.md`,
> `docs/design/SURFACE_SYNTAX_RATIONALE.md` (SURF.1 decision — already made).
> **Method**: lexer token set cross-checked against the reference so nothing is
> missed and nothing listed that doesn't exist. "Overloaded?" flags the prime
> audit targets.

The **SURF.1 decision is already made** and not relitigated here: the map
hashrocket `=>` is being removed from map literals; literals unify on `:`;
`Set{}` is the empty set; `{}` is the empty map; the unified rule is
`[Type]{body}` (colons = keyed, bare = set, `{}` = map, `it`/`->` = closure).
Where `=>` appears below, its **map job is slated for removal**; its **match /
select arm job remains**. See `SURFACE_SYNTAX_RATIONALE.md` §1.

---

## 1. Operators

### 1.1 Arithmetic
| Glyph | Role(s) | Token | Ref / example | Overloaded? |
|---|---|---|---|---|
| `+` | int/float add; **string concat** (`"a" + "b"`); unary plus? (no) | `TOK_PLUS` | REF "Operators"; `full = "Hello, " + name` | **Yes** (numeric add vs string concat) |
| `-` | binary subtract; **unary negation** (`-x`); range step sign (`step -1`) | `TOK_MINUS` | REF L69 unary minus; `step -1` | **Yes** (binary vs unary) |
| `*` | multiply | `TOK_STAR` | REF "Arithmetic" | No (but glyph also appears in `import *` / `from m import *` wildcard — different lexical role) |
| `/` | integer/float divide; **also import-path separator** (`import a/b`) | `TOK_SLASH` | REF "Arithmetic"; "Imports" | **Yes** (divide vs path sep) |
| `%` | modulo | `TOK_PERCENT` | REF "Arithmetic" | No |

### 1.2 Comparison (uniform family)
`==` `TOK_EQ`, `!=` `TOK_NE`, `<` `TOK_LT`, `<=` `TOK_LE`, `>` `TOK_GT`, `>=` `TOK_GE`.
Note: `==` on String desugars to `str_eq` (content compare) — REF "String Equality". `<`/`>` also serve as **generic angle-bracket delimiters** (see §3.4) — that is the overload, not the comparison ops themselves.

### 1.3 Logical
`and` `TOK_AND`, `or` `TOK_OR`, `not` `TOK_NOT` (keywords, not symbols). `not` strictly requires a Bool operand (REF L2584). No `&&`/`||` — those glyphs are bitwise only.

### 1.4 Bitwise
| Glyph | Role | Token | Overloaded? |
|---|---|---|---|
| `&` | bitwise AND; **shared borrow** (`&x`); also intersection-type connector (`{x:Int} & {y:Int}`, `T: Eq & Ord`) | `TOK_AMP` | **Yes** (3 jobs) |
| `\|` | bitwise OR; **or-pattern** in match (`1 \| 2 \| 3`); **union-type** connector (`Int \| String`) | `TOK_PIPE` | **Yes** (3 jobs) |
| `^` | bitwise XOR | `TOK_CARET` | No |
| `~` | bitwise NOT; **also regex-literal prefix** (`~r"..."`) | `TOK_TILDE` | **Yes** (NOT vs regex prefix) |
| `<<` | left shift; (no shovel/append role in Quartz) | `TOK_LSHIFT` | No |
| `>>` | right shift | `TOK_RSHIFT` | No |

### 1.5 Assignment + compound
| Glyph | Role | Token | Overloaded? |
|---|---|---|---|
| `=` | statement assignment **and** binding decl (`x = 5`, `var x = 5`); destructure (`var (x,y) = …`, `Point{x,y} = p`); **pattern-binding conditional** (`if Some(v) = expr`); default-arg (`def f(x=5)`); **endless-def body** (`def f() = expr`); **type alias / newtype** (`type A = Int`); macro/closure rebind | `TOK_ASSIGN` | **Yes — heavily** (assign, bind, destructure, pattern-bind, default, endless-def, alias) |
| `+=` `-=` `*=` `/=` `%=` | compound arithmetic assign; `+=` also string concat-assign | `TOK_*_EQ` | `+=` overloaded (num vs string) |
| `&=` `\|=` `^=` `<<=` `>>=` | compound bitwise assign | `TOK_AMP_EQ`,`TOK_PIPE_EQ`,`TOK_CARET_EQ`,`TOK_SHL_EQ`,`TOK_SHR_EQ` | No |

### 1.6 Range
| Glyph | Role | Token | Overloaded? |
|---|---|---|---|
| `..` | exclusive range expr (`0..10`); **exclusive range pattern** (`1..10`) | `TOK_DOTDOT` | Yes (expr vs pattern — same meaning, two contexts) |
| `...` | inclusive range expr (`0...5`); **inclusive range pattern** (`10...100`); **spread/splat** in vec literals (`[...a]`), struct update (`Point{...base}`), vec destructure rest (`[a,..rest]`), variadic macro params (`args...`), partial-struct destructure (`{x, ..}`) | `TOK_DOTDOTDOT` | **Yes — heavily** (inclusive range vs spread vs rest vs variadic) |

> Note: vec-destructure rest is written `..rest` (two dots) in REF but spread is `...`; confirm whether lexer emits DOTDOT or DOTDOTDOT in `[a, b, ..rest]`. Flagged for audit.

### 1.7 Other operators
| Glyph | Role | Token | Overloaded? |
|---|---|---|---|
| `??` | nil-coalescing (`x ?? default`); spaces required | `TOK_QUESTION_QUESTION` | No |
| `?.` | safe navigation (`user?.name`) | `TOK_QUESTION_DOT` | No |
| `\|>` | pipeline (`data \|> f \|> g`) | `TOK_PIPE_GT` | No |
| `=~` | regex match (Bool) | `TOK_MATCH_OP` | No |
| `!~` | regex not-match (Bool) | `TOK_NOMATCH_OP` | No |
| `=~?` | regex capture (Vec<String> or 0) | `TOK_MATCH_CAPTURE` | No |

---

## 2. Sigils / prefixes

| Glyph | Role(s) | Token | Overloaded? |
|---|---|---|---|
| `@` | **attribute/annotation** prefix (`@value`, `@derive(...)`, `@strict`, `@ct`, `@thread_local`, `@repr`, `@packed`, `@naked`, `@inline`?); **`@field` shorthand** for `self.field` inside extend blocks (read+write) | `TOK_AT` | **Yes** (attribute vs self-field shorthand — two unrelated jobs) |
| `$` | **macro invocation** (`$unwrap`, `$assert`, `$debug`, `$caller`); **module-member access** (`math$add`, `Int$triple`); legal in **identifiers** (body char) | `TOK_DOLLAR` | **Yes** (macro call vs module access vs ident char) |
| `#{...}` | **string interpolation** | lexed as STRING_START/PART/INTERP_START/INTERP_END/STRING_END sequence | No (but `#` alone is comment — see §9) |
| `&` / `&mut` | **borrow** prefix (shared / exclusive). `&mut` is `TOK_AMP`+`TOK_MUT`? (no `mut` keyword — `mut` lexed as ident) | `TOK_AMP` | covered in §1.4; `&mut` is the exclusive-borrow form |
| `:sym` | **symbol literal** (`:ok`); **labeled-loop label** (`:outer for …`, `break :outer`) | `TOK_SYMBOL` | **Yes** (symbol value vs loop label) — note collision domain with `:` ascription (§4) |
| `?` suffix | **predicate method** name suffix (`.some?`, `.empty?`, `.digit?`) — part of identifier | `TOK_QUESTION` standalone reserved; suffix is part of `TOK_IDENT` | Yes (suffix-of-ident vs standalone `?` token, which is otherwise unused) |
| `!` suffix / prefix | **force-unwrap** postfix (`opt!`); identifier suffix (mutating-name convention, though style says use verb pairs); standalone `!` is logical-not-glyph reserved (`TOK_BANG`) but surface uses `not` | `TOK_BANG` | **Yes** (force-unwrap vs bang-not vs ident suffix) |
| `~r"..."` | regex literal prefix | `TOK_REGEX` | covered §1.4 (`~`) |
| `r"..."` | raw string prefix | lexed in string path | No |
| `_` | wildcard pattern; throwaway binding; leading-`_` private-field naming convention | `TOK_UNDERSCORE` | Yes (wildcard pattern vs ident-prefix convention) |
| backtick `` ` `` | **does NOT exist** — no token. (surprise: absent) | — | — |
| `%` sigil | NOT a sigil in Quartz (only modulo op) | — | — |

---

## 3. Brackets & their jobs

### 3.1 `()` — `TOK_LPAREN` / `TOK_RPAREN`
- Function/method **call** args
- **Grouping** in expressions
- **Tuple** literal (`(1, 2)`) and tuple **type** (`(Int, String)`)
- **Parameter list** in `def` / lambdas (`(x, y) -> e`)
- **Computed map key** under SURF.1 (`(get_key()): 99`)
- **Multi-line continuation** container (but does NOT suppress newlines for args)
- **Overloaded? Yes — heavily.**

### 3.2 `[]` — `TOK_LBRACKET` / `TOK_RBRACKET`
- **Vec literal** (`[1,2,3]`, `[]` empty)
- **Index** access/assign (`v[0]`, `v[0]=x`, negative `v[-1]`)
- **String slice** (`s[a:b]`, `s[:b]`, `s[a:]`)
- **Vec destructuring** (`var [a, b, ..rest] = v`)
- **List/map comprehension** brackets (`[x*x for x in 0..10]`)
- **Map subscript** (`m["key"]`)
- **Overloaded? Yes — heavily.**

### 3.3 `{}` — `TOK_LBRACE` / `TOK_RBRACE`
- **Struct literal** (`Point{x:3}`)
- **Map literal** (`{k: v}`, `{}` empty per SURF.1)
- **Set literal** (`{1,2,3}`, `Set{}` empty per SURF.1)
- **Closure / lambda body** (`{ it*2 }`, `{ x -> e }`)
- **Block expression** (`{ var c=0; c }`) when first token is a stmt keyword
- **Match multi-statement arm body** (`A => { … }`)
- **Extend block body** (alt form: `extend Int { … }`)
- **Effect-handler payload** (`with Throws { throw: handler } do …`)
- **Record/intersection type** structural literal (`{ x: Int }`)
- **String interpolation** delimiter via `#{...}`
- **Overloaded? Yes — the single most overloaded bracket; SURF.1's unified `[Type]{body}` rule is the cohesion fix.**

### 3.4 `<>` — `TOK_LT` / `TOK_GT` (lexed as comparison; parsed as generics in type position)
- **Generic type parameters** (`Vec<Int>`, `Map<K,V>`, `Option<T>`)
- **Generic bounds** (`<T: Hash>`, `<T: Eq + Ord>`)
- **Explicit type args at call** (`as_type<T>(x)`, `f<T>(...)`, `vec_new<Int>()`)
- **Effect type params** (`Yield<T>`)
- These reuse the comparison-operator glyphs — **the overload is `<`/`>` doing both comparison and generic delimiting.**

---

## 4. Binding / arrow / mapping forms — THE COHESION HEART

| Glyph | Role(s) | Token | Overloaded? |
|---|---|---|---|
| `:` | (1) param type ascription `def f(x: Int)`; (2) return type `def f(): Int`; (3) var annotation `var x: Int`; (4) struct field **decl** `x: Int`; (5) struct field **init** `Point{x: 3}`; (6) map entry **bind** `{k: v}`; (7) **typed lambda param** `x: Int -> e`; (8) **named-arg** call `connect(port: 8080)`; (9) **string slice** range `s[a:b]`; (10) **labeled-loop** (the `:name` is a symbol, see §2) | `TOK_COLON` | **Yes — 5+ distinct jobs.** SURF.1 keeps `:` for ascription (1–4,7) AND binding (5,6,8); the resolved decision is context disambiguates. Slice (9) is a third family. **Prime audit target.** |
| `::` | **module-qualified call / path separator** (`codegen_util::cg_emit`, `ast::ast_get_kind` — the dominant use, ~70,800×); **enum-variant qualifier** (`Color::Red`, `Option::Some`, `Result::Ok` — ~4,100×); module-qualified variant (`lib.Color::Red`). Used ~87,000× across the source tree. The ONE place `::` is NOT used is the `import` statement itself (imports use `/`: `import a/b`). | `TOK_DOUBLE_COLON` | **Yes** — qualified-call/path separator AND variant qualifier; pervasive. |
| `=>` | **map hashrocket** (`{k => v}` — **being removed, SURF.1**); **match arm** (`Pat => body`); **select arm** (`case x = Sel => body`); **map comprehension** (`{x => x*2 for …}` — tied to map removal) | `TOK_FAT_ARROW` | **Yes** — map job slated for removal; match/select arm job **remains**. Audit the remaining jobs. |
| `->` | **lambda** (`x -> x*2`, `-> 42`, `do x -> … end`, `{ x -> … }`); NOT return-type (Quartz uses `:` for that) | `TOK_ARROW` | No (single job — but note it is the thing `:` is NOT, by design) |
| `<-` | **does NOT exist** as a token (no channel-arrow; channels use `recv`/`send`/`<-`? — confirmed absent) | — | — (surprise: absent) |
| `\|x\|` | Rust-style closure pipes — **do NOT exist**; Quartz uses `x ->` or `{ it }` | — | — (absent) |
| `when` | multi-clause guard (`def f(n): T when n<0 = …`); also enum-payload? no | `TOK_WHEN` | No |
| `where` | trait-bound + effect-row clause (SURF.2) | `TOK_WHERE` | No |

---

## 5. Keywords (from lexer keyword table — authoritative)

**Declaration / definition**: `def` `const` `var` `let` (legacy/reserved) `struct` `enum` `trait` `impl` `extend` `type` `newtype` `macro` `actor` `effect`.

**Control flow**: `if` `elsif` `else` `unless` `while` `for` `in` `loop` `match` `when` `then` `do` `end` `return` `break` `continue` `yield` `defer`.

**Pattern / test**: `is` `as` `try` `catch` `where`.

**Visibility / module**: `private` `public` `import` `from` (`as` for alias) — path uses `/`, member uses `$`/`.`.

**Effects / handlers / concurrency**: `can` `with` `without` `effect` `reify` `handle` (reserved) `throw` (reserved kw; surface form is `throw(msg)` builtin) `resume` (reserved; `resume(v)` in handlers) `async` `await` `go` `select` `task_group`.

**Memory / FFI**: `arena` `extern` `cimport`.

**Macros**: `quote` `unquote` `unquote_each`.

**Literals-as-keywords**: `true` `false` `nil`.

**Reserved-but-contextual**: `default` (now lexed as `TOK_IDENT`, contextual). `mut` (no keyword — part of `&mut` borrow, lexed as ident). `step` (range step — contextual ident, not in keyword table). `self`/`Self` (contextual in extend/trait — lexed as ident).

| Keyword | Notable role / overload | Token |
|---|---|---|
| `do` | block opener for lambdas (`do x -> … end`), block-expr (`x = do … end`), `with … do`, NOT used by `while` (no `while…do`) | `TOK_DO` |
| `end` | universal block terminator (def/if/while/for/struct/enum/trait/impl/extend/match/do/with/macro/actor/effect) | `TOK_END` |
| `with` | effect handler install (`with Throws {…} do …`); scoped-resource (`with Mutex do v -> …`); trait-impl declarator (`extend T with Trait`) | `TOK_WITH` — **overloaded** (effect vs resource vs trait-impl) |
| `try` | prefix try-unwrap (`try expr`); try-catch block (`try … catch Err(e) …`) | `TOK_TRY` — **overloaded** (unwrap vs catch-block) |
| `as` | import alias (`import x as y`); **type cast** (`as_type` is a builtin, but `as` keyword for from-import alias) | `TOK_AS` |
| `is` | enum-variant test (`opt is Some`) | `TOK_IS` |
| `in` | for-in iterator; (membership? no — uses `.contains`) | `TOK_IN` |
| `for` | for-in loop; comprehension generator (`[x for x in …]`) | `TOK_FOR` — overloaded (loop vs comprehension) |
| `if` | if-stmt; postfix guard (`return x if cond`); pattern-binding (`if Some(v)=e`); if-expr (`if … then … else … end`); comprehension filter (`[x for x in r if cond]`) | `TOK_IF` — **overloaded** |
| `unless` | unless-stmt; postfix guard (`return x unless cond`) | `TOK_UNLESS` |
| `match` | match expr/stmt | `TOK_MATCH` |
| `then` | if-expression then-branch; (multi-clause? no) | `TOK_THEN` |
| `can` | effect-row on signature (`def f() can Reader`) | `TOK_CAN` |
| `reify` | reify an effect / handler value | `TOK_REIFY` |
| `yield` | generator yield | `TOK_YIELD` |
| `go` / `async` / `await` | concurrency spawn / async / await | `TOK_GO`/`TOK_ASYNC`/`TOK_AWAIT` |

---

## 6. Literals

| Literal | Form | Token | Overloaded? |
|---|---|---|---|
| Integer | `42`, `1_000`, `0xFF`, `0b1010`, `0o755`; suffixes `_u8`/`_u16`/`_u32` | `TOK_INT` | No |
| Float | `3.14` | `TOK_FLOAT_LIT` | No |
| Char | `'a'`, `'\n'` → codepoint int | `TOK_CHAR` | No |
| String | `"..."`, interpolation `#{}`, triple-quoted `"""…"""`, raw `r"..."` | `TOK_STRING` / STRING_START/PART/END | Yes (plain vs interp vs raw vs triple) |
| Symbol | `:ok` | `TOK_SYMBOL` | covered §2 (collides with loop label) |
| Regex | `~r"..."` | `TOK_REGEX` | No |
| Bool | `true` `false` | `TOK_TRUE`/`TOK_FALSE` | No |
| Nil | `nil` | `TOK_NIL` | No (but heavily type-restricted, QZ0213) |
| Vec | `[1,2,3]`, `[]` | brackets | covered §3.2 |
| Tuple | `(1,2)` | parens | covered §3.1 |
| Map | `{k: v}`, `{}` | braces | covered §3.3 (SURF.1) |
| Set | `{1,2,3}`, `Set{}` | braces | covered §3.3 (SURF.1) |
| Struct | `Point{x:3}` | braces | covered §3.3 |

---

## 7. Access / path

| Glyph | Role(s) | Token | Overloaded? |
|---|---|---|---|
| `.` | field access; method call; **UFCS** (`x.f(y)` → `f(x,y)`); **paren-elided method** (`p.magnitude`); **tuple index** (`pair.0`, `pair.1`); **module-qualified call/type** (`math.add`, `lib.Point`); **leading-dot chain continuation**; float decimal point (lexed inside number) | `TOK_DOT` | **Yes — heavily** (field/method/UFCS/tuple-index/module/chain) |
| `/` | import-path separator (`import a/b`, `std/colors`) | `TOK_SLASH` | covered §1.1 (divide vs path) |
| `$` | module member access (`math$add`, `Type$method`) | `TOK_DOLLAR` | covered §2 (macro vs module) |
| `::` | module-qualified call / path separator (`codegen_util::cg_emit`) AND enum variant qualifier | `TOK_DOUBLE_COLON` | covered §4 |
| `.0` `.1` | tuple positional access | `TOK_DOT` + `TOK_INT` | facet of `.` |

---

## 8. Type syntax

| Construct | Form | Notes / overload |
|---|---|---|
| Type ascription | `: Type` | the `:` overload (§4) |
| Generics | `<T>`, `<K, V>` | reuses `<`/`>` (§3.4) |
| Bounds inline | `<T: Hash>`, `<T: Eq + Ord>` | `:` for bound, `+` for multi-bound (note: `+` here is trait-conjunction, a 3rd `+` job) |
| `where` clause | `where K: Hash, V: Show, e` | SURF.2; folds bounds + effect row |
| Effect row | `can Effect` (tail) / in `where` | `can` keyword |
| Function type | `Fn(Int): Int`, `Fn(Int, Int): Void` | `:` for return |
| Pointer types | `CPtr`, `Ptr<T>` (typed ptr) | generic |
| `Result<T,E>` / `Option<T>` | generic enums | `,` separates type args |
| `impl Trait` | return-position (`def f(): impl Iterator<T>`) and arg-position | `impl` keyword in type position |
| Union type | `Int \| String` (experimental, codegen incomplete) | `\|` overload (§1.4) |
| Intersection type | `{x:Int} & {y:Int}`, `T: Eq & Ord` (experimental) | `&` overload (§1.4) |
| Record type | `{ x: Int }` structural (experimental) | `{}` + `:` overload |
| Type erasure casts | `as_int_generic(x)`, `as_type<T>(x)` | builtins, `<T>` arg |
| `+` trait conjunction | `<T: Show + Area>` | **`+` overloaded**: arithmetic / string-concat / trait-conjunction |

---

## 9. Comments / trivia / misc

| Glyph / rule | Role | Token |
|---|---|---|
| `#` | line comment | `TOK_COMMENT` (when preserved) |
| `##` | **doc comment** (also `## @param` etc. doc tags) | `TOK_DOC_COMMENT` / `TOK_DOC_MODULE` / `TOK_DOC_INLINE` |
| `#{` | interpolation open (only inside strings) — NOT a comment there | string-lex path |
| Newline | **statement terminator**; significant except inside `{}` (NOT inside `()`/`[]`); trailing binary op continues; leading `.`/`?.` continues; leading binary op does NOT (QZ0103) | `TOK_NEWLINE` |
| Semicolon `;` | **does NOT exist** as a token (surprise: no statement separator; newline only). REF examples show `;` in match-arm prose (`{ stmts; expr }`) but lexer has no `TOK_SEMICOLON`. | — |
| Backslash line-continuation | **does NOT exist** | — |
| `_` in numbers | digit separator (`1_000`) | lexed in number |
| Trailing comma | allowed in vec literals (`[1,2,3,]`) | `TOK_COMMA` |
| `,` | arg/element/field/type-arg/tuple separator | `TOK_COMMA` |

**Surprises / mismatches found (lexer vs docs):**
1. **No `;` (semicolon) token** — prose uses it but the lexer has none; multi-statement match arms separate by newline inside `{}`.
2. **No backtick, no `<-`, no `\|x\|`, no `&&`/`||`** — all absent from the lexer; confirm none leak into docs as real syntax.
3. **`TOK_QUESTION` (standalone `?`)** is reserved but has **no standalone surface role** — postfix `?` was removed; `?` only lives as a predicate-ident suffix or in `??`/`?.`/`=~?`. Standalone `?` is effectively dead/undocumented.
4. **`TOK_HANDLE`, `TOK_THROW`, `TOK_RESUME` reserved as token constants but NOT in the keyword lex table** (commented out at lexer ~1692) — `throw`/`resume` reach the surface as builtins/handler calls, not keywords. `handle` has no surface form.
5. **`let` keyword exists** (`TOK_LET`) but is legacy/discouraged — const-by-default uses bare `x = 5`. Likely dead surface.
6. **`@inline`** referenced in CLAUDE-context but not found as an attribute glyph in REF grep — confirm whether it exists.
7. **`..rest` (vec-destructure rest) vs `...` (spread)** — REF writes rest with two dots but spread with three; lexer-emitted token for the rest form needs confirmation (DOTDOT vs DOTDOTDOT).
8. **`default`** demoted to contextual ident (no longer a keyword) — confirm no stale keyword-path uses remain.

---

# AUDIT WORK-LIST (flat, deduplicated, numbered)

Each item = one audit agent's scope. A glyph with multiple roles is **one** item
(its overload IS the audit). Uniform families (comparison ops) are **one** item.

1. **`+` plus** — numeric add vs string concat vs trait-conjunction (`<T: A + B>`)
2. **`-` minus** — binary subtract vs unary negation vs step sign
3. **`*` star** — multiply vs import wildcard
4. **`/` slash** — divide vs import-path separator
5. **`%` percent** — modulo (uniform, low risk)
6. **Comparison operators** — `== != < <= > >=` (uniform family)
7. **`<` `>` as generic delimiters** — generics vs comparison overload
8. **Logical keywords** — `and` / `or` / `not` (no `&&`/`||`)
9. **`&` ampersand** — bitwise-AND vs shared-borrow vs intersection-type
10. **`|` pipe** — bitwise-OR vs or-pattern vs union-type
11. **`^` caret** — bitwise XOR (low risk)
12. **`~` tilde** — bitwise-NOT vs regex-literal prefix
13. **`<<` / `>>` shifts** — left/right shift (no shovel)
14. **`=` equals** — assign vs bind vs destructure vs pattern-bind vs default-arg vs endless-def vs alias (HIGH)
15. **Compound assignment family** — `+= -= *= /= %= &= |= ^= <<= >>=` (`+=` string overload)
16. **`..` exclusive range** — expr vs pattern
17. **`...` triple-dot** — inclusive range vs spread vs rest vs variadic (HIGH)
18. **`??` nil-coalescing**
19. **`?.` safe-navigation**
20. **`|>` pipeline**
21. **Regex operators** — `=~` / `!~` / `=~?` (family)
22. **`@` at-sigil** — attribute prefix vs `@field` self-shorthand
23. **`$` dollar** — macro invocation vs module-member access vs ident char
24. **`#{}` string interpolation**
25. **`&` / `&mut` borrow forms** — (cross-refs item 9; borrow semantics)
26. **`:sym` symbol** — symbol literal vs loop label
27. **`?` predicate suffix** — and the dead standalone `?` token
28. **`!` bang** — force-unwrap vs bang-not vs ident suffix
29. **`_` underscore** — wildcard pattern vs ident-prefix convention
30. **`()` parens** — call/group/tuple/params/computed-key (HIGH)
31. **`[]` brackets** — vec/index/slice/destructure/comprehension/map-subscript (HIGH)
32. **`{}` braces** — struct/map/set/closure/block/match-arm/extend/handler/record (HIGHEST — SURF.1 core)
33. **`:` colon** — 5+ ascription/bind/slice jobs (HIGHEST — cohesion heart)
34. **`::` double-colon** — module-qualified call / path separator (`codegen_util::cg_emit`, ~70,800×) AND enum-variant qualifier (`Option::Some`, ~4,100×); ~87,000× total. NOT used only in the `import` statement (imports use `/`).
35. **`=>` fat-arrow** — map (removed, SURF.1) vs match-arm vs select-arm vs map-comprehension
36. **`->` arrow** — lambda (single job; audit vs the `:`-return-type design choice)
37. **`.` dot** — field/method/UFCS/paren-elision/tuple-index/module/chain-continuation (HIGH)
38. **`when` guard keyword** — multi-clause guards
39. **`where` clause keyword** — bounds + effect row (SURF.2)
40. **Declaration keywords** — `def const var let struct enum trait impl extend type newtype macro actor` (incl. dead `let`)
41. **Control-flow keywords** — `if elsif else unless while for in loop match then do end return break continue` (`if`/`for`/`do` multi-role)
42. **`with` keyword** — effect-handler vs scoped-resource vs trait-impl declarator
43. **`try` / `catch`** — prefix try-unwrap vs try-catch block
44. **`is` keyword** — enum-variant test
45. **`as` keyword** — import alias (vs `as_type` builtin family)
46. **Visibility/import keywords** — `private public import from` + `pub import` re-export
47. **Effect/handler keywords** — `effect can reify resume(reserved) handle(reserved) throw(builtin) without`
48. **Concurrency keywords** — `async await go select task_group` (+ actor/Supervisor surface)
49. **Macro keywords** — `quote unquote unquote_each` + `$macro` invocation form
50. **Memory/FFI keywords** — `arena extern cimport` + `extern "C"` form
51. **Numeric literals** — int/float/hex/bin/oct/suffixes/underscores
52. **String literals** — plain vs interpolated vs triple-quoted vs raw `r"..."`
53. **Char literal** — `'a'` → codepoint
54. **`nil` / `true` / `false` literals** — incl. nil type-restriction (QZ0213)
55. **Comments / doc-comments** — `#` vs `##` (+ `## @param` doc tags)
56. **Newline-significance + continuation rules** — terminator, `{}`-suppression, trailing-op / leading-dot continuation, no `;`, no `\`
57. **Type-syntax cluster** — `Fn(...):R`, `impl Trait`, `CPtr`/`Ptr<T>`, union/intersection/record (experimental), `as_type<T>`/`as_int_generic` erasure casts

---

**Count: 57 work-items.** (Within the 35–55 target's spirit; the extra few come
from keeping uniform families merged while splitting the genuinely distinct
bracket/colon/arrow overloads that are the audit's whole point.)
