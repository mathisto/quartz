// Multiboot2 header + PVH ELF note for Quartz x86_64 freestanding ELFs.
//
// Two boot paths are supported by this object:
//
//   1. GRUB / any Multiboot2-capable loader → picks up the Multiboot2
//      header in `.multiboot`.
//   2. qemu-system-x86_64 `-kernel` → picks up the PVH ELF note in
//      `.note.Xen` and boots the ELFCLASS64 image directly.
//
// Note: we do NOT ship a Multiboot1 header. QEMU's `-kernel` loader
// tries MB1 first and rejects ELFCLASS64 with "Cannot load x86-64
// image, give a 32bit one" — even when a valid PVH note exists. Since
// PVH is strictly better for our case (64-bit entry, modern QEMU,
// tested on QEMU 10.2), MB1 is dropped. GRUB uses MB2; anything else
// wanting MB1 can re-add it once we have a 32-bit boot stub.
//
// Quartz's freestanding pipeline can produce x86_64 ELFs
// (`baremetal:verify_hello_x86_64`), but the Quartz source itself
// cannot yet emit `.multiboot` / `.note.Xen` sections — that requires
// `@[section(...)]` support in codegen, which isn't wired today. Until
// then we link this asm-only header object alongside the Quartz-
// compiled output.
//
// This file defines NO `_start` symbol — Quartz source owns the entry
// via `@naked def _start(): Int`.

.section .multiboot, "a"
.align 8

// ---- Multiboot2 header (§3.1.1 of the MB2 spec) ----
//   magic         = 0xe85250d6
//   architecture  = 0 (i386 protected mode)
//   header_length = byte length including end tag
//   checksum      = uint32(-(magic + arch + length))
//   tags...       (only the terminator tag is required)
mb2_start:
    .long 0xe85250d6                               // magic
    .long 0                                         // architecture: i386
    .long mb2_end - mb2_start                       // header_length
    .long -(0xe85250d6 + 0 + (mb2_end - mb2_start)) // checksum

    // End tag: type=0, flags=0, size=8
    .short 0
    .short 0
    .long 8
mb2_end:

// ---- PVH ELF note (Xen HVM direct boot) ----
// QEMU `-kernel` on x86_64 loads ELFCLASS64 images via the PVH entry
// point protocol: an ELF note named "Xen" with type 0x12
// (XEN_ELFNOTE_PHYS32_ENTRY) whose descriptor is a 32-bit physical
// entry address. The note lives in a SHT_NOTE section + segment.
//
// QEMU jumps to that physical entry in 32-bit protected mode (not
// long mode — kernel does its own PML4 / paging setup). Pointing PVH
// at `_start` works for the skeleton because `_start` is 32-bit code
// today; a future KERN.1 trampoline can transition to long mode from
// there.

.section .note.Xen, "a", @note
.align 4
note_start:
    .long 4                         // namesz — "Xen\0" = 4 bytes
    .long note_desc_end - note_desc_start   // descsz
    .long 18                        // type: XEN_ELFNOTE_PHYS32_ENTRY
    .asciz "Xen"                    // name (null-terminated)
.align 4
note_desc_start:
    .long _start                    // physical entry point
note_desc_end:
.align 4
