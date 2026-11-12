# toml/manifest

## Structs

### `PackageInfo` *(std/toml/manifest.qz:80)*

Package metadata from the `[package]` section.

Contains all package identification and descriptive fields.

@since 6.0.0

| Field | Type |
|-------|------|
| `name` | `String` |
| `version` | `String` |
| `edition` | `String` |
| `description` | `String` |
| `license` | `String` |
| `authors` | `Vec<String>` |
| `repository` | `String` |
| `homepage` | `String` |
| `documentation` | `String` |
| `readme` | `String` |
| `keywords` | `Vec<String>` |
| `categories` | `Vec<String>` |

### `Dependency` *(std/toml/manifest.qz:137)*

Dependency specification.

Represents a single dependency from `[dependencies]` or `[dev-dependencies]`.

@since 6.0.0

| Field | Type |
|-------|------|
| `name` | `String` |
| `version` | `String` |
| `path` | `String` |
| `git` | `String` |
| `branch` | `String` |
| `tag` | `String` |
| `rev` | `String` |
| `features` | `Vec<String>` |
| `default_features` | `Bool` |
| `optional` | `Bool` |

### `BinTarget` *(std/toml/manifest.qz:188)*

Binary target configuration.

Represents a `[[bin]]` entry in the manifest.

@since 6.0.0

| Field | Type |
|-------|------|
| `name` | `String` |
| `path` | `String` |
| `required_features` | `Vec<String>` |

### `LibTarget` *(std/toml/manifest.qz:204)*

Library target configuration.

Represents the `[lib]` section in the manifest.

@since 6.0.0

| Field | Type |
|-------|------|
| `name` | `String` |
| `path` | `String` |

### `ExampleTarget` *(std/toml/manifest.qz:221)*

Example target configuration.

Represents an `[[example]]` entry in the manifest.

@since 6.0.0

| Field | Type |
|-------|------|
| `name` | `String` |
| `path` | `String` |
| `required_features` | `Vec<String>` |

### `Profile` *(std/toml/manifest.qz:241)*

Build profile configuration.

Represents `[profile.dev]` or `[profile.release]` settings.

@since 6.0.0

| Field | Type |
|-------|------|
| `name` | `String` |
| `debug` | `Bool` |
| `opt_level` | `Int` |
| `lto` | `Bool` |

### `Feature` *(std/toml/manifest.qz:264)*

Feature definition.

Represents a feature and its implied dependencies.

@since 6.0.0

| Field | Type |
|-------|------|
| `name` | `String` |
| `implies` | `Vec<String>` |

### `Manifest` *(std/toml/manifest.qz:281)*

Complete parsed manifest.

The top-level structure containing all manifest sections.

@since 6.0.0

| Field | Type |
|-------|------|
| `package` | `PackageInfo` |
| `dependencies` | `Vec<Dependency>` |
| `dev_dependencies` | `Vec<Dependency>` |
| `features` | `Vec<Feature>` |
| `default_features` | `Vec<String>` |
| `bin_targets` | `Vec<BinTarget>` |
| `lib_target` | `LibTarget` |
| `example_targets` | `Vec<ExampleTarget>` |
| `profile_dev` | `Profile` |
| `profile_release` | `Profile` |
| `include_dirs` | `Vec<String>` |

## Functions

### `package_info_new(): PackageInfo` *(std/toml/manifest.qz:325)*

Creates an empty PackageInfo with default values.

@returns A PackageInfo with empty/default fields

@since 6.0.0

---

### `dependency_new(): Dependency` *(std/toml/manifest.qz:347)*

Creates an empty Dependency with default values.

@returns A Dependency with empty/default fields

@since 6.0.0

---

### `lib_target_new(): LibTarget` *(std/toml/manifest.qz:367)*

Creates an empty LibTarget with default values.

@returns A LibTarget with default path

@since 6.0.0

---

### `profile_new(): Profile` *(std/toml/manifest.qz:380)*

Creates an empty Profile with default values.

@param name Profile name ("dev" or "release")
@returns A Profile with default settings

@since 6.0.0

---

### `manifest_new(): Manifest` *(std/toml/manifest.qz:393)*

Creates an empty Manifest with default values.

@returns A Manifest ready to be populated

@since 6.0.0

---

### `parse_string_array(): Vec<String>` *(std/toml/manifest.qz:419)*

Parses a string array from a TOML value.

@param value The TOML value (should be an array)
@returns Vector of strings, or empty if wrong type

@since 6.0.0

---

### `parse_package_section(): PackageInfo` *(std/toml/manifest.qz:440)*

Parses the [package] section.

@param table The package table
@returns Populated PackageInfo

@since 6.0.0

---

### `parse_dependency(): Dependency` *(std/toml/manifest.qz:479)*

