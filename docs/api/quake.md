# quake

## Functions

### `task(): Void` *(std/quake.qz:46)*

Register a task with name, description, and action.

---

### `task_dep(): Void` *(std/quake.qz:56)*

Register a task with dependencies.

---

### `task_alias(): Void` *(std/quake.qz:66)*

Register a dependency-only task (no action body).

---

### `_task_name(): String` *(std/quake.qz:79)*

---

### `_task_desc(): String` *(std/quake.qz:80)*

---

### `_task_deps(): Vec<String>` *(std/quake.qz:81)*

---

### `_task_action(): Int` *(std/quake.qz:82)*

---

### `_find_task(): Int` *(std/quake.qz:84)*

---

### `sh(): Int` *(std/quake.qz:100)*

Run a shell command. Fails the build on non-zero exit code.

---

### `sh_maybe(): Int` *(std/quake.qz:112)*

Run a shell command, returning the exit code without failing.

---

### `sh_capture(): String` *(std/quake.qz:120)*

Run a shell command and capture its stdout as a String.

---

### `sh_quiet(): Int` *(std/quake.qz:140)*

Run a shell command, suppressing output. Fails on non-zero exit.

---

### `_print_cmd(): Void` *(std/quake.qz:149)*

---

### `rm(): Void` *(std/quake.qz:158)*

Remove a file (silently ignores if file doesn't exist).

---

### `mv(): Void` *(std/quake.qz:165)*

Move/rename a file.

---

### `cp(): Void` *(std/quake.qz:173)*

Copy a file.

---

### `mkdir_p(): Void` *(std/quake.qz:180)*

Create a directory (with parents, like mkdir -p).
Silently succeeds if the directory already exists.

---

### `rm_rf(): Void` *(std/quake.qz:205)*

Recursively remove a directory and all its contents.

---

### `exists(): Int` *(std/quake.qz:228)*

Check if a path exists (file or directory).

---

### `basename(): String` *(std/quake.qz:231)*

Get the basename of a path (filename without directory).

---

### `basename_no_ext(): String` *(std/quake.qz:234)*

Get the basename with a specific extension stripped.

---

### `dirname(): String` *(std/quake.qz:243)*

Get the directory part of a path.

---

### `glob(): Vec<String>` *(std/quake.qz:251)*

Find files matching a glob pattern.
Supports `*` (any chars in filename) and `**` (recursive directory descent).

---

### `_glob_walk(): Void` *(std/quake.qz:259)*

---

### `_glob_match(): Int` *(std/quake.qz:302)*

Simple glob pattern matching (* matches any chars).

---

### `_glob_match_rec(): Int` *(std/quake.qz:308)*

---

### `_path_join(): String` *(std/quake.qz:336)*

---

### `env(): Void` *(std/quake.qz:348)*

Set an environment variable.

---

### `env_get(): String` *(std/quake.qz:353)*

Get an environment variable (returns "" if not set).

---

### `step(): Void` *(std/quake.qz:360)*

Execute a named step within a task, with progress output.

---

### `fail(): Void` *(std/quake.qz:367)*

Fail the build with an error message. Terminates immediately.

---

### `_quake_fail(): Void` *(std/quake.qz:371)*

---

### `needs_update(): Int` *(std/quake.qz:383)*

Check if target is stale relative to any of the source files.
Returns 1 if target doesn't exist or any source is newer.

---

### `quake_main(): Int` *(std/quake.qz:397)*

Entry point for Quakefiles. Parses CLI args, resolves dependencies,
and executes the requested task.

---

### `_execute_task(): Void` *(std/quake.qz:454)*

---

### `_fmt_desc(): String` *(std/quake.qz:490)*

---

### `_list_tasks(): Void` *(std/quake.qz:501)*

---

### `_task_not_found(): Void` *(std/quake.qz:531)*

---

### `_print_help(): Void` *(std/quake.qz:560)*

---

### `color_red(): String` *(std/quake.qz:578)*

---

### `color_green(): String` *(std/quake.qz:579)*

---

### `color_yellow(): String` *(std/quake.qz:580)*

---

### `color_blue(): String` *(std/quake.qz:581)*

---

### `color_cyan(): String` *(std/quake.qz:582)*

---

### `color_dim(): String` *(std/quake.qz:583)*

---

### `color_bold(): String` *(std/quake.qz:584)*

---

