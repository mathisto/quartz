# argparse

## Structs

### `ArgParser` *(std/argparse.qz:23)*

Declarative command-line argument parser.

Inspired by Ruby's Thor/Optimist: one line per flag, auto-generated help,
short + long form support, subcommands, repeatable options.

Example:
  var cli = argparser_new("myapp", "1.0.0", "A great tool")
  argparser_command(cli, "build", "Compile the project")
  argparser_flag(cli, "-v", "--verbose", "Show detailed output")
  argparser_option(cli, "-o", "--output", "Output file path")
  var args = argparser_parse_args(cli)
  var cmd = parsed_command(args)
  var verbose = parsed_has(args, "--verbose")
  var out = parsed_get(args, "--output")
Entry kinds stored as strings for Vec<String> compat.
"0" = flag, "1" = option, "2" = repeatable option, "3" = command

| Field | Type |
|-------|------|
| `prog_name` | `String` |
| `prog_version` | `String` |
| `prog_desc` | `String` |
| `short_names` | `Vec<String>` |
| `long_names` | `Vec<String>` |
| `descriptions` | `Vec<String>` |
| `kinds` | `Vec<String>` |
| `count` | `Int` |

### `ParsedArgs` *(std/argparse.qz:37)*

Registered entries (flags, options, commands)

| Field | Type |
|-------|------|
| `keys` | `Vec<String>` |
| `values` | `Vec<String>` |
| `positionals` | `Vec<String>` |
| `command` | `String` |

## Functions

### `argparser_new(): ArgParser` *(std/argparse.qz:49)*

Create a new argument parser.

---

### `argparser_flag(): Void` *(std/argparse.qz:67)*

Register a boolean flag (no value).

---

### `argparser_option(): Void` *(std/argparse.qz:76)*

Register an option that takes a value.

---

### `argparser_option_repeat(): Void` *(std/argparse.qz:85)*

Register a repeatable option (can appear multiple times, e.g. -I path).

---

### `argparser_command(): Void` *(std/argparse.qz:94)*

Register a subcommand.

---

### `argparser_find(): Int` *(std/argparse.qz:103)*

Find an entry by short or long name. Returns index or -1.

---

### `argparser_find_command(): Int` *(std/argparse.qz:124)*

Check if a string matches any registered command.

---

### `argparse_is_flag(): Int` *(std/argparse.qz:139)*

Check if a string starts with "-".

---

### `argparser_parse_args(): ParsedArgs` *(std/argparse.qz:149)*

Parse command-line arguments from argc/argv.

---

### `parsed_has_in(): Int` *(std/argparse.qz:256)*

Internal helper: check if a key exists in parallel key/value vecs.

---

### `parsed_has(): Int` *(std/argparse.qz:269)*

Check if a flag or option was provided.

---

### `parsed_get(): String` *(std/argparse.qz:274)*

Get the value of an option. Returns empty string if not found.

---

### `parsed_get_all(): Vec<String>` *(std/argparse.qz:287)*

Get all values for a repeatable option. Returns Vec<String>.

---

### `parsed_command(): String` *(std/argparse.qz:301)*

Get the matched subcommand name (empty string if none).

---

### `parsed_positional(): String` *(std/argparse.qz:306)*

Get a positional argument by index. Returns empty string if out of range.

---

### `parsed_positionals(): Vec<String>` *(std/argparse.qz:317)*

Get all positional arguments.

---

### `argparser_print_help(): Void` *(std/argparse.qz:322)*

Print formatted help text.

---

### `argparser_new(): ArgParser` *(std/argparse.qz:415)*

--- Convenience API (simpler signatures for testing / quick scripts) ---
Create a bare parser with no metadata and no auto-registered flags.

---

### `argparser_flag(): Void` *(std/argparse.qz:430)*

Register a flag without description.

---

### `argparser_option(): Void` *(std/argparse.qz:435)*

Register an option without description.

---

### `argparser_parse(): ParsedArgs` *(std/argparse.qz:440)*

Parse an explicit Vec<String> of arguments (for testing without argc/argv).

---

### `argparse_has(): Int` *(std/argparse.qz:490)*

Alias: check if a flag/option was provided.

---

### `argparse_get(): String` *(std/argparse.qz:495)*

Alias: get an option value.

---

