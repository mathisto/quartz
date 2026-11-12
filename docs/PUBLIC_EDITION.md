# Public research edition

Prepared November 11, 2026, at Matt Kelly's direction. This is a retired research project, not a promise to ship a production language. The repository is left writable rather than placed in GitHub's read-only archive state.

## Provenance

The source snapshot was taken from development revision `6a35031c`, including the uncommitted standard-library, QSpec and guard-tooling changes present on the owner's machine. Those changes are preserved as unfinished work. The original checkout, its uncommitted files and full development history were not rewritten or reset. This public repository begins with a new publication commit rather than exposing private operations history.

Excluded from the public edition:

- Local caches, deployment configuration, private agent/session ledgers, generated website output and superseded compiler backup binaries.
- Bundled CHIP-8 game ROMs whose redistribution provenance was not established.
- The hyper bouba port: the source credits an upstream project for which this review did not locate a redistribution license. Its code remains in the private original until permission is clear.
- An unrelated unfinished afterdark subproject and internal qualitative audit notes. The public status still records the material compiler/safety limitations.

Local developer home-directory paths in text were generalized. No self-hosted compiler source behavior was changed for publication. The existing arm64 macOS seed compiler and Quake binaries are retained, with checksums in the [publication validation record](PUBLIC_VALIDATION.json).

## Review scope

Gitleaks 8.30.1 scanned the reachable committed history (4,511 commits scanned by the tool) and the extracted working snapshot with redaction enabled. It reported no secret detections. A separate content inventory reviewed local paths, network references, asset provenance and third-party notices. That is a bounded publication review, not proof that the compiler, runtime or cryptographic implementations are secure.

Known compiler faults, incomplete safety boundaries and the red validation baseline remain documented. Do not deploy the HTTP or cryptographic experiments as production infrastructure. Read [build and validation notes](BUILD.md) before running the seed toolchain.

The root MIT license covers Matt's original work. Third-party material and attributed ports retain their separate notices; see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
