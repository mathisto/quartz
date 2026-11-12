// 32 → 64 long-mode trampoline for Quartz x86_64 kernels.
//
// QEMU's PVH loader jumps to `_start` in 32-bit protected mode with
// segments flat, EDI pointing to a `hvm_start_info` struct, and
// paging off. We preserve the start_info pointer (saved into a .bss
// global on entry) and expose it to Quartz so the kernel can walk
// the PVH memory map and discover usable RAM dynamically (SOUL.2).
// LLC-emitted Quartz code is 64-bit — to call it we must transition
// to long mode first.
//
// Steps (standard Rust OS / Blog OS pattern):
//   1. Save the PVH start_info pointer from EDI into pvh_start_info_ptr.
//   2. Load a minimal GDT that defines 64-bit code + data segments.
//   3. Identity-map up to 64 GiB. PDPT[0] uses 2 MiB pages for the
//      first 1 GiB (covers kernel image + .bss + any low-mem MMIO).
//      PDPT[3] uses 2 MiB pages for the 3-4 GiB window (LAPIC at
//      0xFEE00000 + virtio-mmio at 0xFEA00000). PDPT[1], [2], and
//      [4..63] use 1 GiB huge pages (PS=1, requires CPUID
//      0x80000001:EDX bit 26 — present on `-cpu max`, qemu64 since
//      Skylake, and every reasonable host CPU). Total page-table
//      footprint: 4 KiB PML4 + 4 KiB PDPT + 4 KiB PD + 4 KiB pd_apic
//      = 16 KiB to address 64 GiB of RAM.
//   4. Enable PAE (CR4.PAE).
//   5. Load PML4 base into CR3.
//   6. Enable long mode (EFER.LME = 1 via WRMSR 0xC0000080).
//   7. Enable paging (CR0.PG = 1). Now in compatibility mode —
//      instructions still 32-bit, but long mode is on.
//   8. Far-jump to 64-bit code segment. CPU switches to 64-bit mode.
//   9. Reload data segments, set up stack, call qz_main, halt.
//
// Page tables + GDT live in .bss (zeroed at boot — we populate them
// at runtime before enabling paging). Stack lives in .bss too. The
// PMM pool is NO LONGER statically reserved — Quartz's pvh_probe_ram
// routine walks the memmap at boot and calls pmm_set_pool_bounds
// with the largest contiguous Type=1 (System RAM) region above
// the kernel image. This lets the unikernel scale up to whatever
// `-m N` QEMU was launched with, with no source change required
// (SOUL.2, 2026-05-09).
//
// This file defines `_start` (the PVH entry); the Quartz source
// therefore has no `@naked def _start` — Quartz owns `qz_main` and
// everything called from it.

.section .bss
.align 4096
pml4:    .skip 4096
pdpt:    .skip 4096
pd:      .skip 4096
// Page directory for the PDPT[3] slot (3-4 GiB range). Only one entry
// (index 503) is populated at runtime, to identity-map the 2 MiB huge
// page containing the LAPIC MMIO window at 0xFEE00000. The rest of
// the 3-4 GiB range stays unmapped — we don't touch it.
pd_apic: .skip 4096

// IDT: 256 entries × 16 bytes = 4096 bytes. 16-byte aligned to keep
// entries on their natural boundary (though x86 only requires 8).
// Quartz kernel code fills this + loads IDTR; we just reserve the
// space + expose getters (below in .text).
.align 16
.global idt_storage
idt_storage:    .skip 4096

// IDTR pseudo-descriptor: 2-byte limit + 8-byte base = 10 bytes.
// We expose its address so the Quartz side can write limit/base and
// then pass the address to `idt_load` which issues `lidt (%rdi)`.
.global idtr_storage
idtr_storage:   .skip 10

// Physical memory manager pool — runtime-discovered (SOUL.2,
// 2026-05-09). The static 64 MiB `.skip` reservation that was here
// in the pre-SOUL.2 kernel is gone; instead, the Quartz pvh_probe_ram
// routine walks the PVH memmap at boot and writes the discovered
// pool bounds via `pmm_set_pool_bounds`. The bounds live as runtime
// 64-bit globals; the existing `get_pmm_pool_start` /
// `get_pmm_pool_end` shims now dereference these instead of returning
// the address of a static reservation. Naming convention preserved
// (start inclusive, end one-past-last-byte).
.global pmm_pool_start_addr
pmm_pool_start_addr: .quad 0
.global pmm_pool_end_addr
pmm_pool_end_addr:   .quad 0

