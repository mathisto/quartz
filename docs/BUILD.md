# Building the public research edition

The retained seed compiler and Quake executables are arm64 macOS Mach-O files. They are existing project artifacts, not a compiler rebuilt from this public snapshot. A clean-source bootstrap has not been established for the public edition. No Windows or Linux binary is promised.

For a small native program, install LLVM and use the exact commands in the README. They were exercised on Apple Silicon with examples/workshop.qz and examples/hello.qz. examples/brainfuck.qz also compiled and ran its smoke cases (with compiler warnings). The older examples/simd_dot_product.qz fails with undefined legacy f32_vec_new/push intrinsics; it is retained as research history, not a passing demo.

No self-build, fixpoint or full QSpec run was performed for this edition. The original dated status remains red. The formatter is unshipped; aggregate test tasks may fail closed through format_check. Read docs/development-status.md, STATUS.md and docs/QUARTZ_GUARD.md before deeper toolchain work. The unbanked guard migration is not established just by shipping its files.

The C bootstrap was retired in February 2026. Old documents referring to a sibling bootstrap checkout are historical, not a reproducible public build recipe.
