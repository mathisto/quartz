// AP startup trampoline. Real-mode → protected-mode → long-mode.
//
// At runtime the bytes between `ap_trampoline_start` and
// `ap_trampoline_end` are memcpy'd to physical address 0x8000 by the
// BSP-side bringup orchestrator. The SIPI vector field is set to 8,
// so APs wake with CS:IP = 0x800:0 (linear 0x8000) in 16-bit real
// mode and start executing this code.
//
// Why 0x8000: SIPI vector V → entry at V * 0x1000. The page must live
// below 1 MiB and be 4 KiB-aligned. 0x8000 is the OSDev convention
// (xv6 uses 0x7000; both are fine — we just need an address in low
// memory we don't otherwise touch).
//
// All internal cross-references use the literal runtime base 0x8000.
// This keeps the blob fully position-dependent: it ONLY runs at
// 0x8000. Trying to copy it elsewhere will fault on the first
// inter-stage far jump.
//
// BSP-populated slots (offsets from the start symbol):
//   ap_trampoline_pml4_slot   — PML4 physical base (typically the BSP's CR3)
//   ap_trampoline_stack_slot  — RSP for the AP after long-mode entry
//   ap_trampoline_main_slot   — function pointer the AP calls (Quartz `ap_main`)
//
// The blob also embeds its own 5-entry GDT (null, 32-bit code/data,
// 64-bit code/data) plus a 16/32-bit-mode GDT pointer. We don't reuse
// BSP's GDT because `lgdt` in real mode wants a 16-bit-DS-addressable
// operand — keeping the GDT inside the trampoline page satisfies
// that without a separate low-memory allocation.
//
// Refs: Intel SDM Vol. 3 Ch. 8 (multiprocessor init), Ch. 10 (APIC),
// xv6 `entryother.S`, OSDev wiki "SMP" + "Symmetric Multiprocessing".
// Locked-in design decisions in `docs/design/KERN_8_SMP.md` D2 + D3.

.section .data.ap_trampoline_blob, "a"
.align 4096
.global ap_trampoline_start
ap_trampoline_start:

// ---------- 16-bit real-mode entry ------------------------------------
// AP wakes with: CS=0x800, IP=0, DS/ES/SS undefined, IF=0 (SIPI clears
// it on transition). We zero the data segments, load our GDT, set
// CR0.PE, then far-jump into 32-bit code.

.code16
ap_real_mode_entry:
    cli
    cld
    xorw  %ax, %ax
    movw  %ax, %ds
    movw  %ax, %es
    movw  %ax, %ss
    movw  %ax, %fs
    movw  %ax, %gs

    // Load the GDT. The GDTR pseudo-descriptor lives later in this
    // page at a fixed offset; we hand `lgdtl` the absolute linear
    // address (DS=0, so a flat 16-bit offset works).
    lgdtl ap_gdtr32_runtime - ap_trampoline_start + 0x8000

    // Enable protected mode (CR0.PE = bit 0).
    movl  %cr0, %eax
    orl   $1, %eax
    movl  %eax, %cr0

    // Far jump to the 32-bit code segment (selector 0x18). The far
    // jump must use an absolute 32-bit linear target — encoded as a
    // literal because the trampoline is hard-pinned at 0x8000.
    //
    // K8.MVP: 32-bit code lives at GDT[3] (selector 0x18), not GDT[1],
    // because BSP's IDT entries reference selector 0x08 for 64-bit
    // code — once interrupts fire on the AP after long-mode entry,
    // CS=0x08 must resolve to a 64-bit code descriptor, otherwise the
    // CPU drops into compat mode and immediately #GP's.
    .byte 0x66                  // operand-size prefix → 32-bit imm
    .byte 0xEA                  // ljmp ptr16:32
    .long ap_protected_entry - ap_trampoline_start + 0x8000
    .word 0x18                  // CS = 32-bit code segment (now at GDT[3])

// ---------- 32-bit protected-mode stage ------------------------------
// Reload data selectors, set up paging (PAE + CR3 + EFER.LME + CR0.PG),
// then far-jump to 64-bit code.

