# Quartz Guard — Source-Only Build Verification

> **Operational status (2026-07-19):** B4 protocol implementation and fixtures
> exist as uncommitted work, but the trusted first migration, externally pinned
> protected reproduction service, branch-protection requirement, and attended
> owner evidence are not complete. The protocol below describes the implemented
> design; it is not yet an established operational repository gate. See
> [`STATUS.md`](../STATUS.md) and the
> [owner review packet](conductor/quartz-guard-owner-review-packet-2026-07-16.md).

## Problem

Quartz is self-hosted: the committed binary at every commit was built from that commit's
source by a *previous* binary, which may have had compiled-in definitions that no longer
exist in the current source. When references to those definitions survive in the source
but the definitions are gone, the source becomes **fossilized** — it only builds if you
use a pre-existing binary that still remembers the ghost. A pure source-only build
(start from a known-good gen0, compile every forward commit in order) will fail at
the fossil commit and every commit downstream of it.

This is exactly what the 2026-03 → 2026-04 Linux bootstrap walk exposed. Multiple
fossils were discovered and have since been **fully resolved** (verified Apr 12, 2026):

| Fossil | Introduced | Status (Apr 12, 2026) |
|---|---|---|
| `ast_func_is_cconv_c` | `015b0305` (Apr 3) | ✅ Stub at `ast.qz:1489` (returns 0, intentional) |
| `TYPE_MAP` constant | `97d088ce` (Apr 6) | ✅ Defined at `type_constants.qz:90` |
| `NODE_IS_CHECK` constant | ~Apr 6 | ✅ Defined at `node_constants.qz:257` |
| `tc_type_is_hashable` / `tc_struct_is_hashable` / `tc_hashable_rejection_reason` / `tc_struct_hashable_rejection` | Apr 6 | ✅ Full impls in `typecheck_helpers.qz:527-596` |
| `mir_register_poll_callee` | `015b0305` | ✅ Full impl at `mir.qz:62` |
| `mir_func_set_cconv_c` / `mir_func_is_cconv_c` | `015b0305` | ✅ Full impl at `mir.qz:1156-1168` |
| `mir_block_set_switch` / `mir_block_get_switch_values` / `mir_block_get_switch_targets` | Pre-`54eb4965` | ✅ Full impl at `mir.qz:1479-1511` |
| `cg_emit_struct_hash_eq_functions` / `cg_emit_custom_map_functions` | Pre-`54eb4965` | ✅ Full impls in `codegen_runtime.qz:6351/6499` |

Source-only build verified: gen1 (1,679,869 lines IR) == gen2 byte-identical.
The standing patch set has been **retired** — no patches are required for a clean
source-only build from HEAD.

Each fossil originally cost **hours** of bootstrap walking to identify and patch around.
The resolution ensures this class of problem cannot recur undetected.

## The Guard — invariant to maintain

> **For every commit on `trunk`, compiling `self-hosted/quartz.qz` *from source* using
> the previous commit's binary (plus any required source-level patches that are
> intentional forward steps) must succeed.**

The "plus patches" escape hatch is for legitimate cases where a commit introduces new
syntax or builtins — the patch set at that commit would be the minimal diff a user
would apply to cross-compile the feature. The important property: **no dangling
references to definitions that don't exist anywhere in the source tree**.

## Transactional Local Guard

### Trust model

The local `.fixpoint` stamp is structured consistency and provenance evidence.
It is not a signature and is not an unforgeable attestation: anyone able to edit
candidate source can also edit a candidate checker, binary, and stamp. Local
guard/check/hook paths catch mistakes and corruption but do not establish trust
against a malicious candidate tree.

Local pre-commit execution therefore materializes `tools/quartz_guard.rb` from
trusted `HEAD`, never from the staged candidate. The trusted checker also uses
the `HEAD` input policy; staged checker/policy edits are hashed as candidate
inputs but cannot redefine their own validation boundary. Checker changes must
pass the old checker's protocol and independent base-checker reproduction.