// Total system RAM detected from the PVH memmap (sum of all Type=1
// regions). Surfaced on the dashboard's "Detected RAM" card.
.global detected_ram_bytes
detected_ram_bytes:  .quad 0

// PVH start_info pointer. The PVH spec
// (https://xenbits.xen.org/docs/unstable/misc/pvh.html) says EBX
// holds the physical address of the hvm_start_info struct on entry;
// the previous trampoline comment incorrectly said EDI. We save
// BOTH EBX and EDI into sibling slots and let the Quartz probe try
// each in turn, picking the one whose magic field matches 0x336EC578.
// Belt-and-suspenders: it costs 2 extra movl + 8 bytes of .bss to
// support either convention silently.
.global pvh_start_info_ptr
pvh_start_info_ptr:      .quad 0
.global pvh_start_info_ptr_alt
pvh_start_info_ptr_alt:  .quad 0

.align 16
stack_bottom:   .skip 16384
stack_top:

.section .rodata
.align 8
gdt64:
    .quad 0                         // null descriptor
gdt64_code:
    // 64-bit code segment: L=1, base=0, limit=ignored in 64-bit.
    // Access byte: P=1, DPL=00, S=1, Type=1010 (code, R) = 0x9A
    // Flags nibble: L=1 (long mode), others 0
    //   [0:15]  limit_lo  = 0xFFFF
    //   [16:31] base_lo   = 0x0000
    //   [32:39] base_mid  = 0x00
    //   [40:47] access    = 0x9A
    //   [48:55] flags+limit_hi = 0xAF  (G=1,D=0,L=1,AVL=0,limit=0xF)
    //   [56:63] base_hi   = 0x00
    .quad 0x00AF9A000000FFFF
gdt64_data:
    // 64-bit data segment: P=1, S=1, Type=0010 (data, W) = 0x92
    .quad 0x00CF92000000FFFF
gdt64_end:

gdt64_ptr:
    .short gdt64_end - gdt64 - 1    // limit
    .quad  gdt64                    // base (linear)

.section .text
.code32
.global _start
.type _start, @function
_start:
    // Disable interrupts + set stack.
    cli
    mov $stack_top, %esp

    // -- Save the PVH start_info pointer BEFORE any code runs that
    // could clobber it. PVH spec says EBX, but we save EDI too as a
    // belt-and-suspenders fallback (the trampoline's pre-SOUL.2
    // comment incorrectly said EDI, and old kernels worked because
    // they ignored both). The Quartz probe picks whichever has the
    // right magic. The high 32 bits of each slot stay zero (the .bss
    // initializer); QEMU PVH puts start_info in low memory below
    // 4 GiB, so a 32-bit pointer is sufficient.
    movl %ebx, pvh_start_info_ptr
    movl %edi, pvh_start_info_ptr_alt

    // -- Build identity-mapped page tables for the first 2 MiB. --
    // pml4[0] = pdpt | 0x03 (Present | Writable)
    mov $pdpt, %eax
    or $0x03, %eax
    mov %eax, pml4

    // pdpt[0] = pd | 0x03
    mov $pd, %eax
    or $0x03, %eax
    mov %eax, pdpt

    // pd[0..512] = <i * 2MiB> | 0x83 — map first 1 GiB via 512
    // 2 MiB huge pages. Each PDE is 8 bytes; we write the physical
    // address (low 32 bits) to the first 4 bytes and rely on BSS
    // being zero-initialized for the upper 4. The highest PDE
    // physical address is 0x3FE00000 (= 1022 * 2 MiB) which fits
    // entirely in the low 32 bits.
    xorl %ecx, %ecx                 // i = 0
    movl $0x00000083, %eax           // eax = phys 0 | PS|W|P