.code32
ap_protected_entry:
    movw  $0x20, %ax            // 32-bit data selector (now at GDT[4])
    movw  %ax, %ds
    movw  %ax, %es
    movw  %ax, %ss
    movw  %ax, %fs
    movw  %ax, %gs

    // Enable PAE (CR4.PAE = bit 5). Required for long mode.
    movl  %cr4, %eax
    orl   $0x20, %eax
    movl  %eax, %cr4

    // Load PML4 base from BSP-populated slot. Slot is 8 bytes; the
    // PML4 physical address fits in 32 bits (BSP's PML4 lives in
    // .bss < 4 GiB), so a 32-bit load is sufficient.
    movl  (ap_trampoline_pml4_slot - ap_trampoline_start + 0x8000), %eax
    movl  %eax, %cr3

    // Enable EFER.LME (long-mode enable, bit 8). MSR 0xC0000080.
    movl  $0xC0000080, %ecx
    rdmsr
    orl   $0x100, %eax
    wrmsr

    // Enable paging (CR0.PG = bit 31). Long mode is now active in
    // compatibility mode; the next far-jump promotes us to 64-bit.
    movl  %cr0, %eax
    orl   $0x80000000, %eax
    movl  %eax, %cr0

    // Far jump to 64-bit code segment (selector 0x08). The GDT we
    // loaded in 16-bit mode has the 64-bit code descriptor at slot 1
    // (selector 0x08) — must match BSP's selector layout so IDT
    // dispatch on the AP loads a valid 64-bit CS once interrupts fire.
    .byte 0xEA                  // ljmp ptr16:32 (still 32-bit operand)
    .long ap_long_mode_entry - ap_trampoline_start + 0x8000
    .word 0x08                  // CS = 64-bit code segment (now at GDT[1])

// ---------- 64-bit long-mode stage ------------------------------------
// We're now in true 64-bit mode. Reload data segs to the 64-bit data
// selector, read our LAPIC ID from the local APIC MMIO window (which
// the BSP's PML4 already identity-maps), set up the per-CPU stack,
// and call into Quartz `ap_main(apic_id)`.

.code64
ap_long_mode_entry:
    movw  $0x10, %ax            // 64-bit data selector (now at GDT[2])
    movw  %ax, %ds
    movw  %ax, %es
    movw  %ax, %ss
    movw  %ax, %fs
    movw  %ax, %gs

    // Read LAPIC ID from the APIC MMIO window at 0xFEE00020. Bits
    // 24..31 carry the 8-bit xAPIC ID. We pass this to ap_main as
    // arg 1 (RDI per SysV).
    movq  $0xFEE00020, %rax
    movl  (%rax), %eax
    shrl  $24, %eax
    movl  %eax, %edi            // edi = APIC ID (zero-extends to rdi)

    // Load AP stack from BSP-populated slot. RSP points to the top
    // of a per-CPU page minus 8 (for first-push alignment).
    movabsq $(ap_trampoline_stack_slot - ap_trampoline_start + 0x8000), %rax
    movq  (%rax), %rsp

    // Indirect call into Quartz ap_main(apic_id).
    movabsq $(ap_trampoline_main_slot - ap_trampoline_start + 0x8000), %rax
    movq  (%rax), %rax
    callq *%rax

    // Defensive halt — ap_main should never return.
    cli
1:  hlt
    jmp 1b

// ---------- GDT for the trampoline -----------------------------------
// 5 entries, 40 bytes. Layout matches BSP's selector layout for the
// 64-bit code/data descriptors so IDT dispatch works identically on
// BSP and AP:
//   0x00  null
//   0x08  64-bit code (DPL=0, R/X, L=1)        -- matches BSP gdt64_code
//   0x10  64-bit data (DPL=0, R/W)             -- matches BSP gdt64_data
//   0x18  32-bit code (DPL=0, R/X)             -- trampoline-only
//   0x20  32-bit data (DPL=0, R/W)             -- trampoline-only

