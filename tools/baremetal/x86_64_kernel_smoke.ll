; Minimal x86_64 freestanding smoke IR for the SYS.1 target-knobs
; passthrough test. Hand-written (not emitted by the Quartz compiler)
; so the test exercises the Quake plumbing without depending on SYS.1
; item 6 (the @[panic_handler] / internal-linkage-prelude work that
; unblocks full Quartz freestanding source compilation).
;
; No libc, no crt0, no runtime. Declares _start, copies a 16-byte
; buffer (a deliberate SSE trigger — LLVM will vectorize this into
; `movaps %xmm0, ...` on x86_64 by default, unless -mattr=-sse is
; passed to LLC), then halts the CPU with `hlt` and loops forever.
;
; The `"no-red-zone"` function attribute is how LLVM disables red-zone
; usage — there is no command-line LLC knob for red zone; it's per-
; function metadata. The 16-byte memcpy exists specifically so the
; `baremetal:verify_x86_64_knobs` task can prove `-mattr=-sse` is
; flowing through to LLC: with the knob, the .o contains zero `xmm`
; references; without it, 2+ `xmm` references appear.

target triple = "x86_64-unknown-none-elf"

@buf_a = internal global [16 x i8] zeroinitializer, align 16
@buf_b = internal global [16 x i8] zeroinitializer, align 16

define void @_start() noreturn nounwind "no-red-zone" {
entry:
  call void @llvm.memcpy.p0.p0.i64(ptr @buf_a, ptr @buf_b, i64 16, i1 false)
  br label %loop
loop:
  call void asm sideeffect "hlt", "~{dirflag},~{fpsr},~{flags}"() nounwind
  br label %loop
}

declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