The independent authority is `quartz_guard.rb reproduce REF|index`. CI executes
the checker from the protected base commit, pins its SHA-256, supplies the
protected base compiler artifact and expected SHA-256, materializes candidate
blobs with the base policy, rebuilds through fixpoint, and compares candidate
source identity and stable IR. It also requires the submitted binary to match
the submitted stamp and either byte-reproduce or independently emit the stamped
stable IR. A forged binary/stamp or no-op staged checker therefore cannot pass.

Checker, supervisor, policy interpreter/schema/meta-policy, tracked hook, and
protected workflow protocol are immutable trust components by default. The base
policy names them with exact path/mode/kind records. Authoritative reproduction
rejects any candidate hash change to an immutable component. Candidate files,
stamp fields, transition files, repository variables, and candidate workflow
environment cannot authorize a successor.

The current implementation is `tools/quartz_guard.rb`, called through Quake.
In the implemented protocol, `guard` aliases `guard:staged`:

```bash
./self-hosted/bin/quake guard:worktree # tracked worktree development snapshot
./self-hosted/bin/quake guard:staged   # exact Git index snapshot for a commit
./self-hosted/bin/quake guard          # alias for guard:staged
```

Neither mode runs `git add`. Staged mode parses stage-zero index entries, checks
their exact modes, reads blobs with `git cat-file`, and creates regular snapshot
files without checkout or symlink traversal. Symlinks, gitlinks, nonregular
entries, unmerged entries, and a compiler binary not staged as `100755` fail.
Worktree mode uses the same checked inventory and rejects symlinks and mode drift.

`tools/quartz_guard_inputs.json` is the checked input policy. It includes every
tracked `.qz` file under `self-hosted/` and `std/`, plus exact Quake, checker,
supervisor, hook, CI, smoke, and protocol files. Its inventory SHA commits the
exact path/mode set. Candidate additions/deletions require
`tools/quartz_guard_policy_transition.json`: the old/base policy constrains
allowed roots, suffixes, and modes, forbids deletion of trust machinery, validates
the candidate inventory, and emits transition evidence without executing the
candidate policy. Unapproved additions, removals, and mode drift fail closed. Import
syntax, including `from X import Y`, cannot evade provenance selection because
selection does not depend on regex import discovery; unknown imports fail in the
trusted seed's supervised canonical compile. The framed manifest records each
selected path, mode, and SHA-256 plus flags, host target, seed provenance, cache
schema, and resolved Ruby/LLVM/linker identities.

The installed seed is accepted only through a complete current artifact pointer
or a committed structured stamp whose HEAD binary and independently rebuilt HEAD
manifest agree. Migration from the legacy stamp requires an explicit executable,
read-only recovery seed that is not the live compiler, plus its expected SHA-256.

The repository lock uses nonblocking OS `flock`; PID/run metadata is diagnostic
only and stale metadata cannot block a run. Every subprocess is executed through
the B2 QSP2/QSS2 supervisor from trusted HEAD/base or an independently pinned
external path, never the candidate snapshot, with a stage deadline, process-group
TERM/KILL/reap, structured outcome, and orphan rejection.

Validation is ordered and fail-closed: canonical IR verification, candidate
construction, two-generation byte-exact IR fixpoint, debug-IR verification,
brainfuck/expr_eval/style_demo compile-link-run smokes, cache-RO smoke, then warm
dependency-invalidation smoke. This B4 implementation intentionally does not
add adaptive generations or successful-result/cache reuse; those remain B8.

Only after every gate passes does guard fsync a versioned directory containing
the candidate, stamp, exact manifest, and stable IR, then atomically renames one
pointer. Compatibility copies at `self-hosted/bin/quartz` and `.fixpoint` are
derived from that pointer. Startup repairs an interrupted mirror update;
`guard:check` detects it without silently accepting mixed bytes, and
`guard:recover` repairs it. The Git index is never modified.