1:
    movl %eax, pd(,%ecx,8)           // pd[i].low = eax
    addl $0x00200000, %eax           // eax += 2 MiB
    incl %ecx
    cmpl $512, %ecx
    jne 1b

    // pdpt[3] = pd_apic | 0x03 — covers the 3-4 GiB linear range, in
    // which the LAPIC MMIO window at 0xFEE00000 lives.
    mov $pd_apic, %eax
    or $0x03, %eax
    mov %eax, pdpt + 0x18            // slot 3: offset 3 * 8

    // pd_apic[503] = 0xFEE00083 — identity-map the single 2 MiB huge
    // page that contains 0xFEE00000 (the x86 legacy LAPIC MMIO base).
    // 503 = (0xFEE00000 - 0xC0000000) / 0x200000.
    movl $0xFEE00083, pd_apic + (503 * 8)

    // pd_apic[501] = 0xFEA00083 — identity-map the 2 MiB huge page
    // that contains the QEMU microvm virtio-mmio window. 8 slots of
    // 0x200 bytes each, starting at 0xFEB00000, all fit in this page.
    // 501 = (0xFEA00000 - 0xC0000000) / 0x200000.
    movl $0xFEA00083, pd_apic + (501 * 8)

    // -- SOUL.2: identity-map 1-3 GiB and 4-64 GiB with 1 GiB huge
    // pages so the dynamic PMM pool can use any RAM the PVH probe
    // discovers. Skips PDPT[0] (already populated above with 2 MiB
    // pages for 0-1 GiB) and PDPT[3] (already populated with pd_apic
    // for the LAPIC + virtio-mmio window). Each PDPTE for a 1 GiB
    // page is 8 bytes: low 32 = phys[31:0] | 0x83 (P|RW|PS), high
    // 32 = phys[63:32]. ECX = pdpt slot, EAX/EDX = phys low/high.
    // Requires CPUID 0x80000001:EDX bit 26 (1 GiB pages) — present
    // on `-cpu max` and on every Skylake-or-newer x86_64 CPU. The
    // ESI register is used as scratch (we don't trash EBX since
    // we already saved it to pvh_start_info_ptr above, but ESI was
    // never used).
    movl $1, %ecx                    // ecx = pdpt slot index
    movl $0x40000000, %eax           // eax = phys low (start at 1 GiB)
    xorl %edx, %edx                  // edx = phys high
4:
    cmpl $3, %ecx
    je   5f                          // skip pdpt[3] (pd_apic occupies it)
    movl %eax, %esi
    orl  $0x83, %esi                 // P|RW|PS
    movl %esi, pdpt(,%ecx,8)         // pdpt[ecx].low
    movl %edx, pdpt+4(,%ecx,8)       // pdpt[ecx].high
5:
    addl $0x40000000, %eax           // advance phys low by 1 GiB
    adcl $0, %edx                    // carry into phys high
    incl %ecx
    cmpl $64, %ecx                   // SOUL scale-up: map 64 GiB (PDPT[0..63])
    jne  4b

    // -- Enable PAE (CR4.PAE = bit 5). --
    mov %cr4, %eax
    or $0x20, %eax
    mov %eax, %cr4

    // -- Load PML4 base into CR3. --
    mov $pml4, %eax
    mov %eax, %cr3

    // -- Enable long mode (EFER.LME = bit 8, MSR 0xC0000080). --
    mov $0xC0000080, %ecx
    rdmsr
    or $0x100, %eax
    wrmsr

    // -- Enable paging (CR0.PG = bit 31). Long mode becomes active. --
    mov %cr0, %eax
    or $0x80000000, %eax
    mov %eax, %cr0

    // -- Load GDT. --
    lgdt gdt64_ptr

    // -- Far jump to 64-bit code segment (selector 0x08). --
    ljmp $0x08, $long_mode_start
.size _start, . - _start

.code64
long_mode_start:
    // Reload data segments to the 64-bit data selector (0x10).
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs

    // Re-set RSP to the post-paging linear address (same identity map).
    mov $stack_top, %rsp

    // Call Quartz main. @c ABI: qz_main takes no args, returns i64.
    call qz_main

    // Fall-through halt. A KERN.1-grade exit path would shut down
    // cleanly; for the skeleton we just park the CPU.
    cli
1:  hlt
    jmp 1b

// --------------------------------------------------------------------
// Helpers for the IDT. Quartz has no syntax for taking the address of
// an extern asm symbol, and `lidt` needs a specific memory operand
// shape — so we expose small asm shims and FFI them from Quartz as
// `extern "C" def ...`.

// Return the linear address of idt_storage (i64).
.global get_idt_addr
.type get_idt_addr, @function
get_idt_addr:
    lea idt_storage(%rip), %rax
    ret
.size get_idt_addr, . - get_idt_addr

// Return the linear address of idtr_storage (i64).
.global get_idtr_addr
.type get_idtr_addr, @function
get_idtr_addr:
    lea idtr_storage(%rip), %rax
    ret
.size get_idtr_addr, . - get_idtr_addr

// Issue `lidt (%rdi)`. Caller passes the address of a 10-byte IDTR
// pseudo-descriptor (2-byte limit + 8-byte base).
.global idt_load
.type idt_load, @function
idt_load:
    lidt (%rdi)
    ret
.size idt_load, . - idt_load

