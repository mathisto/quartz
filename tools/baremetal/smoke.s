// Minimal aarch64 bare-metal smoke target for the Quake linker-script
// passthrough. Does not reference libc, does not need the Quartz prelude,
// does not even need a compiler — just an assembler and a linker. Its
// only job is to produce a valid ELF so we can verify that
// `link_baremetal(...)` plumbed the linker script and entry symbol
// through correctly.
//
// Boots at _start (as declared in aarch64-virt.ld), spins forever.
// Loads the stack pointer from the script-defined _stack_top symbol so
// we also prove symbol resolution across the linker script.

    .section .text
    .global _start
_start:
    ldr x0, =_stack_top
    mov sp, x0
1:  wfe
    b   1b