The stamp records mode, complete input-manifest SHA-256, candidate and seed
SHA-256, stable IR SHA-256, target, flags, toolchain identities, validation set,
seed provenance, policy-transition evidence, claim scope, and timestamp. Local
checks establish consistency only. Authoritative reproduction independently
compares source/input manifests, seed SHA, host target, flags, full toolchain,
environment, command plan, stable IR, and submitted compiler behavior. The
submitted seed provenance location, timestamp, and linked binary byte identity
remain explicitly consistency-only claims. The tracked hook materializes and
executes the trusted HEAD checker, never the staged checker. `guard:status`
reports staged and worktree consistency expectations.

Protocol fixtures run without a compiler:

```bash
./self-hosted/bin/quake guard:protocol_test
```

They cover every failure stage, `from` imports, direct index isolation, partial
staging, symlink/gitlink/mode rejection, seed and stamp corruption, live/stale
locks, target relabeling, pointer-crash recovery, clean-clone CI checking,
process-tree timeout/reaping, candidate-supervisor bypass attempts, legacy pinned
bootstrap reproduction, provenance tampering, policy transitions, forged local
evidence, and index immutability.

Every run also records normalized full argv, cwd, deadline, redirections, and
per-command environment. Toolchain evidence includes executable argv/path/hash/
version for Ruby, the compiler seed, `opt`, `llc`, linker, `bash`, and `file`,
plus SDK/sysroot and queried libc/libm/libpthread/mimalloc identities. Guard does
not accept a target override: compiler, LLVM lowering, linker, and architecture
verification all describe the actual host lane.

Only the current artifact and one verified predecessor are retained. The atomic
pointer names both. Startup/recovery removes abandoned run roots and repairs
compatibility mirrors after an interrupted or SIGKILL-tested pointer switch.

### Bootstrap migration from legacy HEAD

Current HEAD predates the trusted checker and structured stamp. The first landing
cannot pretend HEAD is its trust anchor. The owner must:

1. Place an independently reviewed checker, policy, and supervisor at read-only
   immutable paths and record all three SHA-256 values.
2. Place a known recovery compiler at a separate executable read-only path and
   record its SHA-256. The live compiler path is rejected as recovery authority.
3. Stage the intended tooling/source tree, then invoke the immutable checker with
   `QUARTZ_GUARD_BOOTSTRAP_CHECKER_SHA256`,
   `QUARTZ_GUARD_BOOTSTRAP_POLICY_SHA256`, `QUARTZ_GUARD_BOOTSTRAP_SUPERVISOR`,
   `QUARTZ_GUARD_BOOTSTRAP_SUPERVISOR_SHA256`, `QUARTZ_GUARD_RECOVERY_SEED`, and
   `QUARTZ_GUARD_RECOVERY_SEED_SHA256` set.
4. After successful attended validation, separately stage the generated binary
   and stamp. The hook requires the same pinned bootstrap checker variables; it
   does not bypass validation when HEAD lacks a checker.
5. Run `reproduce-bootstrap` from the immutable checker with independently pinned
   `QUARTZ_GUARD_LEGACY_{CHECKER,POLICY,SUPERVISOR,BASE_SEED}` paths and matching
   `_SHA256` values, plus a pinned external `QUARTZ_GUARD_LEGACY_TRUST_SET` and
   its SHA. The trust set must name the exact initial hash/mode for every immutable
   component and the complete initial policy SHA. This mode does not require
   those files in legacy HEAD and fails unless every pin matches.
6. Require that reproduction from the externally pinned workflow before landing
   the bootstrap commit. After landing, normal commits use checker, policy,
   supervisor, and seed provenance from protected HEAD/base.

### External CI trust anchor

`.github/workflows/ci.yml` runs local consistency, protocol fixtures, and
base-checker reproduction as defense in depth. It is candidate-controlled and
cannot by itself be the trust anchor. GitHub branch protection must require a
check from a pinned reusable workflow in a separately protected repository (or
an equivalent external CI service), referenced by immutable commit SHA and given
the protected base artifact. No external workflow reference is configured in
this repository, so CI fails unless the owner sets
`QUARTZ_GUARD_EXTERNAL_REQUIRED_CHECK=configured` after installing that required
check. The variable is only a setup gate; branch protection is the authority.

