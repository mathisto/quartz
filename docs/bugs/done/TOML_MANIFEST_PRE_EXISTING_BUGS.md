# `std/toml/manifest.qz` has pre-existing bugs masked by silent erasure

**Status:** ✅ MOOT — the file `std/toml/manifest.qz` was deleted `cef12588` (B.15a, user-ratified). The dormant bugs described below no longer exist because their host file is gone. Retired to `docs/bugs/done/`.

**Filed:** 2026-05-21 (surfaced while shipping QZ0220 — see
`TYPECHECK_ACCEPTS_UNDEFINED_TYPE_NAME_AS_PARAM.md`).
**Severity:** Low — `std/toml/manifest.qz` is **orphaned**. Repo-wide
grep shows no module imports it. `std/toml.qz` re-exports `toml/value`,
`toml/lexer`, `toml/parser`, `toml/stringify` but not `toml/manifest`.
The pre-existing bugs are dormant until someone wires it up.

## Summary

After QZ0220 + Path B (the `TomlTable` alias) shipped, manifest.qz's
8 `TomlTable` callsites resolve cleanly. With the type now meaningful,
the function bodies that were typechecking against silent `TYPE_ERROR`
(everything matches anything) now check against the real shape. Two
classes of pre-existing bugs surface:

### Class A — `toml_err` is called but never defined (4 sites)

```
error[QZ0401]: Undefined function: toml_err — Did you mean 'toml_ok'?
   --> ./std/toml/manifest.qz:688:12  return toml_err("Missing required [package] section", 0, 0)
   --> ./std/toml/manifest.qz:695:14    return toml_err("[package] must be a table", 0, 0)
   --> ./std/toml/manifest.qz:700:12  return toml_err("Missing required field: package.name", 0, 0)
   --> ./std/toml/manifest.qz:703:12  return toml_err("Missing required field: package.version", 0, 0)
```

`std/toml/value.qz` defines `toml_ok(value)` but no matching
`toml_err(message, line, col): TomlResult`. The four callsites pass
the right signature for building a `TomlResult::Err(TomlError {
message, location: TomlLocation { line, col } })`, so the fix is
either:

* **Path X — add the helper in `value.qz`:**
  ```qz
  def toml_err(message: String, line: Int, column: Int): TomlResult
    return TomlResult::Err(TomlError {
      message: message,
      location: TomlLocation { line: line, column: column }
    })
  end
  ```
* **Path Y — inline the construction at each callsite.** Less DRY but
  removes the helper dependency.

### Class B — match-arm type mismatch (10 sites)

```
error[QZ0202]: Match arm type mismatch: expected 'Void', found 'Int' (first arm at line 423)
   --> ./std/toml/manifest.qz:429:10    _ => ()
   --> ./std/toml/manifest.qz:509:10    _ => ()
   --> ./std/toml/manifest.qz:711:14    _ => ()
   --> ./std/toml/manifest.qz:721:14    _ => ()
   --> ./std/toml/manifest.qz:730:14    _ => ()
   --> ./std/toml/manifest.qz:747:14    _ => ()
   --> ./std/toml/manifest.qz:764:14    _ => ()
   --> ./std/toml/manifest.qz:777:14    _ => ()
   --> ./std/toml/manifest.qz:794:14    _ => ()
   --> ./std/toml/manifest.qz:804:14    _ => ()
```

Pattern at every site: a `match value` block iterates a TOML value,
the typed arm calls `result.push(...)` (returns `Int`), and `_ => ()`
returns `Void`. The match is being used for its side effect, not its
return value — Quartz requires arm types to unify even in
statement-position match. Fix shape:

```qz
match value
  TomlValue::Array(arr) =>
    for item in arr
      match item
        TomlValue::String(s) =>
          result.push(s)
          ()
        _ => ()
      end
    end
  _ => ()
end
```

Append a `()` after each side-effecting expression so all arms produce
Void. Alternatively change the call to a statement form that doesn't
contribute its value.

## Pull-in trigger

Wire up the package-manifest parser (Cargo.toml-style `Quartz.toml`
support, or whatever its actual consumer ends up being). At that
point either:

1. **Fix:** Land Class A + Class B together. The file compiles cleanly
   against the QZ0220 + Path B world.
2. **Delete:** Per D7 pre-launch absolutism — 969 LOC of broken code
   that nothing imports is a deletion candidate. Recover from git
   history when the package-manifest feature actually starts. Net:
   shrinks the codebase, removes the latent failure mode, doesn't
   block anything because nothing was using the code.

Recommendation today: shelf (do nothing). The bugs are dormant. The
fix cost is ~1 hour. The delete is one `git rm`. Both wait for an
actual consumer.

## Files

* `std/toml/manifest.qz` (969 LOC, untouched since 2026-05-07 cross-
  cutting UFCS refactor in `29ad1edb`).
* `std/toml/value.qz` — has `toml_ok` but no `toml_err`.
