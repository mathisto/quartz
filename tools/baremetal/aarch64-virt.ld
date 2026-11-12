/* Linker script for QEMU aarch64-virt bare metal
 * Load address: 0x40000000 (QEMU virt default for -kernel)
 * Stack: 64KB at end of image
 */
ENTRY(_start)

SECTIONS {
  . = 0x40000000;

  .text : {
    *(.text*)
  }

  .rodata : {
    *(.rodata*)
  }

  .data : {
    *(.data*)
  }

  .bss : {
    *(.bss*)
    *(COMMON)
  }

  . = ALIGN(16);
  _stack_bottom = .;
  . = . + 0x10000;
  _stack_top = .;
}