// Return the runtime PMM pool bounds set by Quartz's pvh_probe_ram
// during early boot. Returns 0 if probe hasn't run yet (the .bss
// initializer); callers that need the bounds before probe completion
// must coordinate ordering, but in practice probe runs at the very
// top of qz_main before any allocation.
.global get_pmm_pool_start
.type get_pmm_pool_start, @function
get_pmm_pool_start:
    movq pmm_pool_start_addr(%rip), %rax
    ret
.size get_pmm_pool_start, . - get_pmm_pool_start

.global get_pmm_pool_end
.type get_pmm_pool_end, @function
get_pmm_pool_end:
    movq pmm_pool_end_addr(%rip), %rax
    ret
.size get_pmm_pool_end, . - get_pmm_pool_end

// Return the saved PVH start_info pointer (EBX at entry).
.global get_pvh_start_info
.type get_pvh_start_info, @function
get_pvh_start_info:
    movq pvh_start_info_ptr(%rip), %rax
    ret
.size get_pvh_start_info, . - get_pvh_start_info

// Return the alternate saved PVH start_info pointer (EDI at entry).
// Used by the Quartz probe as a fallback if EBX didn't have it.
.global get_pvh_start_info_alt
.type get_pvh_start_info_alt, @function
get_pvh_start_info_alt:
    movq pvh_start_info_ptr_alt(%rip), %rax
    ret
.size get_pvh_start_info_alt, . - get_pvh_start_info_alt

// Return total system RAM detected from the PVH memmap (sum of
// Type=1 region sizes). 0 if probe hasn't run yet.
.global get_detected_ram_bytes
.type get_detected_ram_bytes, @function
get_detected_ram_bytes:
    movq detected_ram_bytes(%rip), %rax
    ret
.size get_detected_ram_bytes, . - get_detected_ram_bytes

// pmm_set_pool_bounds(start: u64, end: u64, total_ram: u64)
//
// Setter called from Quartz's pvh_probe_ram at boot. SysV ABI:
// rdi = start, rsi = end, rdx = total_ram_bytes.
.global pmm_set_pool_bounds
.type pmm_set_pool_bounds, @function
pmm_set_pool_bounds:
    movq %rdi, pmm_pool_start_addr(%rip)
    movq %rsi, pmm_pool_end_addr(%rip)
    movq %rdx, detected_ram_bytes(%rip)
    ret
.size pmm_set_pool_bounds, . - pmm_set_pool_bounds

// switch_to(from: *i64, to: *i64)
//
// Context switch between two cooperative tasks. Each task slot is a
// pointer to an i64 holding the task's saved RSP.
//
// System V ABI: %rdi = from, %rsi = to. We push the six callee-saved
// registers the ABI says the caller is NOT responsible for preserving
// (rbx, rbp, r12..r15), save RSP to *from, load RSP from *to, pop the
// incoming task's saved registers, and `ret` — which pops the new
// task's return address (either the real one from a prior switch_to
// call, or a seeded entry function on first-run).
//
// Caller-saved regs (rax, rcx, rdx, rsi, rdi, r8..r11) are clobbered
// per SysV, so we don't save them. FPU/SSE state is similarly whatever
// the compiler emitted — we run with -mattr=-sse anyway.
.global switch_to
.type switch_to, @function
switch_to:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq  %rsp, (%rdi)    // from->rsp = current rsp
    movq  (%rsi), %rsp    // rsp = to->rsp
    popq  %r15
    popq  %r14
    popq  %r13
    popq  %r12
    popq  %rbp
    popq  %rbx
    retq                  // pops return address from the new stack
.size switch_to, . - switch_to

// Read the x86 time-stamp counter. RDTSC writes a 64-bit cycle count
// into %edx:%eax (high 32 bits in %edx, low 32 in %eax). We assemble
// the two halves into %rax for the System V return convention.
//
// Used by SOUL.4 v3's time_mono_ns wrapper for wall-clock task
// deadlines. Modern x86 (`-cpu max` / Skylake+) advertises invariant
// TSC, so this is monotonic across CPU sleep states; QEMU TCG also
// honors this with `-cpu max`.
//
// No serializing prefix — call sites that need ordered samples
// against memory loads should use rdtscp or an mfence/rdtsc pair.
// For a coarse 2-second-deadline poll, the unordered form is fine.
.global read_tsc
.type read_tsc, @function
read_tsc:
    rdtsc
    shlq $32, %rdx
    orq  %rdx, %rax
    retq
.size read_tsc, . - read_tsc
