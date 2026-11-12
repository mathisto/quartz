/* Linker script for QEMU x86_64 bare metal with Multiboot2 boot protocol.
 *
 * Layout:
 *   - Base load address 1 MiB (0x100000). Multiboot2 requires the image
 *     load address to be >= 1 MiB so it doesn't collide with real-mode
 *     IVT / BIOS data area / VGA memory.
 *   - `.multiboot` MUST appear within the first 32 KiB of the image per
 *     the Multiboot2 specification — we place it first in the script.
 *   - Kernel starts in 32-bit protected mode (GRUB / QEMU -kernel
 *     hands control to _start with 32-bit segmented mode active). Any
 *     transition to long mode is the kernel's responsibility — not this
 *     smoke's, which just halts.
 *
 * Stack: 64 KiB at end of image. _stack_top is consumed by _start.
 */
ENTRY(_start)

SECTIONS {
  . = 0x100000;

  .multiboot : ALIGN(8) {
    KEEP(*(.multiboot))
  }

  .text : ALIGN(16) {
    *(.text*)
  }

  .rodata : ALIGN(16) {
    *(.rodata*)
  }

  .data : ALIGN(16) {
    *(.data*)
  }

  .bss : ALIGN(16) {
    *(.bss*)
    *(COMMON)
  }

  . = ALIGN(16);
  _stack_bottom = .;
  . = . + 0x10000;
  _stack_top = .;
}
