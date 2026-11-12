# From Be to Quartz

I wanted to learn what language design decisions actually cost. Borrowing and memory models, vector instructions, concurrency, cryptography: these were things I wanted to understand by building with them, not just reading about them.

Quartz was one of my first experiments in how far I could go with a large language model helping me. The answer turned out to be: much farther than I could comfortably keep under control. I let this one get too big. I do not regret the learning, but I am not pretending that a large language implementation is the same thing as a dependable language.

## The trail in the original history

These are dated commit subjects from the private development history, not newly reconstructed milestones. The public edition starts from a curated snapshot; it does not include that entire history.

| Date | Commit | What changed |
| --- | --- | --- |
| December 27, 2025 | `ad7003b0` | Initialized **Be**, with a C bootstrap and an existential type-system experiment. |
| December 30, 2025 | `1e029bfa` | Began the self-hosted lexer. The language was becoming a tool for implementing itself. |
| January 2, 2026 | `ebae1ffe` | Recorded the first self-hosting fixpoint milestone. |
| January 27, 2026 | `f966c41a` | Renamed Be to **Quartz**, including the `.qz` extension. |
| February 9, 2026 | `d51b0744` | Recorded a stronger byte-identical `gen2 == gen3 == gen4` fixpoint. |
| February 26, 2026 | `3052c017` | Retired the C bootstrap from normal development. |
| April 19, 2026 | `41bc53d1` | Added a CHIP-8 emulator and a test harness in Quartz. |
| July 2026 | see dated `STATUS.md` | Shifted toward stabilization, with a deliberately red correctness baseline. |

By the time I stopped, the language had its own compiler, build tool, test framework, standard library, and enough other experiments to keep finding new corners of systems programming. I was dogfooding a language while making the things needed to dogfood it. That loop was the fun part, and also how the scope got away from me.

## What the source can teach

- [The architecture guide](ARCHITECTURE.md) and [compiler](../self-hosted/) expose the gap between a language rule and enforcing it correctly.
- [The CHIP-8 emulator](../examples/chip8/chip8.qz) is an application written in the language, not just another compiler test. Game ROMs are deliberately not distributed here.
- [The SIMD experiment](../examples/simd_dot_product.qz) records vector work. This particular example is stale against the retained compiler; the build notes record its actual failure.
- [Cryptography experiments](../std/core/crypto/) include primitive implementations and standards-oriented tests. They are unaudited research, not tools for protecting real secrets.
- [Quake](../Quakefile.qz) and [QSpec](../std/qspec.qz) show the project building its own development tools. Unfinished hardening work is preserved, not declared complete.

The achievement is real. So are the defects. This edition keeps both visible.
