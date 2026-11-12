# Quartz

A self-hosted systems-language experiment that grew much bigger than I intended.

[The story](docs/PROJECT_STORY.md) ? [Language reference](docs/QUARTZ_REFERENCE.md) ? [Architecture](docs/ARCHITECTURE.md) ? [Known limits](STATUS.md)

```quartz
def fizzbuzz(n: Int): String when n % 15 == 0 = "FizzBuzz"
def fizzbuzz(n: Int): String when n % 3 == 0 = "Fizz"
def fizzbuzz(n: Int): String when n % 5 == 0 = "Buzz"
def fizzbuzz(n: Int): String = n.to_s()
```

I wanted to understand the decisions hiding underneath a programming language: borrowing, memory layouts, SIMD, concurrency, and the machinery that turns source into something a CPU can run. So I built one, with a lot of help from large language models.

This was one of my first attempts to see how far that assistance could take me. I let it go too far. Quartz became sprawling, difficult to keep coherent, and much harder to stabilize than to expand. I learned an enormous amount, and I had a ridiculous amount of fun.

The compiler is written in Quartz and emits LLVM IR. The same language also grew its own build tool, test framework, standard library, CHIP-8 emulator, and experiments in networking and cryptography. Self-hosting is a real milestone; it is not proof that the compiler is correct.

**Retired research project.** I am preserving it for reading and experimentation, not promising a roadmap or production support. Known miscompilations and memory-safety defects remain. The cryptography is experimental and unaudited. See [status](STATUS.md) before running unfamiliar programs.

## Try a small program

The retained bootstrap executables require Apple Silicon macOS. Install LLVM (`brew install llvm`), then from this checkout:

```sh
self-hosted/bin/quartz examples/workshop.qz > /tmp/workshop.ll
"$(brew --prefix llvm)/bin/llc" /tmp/workshop.ll -filetype=obj -o /tmp/workshop.o
clang /tmp/workshop.o -o /tmp/workshop -lm -lpthread
/tmp/workshop
```

That example was compiled, linked and run for this edition. It does not establish a clean-source bootstrap on other platforms or a green full test suite. [Build notes](docs/BUILD.md) explain the boundary.

[Public-edition notes](docs/PUBLIC_EDITION.md) ? [Third-party notices](THIRD_PARTY_NOTICES.md) ? [MIT license](LICENSE)

Made by [Matt Kelly](https://mattkelly.io/).