### External trust rotation

Trust takeover is a protected two-commit operation, not an ordinary policy
transition. Before proposing the first commit, the owner creates a read-only
approval JSON outside the candidate repository and pins that file by SHA-256 in
the separately protected reproduction service:

```json
{
  "schema": 1,
  "base_policy_sha256": "<protected-base-policy-sha256>",
  "next_policy_sha256": "<full-successor-policy-sha256-or-null>",
  "components": [
    { "path": "tools/quartz_guard.rb", "mode": "100755", "sha256": "<approved-next-sha256>" }
  ]
}
```

The protected service supplies the external path and pin through
`QUARTZ_GUARD_TRUST_ROTATION` and `QUARTZ_GUARD_TRUST_ROTATION_SHA256`.
Reproduction first verifies the approval file is regular, read-only, outside the
candidate repository, and matches its pin. It then requires exact hashes for
every changed immutable component. Any change to policy schema, transition path/
authority, protected paths, roots, modes, files, or trust-component list requires
`next_policy_sha256` to equal the complete candidate policy hash. Constrained
inventory-only add/delete transitions do not require whole-policy approval.

After the approved first commit lands, the successor becomes protected base for
the second commit and normal base-controlled validation resumes. Branch
protection and external workflow configuration remain owner responsibilities;
the repository cannot prove that those settings exist or authorize itself.

## Historical Three-Phase Proposal

### Phase 1 — pre-commit local check (fast, per-commit)

Before committing, run:

```bash
./self-hosted/bin/quake guard:local
```

This task (to be added to `Quakefile.qz`) runs:

