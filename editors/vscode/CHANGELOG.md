# Changelog

## 0.2.0 — 2026-03-19

### Grammar

- Add concurrency keywords: `go`, `async`, `await`, `yield`, `spawn` (`keyword.control.concurrency`)
- Move `select`, `when` to `keyword.control.flow` (were `keyword.other`)
- Add declaration keywords: `cimport`, `where`, `public`
- Add `task_group` to `keyword.other`
- Remove phantom keywords: `spawn_with`, `static_assert`, `linear`
- Add compound assignment operators: `&=`, `|=`, `<<=`, `>>=`
- Add `T?` optional type pattern with operator highlighting

### Language Configuration

- Add `select` to folding markers, indentation rules, and on-enter rules

### Snippets

- Add 11 new snippets: `async`, `await`, `go`, `forawait`, `sel`, `chan`, `gen`, `matchr`, `defopt`, `defm`
- Update `$try` description to mention Result support

### Build Integration

- Add commands: `quartz.run`, `quartz.build`, `quartz.test` with keybindings
- Add `$quartz` problem matcher for compiler error output
- Add `quake` task definition
- Add `quartz.quakePath` setting
- Add Run button in editor title bar for `.qz` files

### Marketplace

- Add README, CHANGELOG, LICENSE
- Add placeholder icon
- Update activation events for workspace detection

## 0.1.0 — 2025-12-15

- Initial release
- TextMate grammar for Quartz syntax
- 57 snippets
- Format-on-save via `quartz --format`