Parses a single dependency entry.

@param name The dependency name (key)
@param value The dependency value (version string or table)
@returns Populated Dependency

@since 6.0.0

---

### `parse_dependencies_section(): Vec<Dependency>` *(std/toml/manifest.qz:521)*

Parses the [dependencies] or [dev-dependencies] section.

@param table The dependencies table
@returns Vector of Dependency structs

@since 6.0.0

---

### `parse_features_section(): Vec<Feature>` *(std/toml/manifest.qz:539)*

Parses the [features] section.

@param table The features table
@returns Vector of Feature structs

@since 6.0.0

---

### `parse_bin_target(): BinTarget` *(std/toml/manifest.qz:559)*

Parses a [[bin]] entry.

@param table The bin table
@returns Populated BinTarget

@since 6.0.0

---

### `parse_lib_section(): LibTarget` *(std/toml/manifest.qz:583)*

Parses the [lib] section.

@param table The lib table
@param pkg_name Package name (for default lib name)
@returns Populated LibTarget

@since 6.0.0

---

### `parse_example_target(): ExampleTarget` *(std/toml/manifest.qz:596)*

Parses a [[example]] entry.

@param table The example table
@returns Populated ExampleTarget

@since 6.0.0

---

### `parse_profile_section(): Profile` *(std/toml/manifest.qz:620)*

Parses a [profile.X] section.

@param table The profile table
@param name Profile name ("dev" or "release")
@returns Populated Profile

@since 6.0.0

---

### `manifest_load(): TomlResult<Manifest>` *(std/toml/manifest.qz:663)*

Loads and parses a quartz.toml manifest file.

This is the primary entry point for loading package manifests.

@param path Path to the quartz.toml file
@returns Ok with parsed Manifest, or Err with error details

@example
```be
result = manifest_load("quartz.toml")

match result
  TomlResult::Ok(m) =>
   puts("Package: " + m.package.name + " v" + m.package.version)
   puts("Dependencies: " + str_from_int(m.dependencies.size))
  TomlResult::Err(e) =>
    puts("Error: " + e.message)
end
```

@since 6.0.0

---

### `manifest_from_toml(): TomlResult<Manifest>` *(std/toml/manifest.qz:682)*

Parses a Manifest from an already-parsed TOML document.

Use this when you've already parsed the TOML and want to extract
the manifest structure.

@param doc The parsed TOML document
@returns Ok with Manifest, or Err if required fields are missing

@since 6.0.0

---

### `manifest_parse(): TomlResult<Manifest>` *(std/toml/manifest.qz:839)*

Parses a manifest from a TOML string.

@param source TOML source text
@returns Ok with Manifest, or Err with error details

@example
```be
toml = """
[package]
name = "test"
version = "0.1.0"
"""

result = manifest_parse(toml)
match result
  TomlResult::Ok(m) => puts(m.package.name)
  TomlResult::Err(e) => puts(e.message)
end
```

@since 6.0.0

---

### `manifest_has_dependencies(): Bool` *(std/toml/manifest.qz:858)*

Checks if a package has any dependencies.

@param m The manifest
@returns true if there are dependencies

@since 6.0.0

---

### `manifest_has_dev_dependencies(): Bool` *(std/toml/manifest.qz:868)*

Checks if a package has any dev dependencies.

@param m The manifest
@returns true if there are dev dependencies

@since 6.0.0

---

### `manifest_has_lib(): Bool` *(std/toml/manifest.qz:878)*

Checks if a package has a library target.

@param m The manifest
@returns true if lib section exists or if src/lib.be exists

@since 6.0.0

---

### `manifest_has_bins(): Bool` *(std/toml/manifest.qz:888)*

Checks if a package has any binary targets.

@param m The manifest
@returns true if there are bin targets

@since 6.0.0

---

### `manifest_get_dependency(): Dependency` *(std/toml/manifest.qz:899)*

Gets a dependency by name.

@param m The manifest
@param name Dependency name to find
@returns The Dependency, or nil if not found

@since 6.0.0

---

### `manifest_has_feature(): Bool` *(std/toml/manifest.qz:915)*

Checks if a feature is defined.

@param m The manifest
@param name Feature name to check
@returns true if the feature exists

@since 6.0.0

---

### `manifest_resolve_feature(): Vec<String>` *(std/toml/manifest.qz:933)*

Gets all features implied by a feature name.

Recursively resolves feature dependencies.

@param m The manifest
@param name Feature name
@returns Vector of all implied feature names

@since 6.0.0

---

### `manifest_resolve_feature_recursive(): Void` *(std/toml/manifest.qz:948)*

Recursive helper for feature resolution.

@param m The manifest
@param name Current feature
@param result Accumulator for resolved features
@param visited Already-visited features (cycle detection)

@since 6.0.0

---