.align 8
ap_gdt_runtime:
    .quad 0                                 // null
    .quad 0x00AF9A000000FFFF                // 64-bit code (L=1) — selector 0x08
    .quad 0x00CF92000000FFFF                // 64-bit data        — selector 0x10
    .quad 0x00CF9A000000FFFF                // 32-bit code        — selector 0x18 (trampoline-only)
    .quad 0x00CF92000000FFFF                // 32-bit data        — selector 0x20 (trampoline-only)
ap_gdt_runtime_end:

// 16/32-bit-mode pseudo descriptor (6 bytes: word limit + dword base).
// `lgdtl` in 16-bit mode reads this and installs a 32-bit-base GDTR.
.align 8
ap_gdtr32_runtime:
    .word (ap_gdt_runtime_end - ap_gdt_runtime - 1)
    .long ap_gdt_runtime - ap_trampoline_start + 0x8000

// ---------- BSP-populated slots --------------------------------------
// These are zeroed in the link-time blob; BSP fills them in just
// before issuing INIT-SIPI-SIPI.

.align 8
.global ap_trampoline_pml4_slot
ap_trampoline_pml4_slot:    .quad 0
.global ap_trampoline_stack_slot
ap_trampoline_stack_slot:   .quad 0
.global ap_trampoline_main_slot
ap_trampoline_main_slot:    .quad 0

.global ap_trampoline_end
ap_trampoline_end:

// ---------- Helpers exposed to Quartz --------------------------------
// Quartz can't take the address of a `.global` symbol declared in an
// asm file directly — it can only call them via `extern "C"`. So we
// wrap each address-of we need with a `lea`-and-return shim and
// expose the shim as a callable function.
//
// All return values are RIP-relative `lea`s into the kernel image —
// these resolve to the kernel-image link-time addresses, NOT the
// runtime trampoline copy at 0x8000. BSP uses these to memcpy the
// blob INTO 0x8000, then writes BSP-populated slots at runtime
// addresses (0x8000 + offset).

.section .text.ap_trampoline_helpers, "ax"

.global get_ap_trampoline_blob
.type get_ap_trampoline_blob, @function
get_ap_trampoline_blob:
    leaq ap_trampoline_start(%rip), %rax
    retq
.size get_ap_trampoline_blob, . - get_ap_trampoline_blob

.global get_ap_trampoline_size
.type get_ap_trampoline_size, @function
get_ap_trampoline_size:
    leaq ap_trampoline_end(%rip), %rax
    leaq ap_trampoline_start(%rip), %rcx
    subq %rcx, %rax
    retq
.size get_ap_trampoline_size, . - get_ap_trampoline_size

.global get_ap_pml4_slot_offset
.type get_ap_pml4_slot_offset, @function
get_ap_pml4_slot_offset:
    leaq ap_trampoline_pml4_slot(%rip), %rax
    leaq ap_trampoline_start(%rip), %rcx
    subq %rcx, %rax
    retq
.size get_ap_pml4_slot_offset, . - get_ap_pml4_slot_offset

.global get_ap_stack_slot_offset
.type get_ap_stack_slot_offset, @function
get_ap_stack_slot_offset:
    leaq ap_trampoline_stack_slot(%rip), %rax
    leaq ap_trampoline_start(%rip), %rcx
    subq %rcx, %rax
    retq
.size get_ap_stack_slot_offset, . - get_ap_stack_slot_offset

.global get_ap_main_slot_offset
.type get_ap_main_slot_offset, @function
get_ap_main_slot_offset:
    leaq ap_trampoline_main_slot(%rip), %rax
    leaq ap_trampoline_start(%rip), %rcx
    subq %rcx, %rax
    retq
.size get_ap_main_slot_offset, . - get_ap_main_slot_offset

// Read CR3 (used by BSP to discover its own PML4 base for the AP slot).
.global read_cr3
.type read_cr3, @function
read_cr3:
    movq %cr3, %rax
    retq
.size read_cr3, . - read_cr3
