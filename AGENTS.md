# Quartz public research edition

This is a retired research project, not an active feature programme. Preserve source and evidence; do not invent release readiness or a stabilization roadmap. Read README.md, STATUS.md and docs/PUBLIC_EDITION.md first. docs/QUARTZ_REFERENCE.md is the detailed language reference; historical target semantics are not proof of implementation.

The compiler is application-owned Quartz source with LLVM as authoritative backend. Known miscompilations, unsafe memory paths and a red validation baseline remain. This edition includes unfinished test/stdlib tooling; inclusion is not acceptance. Do not describe its cryptography as suitable for real secrets.

This publication snapshot did not modify self-hosted compiler source. Before any future compiler-source change, preserve a golden executable, restore a trusted guard protocol, and verify non-self programs as well as fixpoint. Do not use the retired C bootstrap as a normal build path. No heavy QSpec/full self-build runs without owner direction.

Keep deployment configuration, secrets, local caches and private session history out of this repository. Preserve third-party notices. Do not restore excluded ROMs or the hyper bouba port without redistribution permission.