1. `git stash` the working tree
2. `git checkout HEAD~1 -- self-hosted/bin/quartz self-hosted/bin/quake`
   (use the previous commit's binary)
3. `git stash pop`
4. Run `./self-hosted/bin/quake build` (the previous binary compiling the current source)
5. If it fails, report which symbols couldn't be resolved and abort the commit

Budget: ~30 seconds (debug build). Acceptable as a pre-commit hook for the ~20 commits
per day on active feature work. For commits that intentionally introduce a new feature
with a chicken-and-egg gap, the developer adds a `guard-patch:` line to the commit trailer
pointing at a `.quartz-guard/NNN-patch.sh` script that the guard runs before the build.

### Phase 2 — CI forward-rebuild (slow, per-PR)

On every PR, run `guard:forward`:

1. Check out the merge base with `trunk`
2. Use that commit's committed binary as gen0
3. For each commit in the PR, in order:
   - Apply any `.quartz-guard/NNN-patch.sh` scripts present in the diff
   - Build from source using the previous gen binary
   - Run `quake fixpoint` on the last commit
4. Report the first commit (if any) where source-only build fails

Budget: 5-15 minutes depending on PR size. GitHub Actions, triggered on push to any
PR branch.

### Phase 3 — CI historical sweep (weekly, full history)

Weekly job that walks the last 30 days of commits on `trunk` source-only, starting from
a known-good binary 30 days back. Catches fossils that made it past both Phase 1 and
Phase 2 (e.g., cross-commit interactions where two separately-valid commits combine
into a fossil). On failure, the CI opens an issue on GitHub with the commit range and
the missing symbol.

Budget: ~2 hours per run. Once a week on Sunday night.

## The "Guard" binary — bootstrap-quality compiler

A second committed binary at `self-hosted/bin/quartz-guard` that is specifically
built and maintained to be **fixpoint-stable from the minimal fossil-free source
tree**. Its job is *only* to serve as the gen0 for source-only rebuilds. It doesn't
need to be fast, doesn't need mimalloc, doesn't need the latest optimizations — it
just needs to faithfully compile the source.

Whenever a fossil is introduced and then resolved, the guard binary is rebuilt from
the post-resolution commit so Phase 2 has a clean starting point moving forward.

## Patch-set protocol for intentional chicken-and-egg commits

When a commit introduces a feature where the new source can't build with the previous
binary (e.g., `97d088ce` introduced `map_new` registration AND the intrinsic registry
initializer using `map_new()` at the same time), the commit author provides a
`.quartz-guard/<commit-hash>-patch.sh` script that:

1. Mutates the new source just enough to make it buildable with the previous binary
2. Documents why (what compiled-in state the patch is substituting for)
3. The Phase 2 CI applies the patch, builds, and the resulting binary is what's used
   for the NEXT commit in the sequence

The patch file is committed alongside the code change. Once a second commit lands that
moves past the chicken-and-egg, the patch file can be deleted.

## Known patch set — RETIRED (Apr 12, 2026)

All permanent fossils have been resolved in source. The standing patch set is no longer
needed. For historical reference, the patches that were required before resolution:

- ~~`standing/01-strip-cconv-c.sh`~~ — `ast_func_is_cconv_c` now has a stub definition
- ~~`standing/02-type-map-const.sh`~~ — `TYPE_MAP` now defined in `type_constants.qz`
- ~~`standing/03-node-is-check-const.sh`~~ — `NODE_IS_CHECK` now defined in `node_constants.qz`
- ~~`standing/04-hashable-stub.sh`~~ — `tc_type_is_hashable` and friends now have full implementations
- ~~`standing/05-tc-all-builtin-names.sh`~~ — no longer referenced as a fossil

The source tree is now source-only-buildable by any prior binary without patches.

## Relationship to the Binary Backup Protocol

The existing Binary Backup Protocol (CLAUDE.md) protects against *broken builds* destroying
the committed binary. The Quartz Guard protects against *fossils* making the source tree
unbootstrappable even when the committed binary is fine. They're orthogonal:

- **Binary Backup Protocol:** "NEVER overwrite `quartz-golden` until fixpoint is verified"
- **Quartz Guard:** "NEVER let source reference a symbol that doesn't exist in source"

Both must hold simultaneously for the language to remain in a state where any developer
can cross-compile from scratch without a pre-existing binary.

## Golden binary backups from the Linux bootstrap walk

`self-hosted/bin/backups/` contains the checkpoint binaries from the Linux bootstrap
walk that rediscovered these fossils. Each is a Linux x86_64 ELF, fixpoint-verified
at its commit:

```
quartz-linux-x64-<commit>-golden   # the compiler
quake-linux-x64-<commit>-golden    # the build tool
```

Walk order (forward in time):

```
bce5e646 → bbded285 → 27b133a1 → ac0ef57c → d12ea4b6 → 780a0079
          → 015b0305 → 32fa81b3 → 97d088ce → aef2610b → 0c73a2fc
          → 54eb4965 → afad28c0 → 7ba5fa12 (HEAD)
```

Any of these can serve as the gen0 for a future Linux bootstrap without mimalloc and
without the cache-pattern codegen bug described in HANDOFF_LINUX_BOOTSTRAP.md.

## Future work

- ~~**Fix permanent fossils in source**~~ — ✅ DONE (Apr 12, 2026). All 11 fossils resolved.
- ~~**Add `quake guard:source`** to `Quakefile.qz`~~ — ✅ DONE. Automated clean-room
  source-only build + fixpoint verification + 3 smoke tests (brainfuck, expr_eval, style_demo).
- **Add `quake guard:forward`** (per-PR CI) and **`quake guard:history`** (weekly sweep)
- **Enable Phase 1 as a pre-commit hook** via `.claude/settings.json` hooks
- **Enable Phase 2 in GitHub Actions** via `.github/workflows/quartz-guard.yml`
- **Fix the `as_int(string)` / `as_string(int)` round-trip codegen defect** that caused
  the final Linux bootstrap blocker — this is a real runtime bug, not a source fossil
