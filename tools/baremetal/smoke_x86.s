// Minimal x86_64 bare-metal smoke target for the Quake linker-script
// passthrough. Mirror of tools/baremetal/smoke.s (aarch64) but with the
// additions required for the x86 world:
//
//   1. Multiboot2 header so a Multiboot-compliant loader (GRUB, QEMU
//      -kernel) can identify this as a kernel image. The header must
//      live in the first 32 KiB of the file; the linker script pins
//      `.multiboot` to the front of the image.
//   2. 32-bit _start — Multiboot entry runs in protected-mode 32-bit.
//      A real kernel would transition to long mode (set up PML4, enable
//      PAE + LME + PG, far-jump to 64-bit code). That is KERN.1 work.
//      For the smoke we just halt the CPU and spin — same shape as
//      aarch64 smoke.s's wfe-loop.
//
// Does not reference libc, does not need the Quartz prelude, does not
// need the Quartz compiler — only an assembler and a linker. Its only
// job is to produce a valid ELF so we can verify that the Quake
// primitives `assemble` + `link_baremetal` plumb the linker script and
// Multiboot2 header through correctly.

// ---- Multiboot2 header -----------------------------------------------
// Per the Multiboot2 specification, the header is:
//   magic:         0xe85250d6
//   architecture:  0 = i386 (protected mode)
//   header_length: total byte length including end tag
//   checksum:      uint32(-(magic + architecture + header_length))
//   tags...        (we emit only the terminator tag)
//
// Minimal header = 16-byte fixed prefix + 8-byte end tag = 24 bytes.

.section .multiboot, "a"
.align 8

multiboot_start:
    .long 0xe85250d6                              // magic
    .long 0                                        // architecture: i386
    .long multiboot_end - multiboot_start          // header_length
    // checksum = -(magic + arch + length), computed as a uint32
    .long -(0xe85250d6 + 0 + (multiboot_end - multiboot_start))

    // End tag: type=0, flags=0, size=8
    .short 0
    .short 0
    .long 8
multiboot_end:

// ---- Entry -----------------------------------------------------------
// Runs in 32-bit protected mode. Multiboot hands control to _start with:
//   EAX = 0x36d76289 (Multiboot2 magic response, not checked here)
//   EBX = physical address of Multiboot2 information struct
//
// Smoke behavior: load esp from linker-script-defined _stack_top, then
// halt. The `cli; hlt; 1: jmp 1b` sequence is idiomatic x86 "stop and
// stay stopped" — cli masks maskable interrupts, hlt halts the CPU
// until a non-maskable interrupt fires, and the jmp loop re-halts if
// such an interrupt ever wakes us.

.section .text
.code32
.global _start
.type _start, @function
_start:
    mov $_stack_top, %esp
    cli
1:  hlt
    jmp 1b
.size _start, . - _start
