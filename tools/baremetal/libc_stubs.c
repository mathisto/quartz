// Minimal libc-surface stubs + slab allocator for the baremetal pipeline.
//
// Quartz's freestanding codegen emits `declare` statements for a small
// set of libc-shaped symbols that compiler-emitted code calls by name
// (malloc/realloc/free/memcpy/memset/qsort — the Rust `no_std + alloc`
// pattern). We back them with a two-tier allocator over the bump PMM
// provided by the Quartz side (pmm_alloc_page in hello_x86.qz, reachable
// here via extern linkage because Quartz emits top-level def names
// unmangled).
//
// **Tier 1 — slab allocator (≤ 512 B).** Six power-of-2 size classes
// (16, 32, 64, 128, 256, 512 B) layered over the bump PMM. Each class
// has an intrusive freelist (free chunk[0..7] = next pointer). When a
// class runs dry, refill consumes one PMM page and slices it into
// chunk_size pieces, threaded LIFO onto the freelist. Slab pages carry
// a 32-byte header at offset 0 (magic + class_idx + chunk_size +
// chunks_in_page); chunks start at offset 32. Free reads the
// page-aligned-down magic to dispatch slab vs. multi-page.
//
// **Tier 2 — multi-page bump (> 512 B).** Allocations larger than the
// largest slab class fall through to the original bump path: round
// total bytes (incl. 16-byte size header) up to whole pages, consume
// pages contiguously, return base+16. Free is a no-op (bump never
// reclaims). Realloc uses the size header to copy the live bytes into
// a fresh allocation when growing.
//
// Single-core unikernel ⇒ no locking, no per-CPU caches, no deferred
// page reclaim — Bonwick 1994 stripped to its essential primitive.
//
// References:
//  - Bonwick, "The Slab Allocator: An Object-Caching Kernel Memory
//    Allocator" (USENIX Summer 1994). The original.
//  - Linux SLUB and OpenBSD's mallocarray / pool_get share the same
//    intrusive-freelist + slab-page-header skeleton.

typedef unsigned long size_t;
typedef unsigned long uintptr_t;
typedef unsigned long long uint64_t;

// ============================================================================
// UART direct (for OOM panic + slab diagnostic guard — bypasses Quartz
// uart_* which depends on Quartz-side runtime that may not be available
// before / during module-init).
// ============================================================================

#define PAGE_SIZE 4096
#define PAGE_MASK (~(uintptr_t)(PAGE_SIZE - 1))

#define UART_DATA_PORT 0x3F8
#define UART_LSR_PORT  0x3FD
#define UART_LSR_THRE  0x20

static inline unsigned char dbg_in8(unsigned short port) {
  unsigned char v;
  __asm__ volatile ("inb %1, %0" : "=a"(v) : "Nd"(port));
  return v;
}
static inline void dbg_out8(unsigned short port, unsigned char val) {
  __asm__ volatile ("outb %0, %1" :: "a"(val), "Nd"(port));
}
static void dbg_putc(char c) {
  while ((dbg_in8(UART_LSR_PORT) & UART_LSR_THRE) == 0) {}
  dbg_out8(UART_DATA_PORT, (unsigned char)c);
}
static void dbg_puts(const char *s) {
  while (*s) dbg_putc(*s++);
}
static void dbg_put_hex(uint64_t v) {
  dbg_putc('0'); dbg_putc('x');
  for (int i = 60; i >= 0; i -= 4) {
    unsigned d = (unsigned)((v >> i) & 0xF);
    dbg_putc(d < 10 ? ('0' + d) : ('a' + d - 10));
  }
}
static void dbg_put_dec(uint64_t v) {
  char buf[24]; int n = 0;
  if (v == 0) { dbg_putc('0'); return; }
  while (v > 0) { buf[n++] = '0' + (char)(v % 10); v /= 10; }
  while (n > 0) dbg_putc(buf[--n]);
}

// ============================================================================
// PMM bridge — bump page allocator. Cursor + pmm_alloc_page live in
// Quartz (`tools/baremetal/hello_x86.qz`). These extern decls let the
// slab allocator below call into them.
// ============================================================================

extern long pmm_alloc_page(void);
// Path C.5.5 — atomic contiguous N-page bump (one g_pmm_lock acquisition).
// The multi-page bump allocator below REQUIRES the N pages to be physically
// sequential; a per-page pmm_alloc_page() loop races AP ss_refills under SMP
// (PATH_C_STACK_ON_DEMAND.md §12.8 #2). Defined in hello_x86.qz.
extern long pmm_alloc_pages_contig(long n);
extern long get_pmm_pool_start(void);
extern long get_pmm_pool_end(void);

// ============================================================================
// Slab allocator
// ============================================================================

#define SLAB_NUM_CLASSES 6

// Magic stamped at offset 0 of every slab page. Distinct from any
// realistic multi-page allocation size (size_t values for legitimate
// allocations are at most ~10^14; this magic is ~5.86 × 10^18, so the
// dispatcher in free() can read the page-base u64 and disambiguate
// slab page vs. multi-page size header without a tag bit elsewhere).
// 0x515A5F534C414200 = "QZ_SLAB\0" interpreted as big-endian bytes.
#define SLAB_PAGE_MAGIC 0x515A5F534C414200ULL

// Per-class chunk size in bytes. Power-of-2 ladder. log2(min) = 4 so
// size_to_class_idx is a leading-zero count; see slab_class_idx_for.
static const size_t SLAB_CLASS_SIZES[SLAB_NUM_CLASSES] = {
    16, 32, 64, 128, 256, 512,
};

// Layout at the start of every slab page (offset 0..63). Chunks begin
// at offset 64 and pack chunk_size bytes each.
//
// SLAB.1 (2026-05-27) expanded the header 32 → 64 bytes to inline a
// 256-bit per-chunk arena ownership bitmap. Bit i, set, means "chunk
// slot i of this page is alive on some task's per-request slab arena
// chain — free() must no-op until arena_end sweeps." Maximum class is
// 16B at 252 chunks/page (was 254 before expansion; 256-bit bitmap
// has slack for the 32B-class boundary). See [[feedback-multipage-
// fragmentation-under-burst]] "actual production binding constraint."
typedef struct {
  uint64_t magic;          // SLAB_PAGE_MAGIC
  uint64_t class_idx;      // 0..5
  uint64_t chunk_size;     // bytes per chunk
  uint64_t chunks_in_page; // (PAGE_SIZE - 64) / chunk_size
  uint64_t arena_bitmap[4]; // 256 bits — per-chunk arena ownership
} slab_page_header;

#define SLAB_HEADER_BYTES sizeof(slab_page_header)

// Bitmap helpers — slot is the chunk's index within the page (0..251 for
// 16B class, fewer for larger classes). Caller must have computed slot
// from chunk_addr and class chunk_size.
static inline int slab_bitmap_get(slab_page_header *hdr, int slot) {
  return (int)((hdr->arena_bitmap[slot >> 6] >> (slot & 63)) & 1ULL);
}
static inline void slab_bitmap_set(slab_page_header *hdr, int slot) {
  hdr->arena_bitmap[slot >> 6] |= (1ULL << (slot & 63));
}
static inline void slab_bitmap_clear(slab_page_header *hdr, int slot) {
  hdr->arena_bitmap[slot >> 6] &= ~(1ULL << (slot & 63));
}
static inline int slab_slot_idx_for(uintptr_t chunk, uintptr_t page_base,
                                    size_t chunk_size) {
  return (int)((chunk - page_base - SLAB_HEADER_BYTES) / chunk_size);
}

// Per-class state. `freelist` is the head of an intrusive linked list
// where each free chunk's first 8 bytes hold the next-pointer. Empty
// list = NULL. allocs/frees/refills are running totals — never reset.
typedef struct {
  void *freelist;
  uint64_t allocs;
  uint64_t frees;
  uint64_t refills;
} slab_class;

static slab_class g_slab_classes[SLAB_NUM_CLASSES];

// Map a request size (1..512) to its class index. Class 0 = 16 B; each
// successive class doubles. Caller must have already checked that
// bytes <= 512 — out-of-range bytes return 0 here, but the caller
// always falls through to the multi-page path before invoking this.
static int slab_class_idx_for(size_t bytes) {
  // Ensure bytes round up to the smallest class.
  if (bytes <= 16) return 0;
  if (bytes <= 32) return 1;
  if (bytes <= 64) return 2;
  if (bytes <= 128) return 3;
  if (bytes <= 256) return 4;
  return 5; // 257..512
}

// Refill a class's freelist by consuming one PMM page and threading
// every chunk in it onto the freelist (LIFO push order — last chunk
// pushed is the next chunk allocated). The slab header at offset 0..63
// is reserved (SLAB_HEADER_BYTES = sizeof(slab_page_header) = 64);
// chunks span offsets 64..(64 + chunks * chunk_size).
static void slab_refill(int class_idx) {
  long page = pmm_alloc_page();
  if (page == 0) {
    // PMM exhausted — slab refill fails silently. Subsequent
    // slab_alloc on this class will see freelist still NULL and
    // return NULL, causing malloc() to fall through to the multi-page
    // path. That path will likely also fail and the kernel will OOM
    // halt via pmm_alloc_page's existing OOM-print.
    return;
  }
  slab_page_header *hdr = (slab_page_header *)(uintptr_t)page;
  size_t chunk_size = SLAB_CLASS_SIZES[class_idx];
  size_t chunks_in_page = (PAGE_SIZE - SLAB_HEADER_BYTES) / chunk_size;

  hdr->magic = SLAB_PAGE_MAGIC;
  hdr->class_idx = (uint64_t)class_idx;
  hdr->chunk_size = (uint64_t)chunk_size;
  hdr->chunks_in_page = (uint64_t)chunks_in_page;
  // SLAB.1 — zero the per-chunk arena ownership bitmap. PMM is a bump
  // allocator (no zero-on-alloc), so without this the bitmap would
  // inherit whatever bytes happened to sit at that physical address —
  // any spurious set bit would cause slab_free to no-op a chunk that
  // isn't actually arena-tracked, and the chunk would then be handed
  // out by a subsequent slab_alloc (double-allocation hazard).
  hdr->arena_bitmap[0] = 0;
  hdr->arena_bitmap[1] = 0;
  hdr->arena_bitmap[2] = 0;
  hdr->arena_bitmap[3] = 0;

  slab_class *cls = &g_slab_classes[class_idx];
  // Thread chunks onto freelist back-to-front so the lowest-address
  // chunk emerges first on the next alloc. LIFO push order.
  void *head = cls->freelist;
  for (size_t i = chunks_in_page; i > 0; i--) {
    size_t idx = i - 1;
    void *chunk = (void *)((uintptr_t)page + SLAB_HEADER_BYTES + idx * chunk_size);
    *(void **)chunk = head;
    head = chunk;
  }
  cls->freelist = head;
  cls->refills++;
}

// Forward declaration — SLAB.1 arena hook. Definition lives with the
// rest of the per-request arena machinery further down so it can see
// TASK_SLAB_ARENA_HEAD / sched_current() / chain-page bookkeeping.
// Called from slab_alloc just before returning the chunk to the caller.
static void slab_arena_track(void *chunk, slab_page_header *hdr, int class_idx);

// KERN.SLAB.2 — forward declarations for the arena-slot value validators
// + halt site (definitions further down with the arena machinery).
// slab_arena_drain / slab_arena_chain_push use these to catch wild
// TASK_SLAB_ARENA_HEAD / chain-page values at every read, halting before
// the cascade corrupts the slab class freelists.
static inline int arena_slot_value_ok(uintptr_t v);
static inline int slab_arena_slot_value_ok(uintptr_t v);
static void arena_slot_corrupt_halt(const char *site, long task,
                                    uintptr_t slot_addr, uintptr_t value);

// Allocate a chunk of size <= 512. Returns NULL if no PMM page is
// available for refill (the multi-page path then takes over). Class
// is selected by rounding bytes up to the next power-of-2 in the
// 16..512 range.
static void *slab_alloc(size_t bytes) {
  int idx = slab_class_idx_for(bytes);
  slab_class *cls = &g_slab_classes[idx];
  if (cls->freelist == 0) {
    slab_refill(idx);
    if (cls->freelist == 0) {
      return (void *)0;
    }
  }
  void *chunk = cls->freelist;
  // Diagnostic guard: chunk must point inside a valid slab page (page
  // header at page_base must carry SLAB_PAGE_MAGIC). Catches use-after-
  // free / OOB-write corruption that put a non-slab pointer onto the
  // freelist before the deref of *chunk crashes.
  uintptr_t cb = (uintptr_t)chunk;
  uintptr_t cpage = cb & PAGE_MASK;
  // Range check uses the live PMM pool bounds — captured on the first
  // pass after slab_refill ran pmm_alloc_page (which lazy-runs
  // pvh_probe_ram → pmm_set_pool_bounds). The original guard hard-coded
  // 0x80000000 (2 GiB), which silently failed on production -m 6G where
  // pvh_probe_ram picks the high-RAM region at 0x100000000 because it's
  // 16 MiB larger after the low-region kernel-floor trim. The boot
  // trampoline identity-maps 16 GiB (PDPT[0..15] in boot_trampoline_x86.s),
  // so addresses up to ~0x400000000 are valid; the bound here just
  // mirrors whatever pvh_probe_ram chose, so the guard tightens as the
  // pool size shrinks.
  uintptr_t pool_lo = (uintptr_t)get_pmm_pool_start();
  uintptr_t pool_hi = (uintptr_t)get_pmm_pool_end();
  if (cb < pool_lo || cb >= pool_hi || (cb & 0xFULL) != 0) {
    dbg_puts("\n[SLAB-CORRUPT] bad chunk addr cls=");
    dbg_put_dec(idx);
    dbg_puts(" size=");
    dbg_put_dec(SLAB_CLASS_SIZES[idx]);
    dbg_puts(" chunk=");
    dbg_put_hex(cb);
    dbg_puts(" allocs=");
    dbg_put_dec(cls->allocs);
    dbg_puts(" frees=");
    dbg_put_dec(cls->frees);
    dbg_puts(" refills=");
    dbg_put_dec(cls->refills);
    dbg_putc('\n');
    while (1) { __asm__ volatile ("cli; hlt"); }
  }
  // Page-header magic check (only safe after the range check above).
  if (*(uint64_t *)cpage != SLAB_PAGE_MAGIC) {
    dbg_puts("\n[SLAB-CORRUPT] chunk page lacks magic cls=");
    dbg_put_dec(idx);
    dbg_puts(" size=");
    dbg_put_dec(SLAB_CLASS_SIZES[idx]);
    dbg_puts(" chunk=");
    dbg_put_hex(cb);
    dbg_puts(" page_base=");
    dbg_put_hex(cpage);
    dbg_puts(" hdr0=");
    dbg_put_hex(*(uint64_t *)cpage);
    dbg_puts(" allocs=");
    dbg_put_dec(cls->allocs);
    dbg_puts(" frees=");
    dbg_put_dec(cls->frees);
    dbg_putc('\n');
    while (1) { __asm__ volatile ("cli; hlt"); }
  }
  cls->freelist = *(void **)chunk;
  cls->allocs++;

  // SLAB.1 (2026-05-27) — per-request slab arena tracking. If the calling
  // task has an active arena, record this allocation on the task's slab
  // arena chain so arena_end can sweep it back to the class freelist
  // regardless of whether user code ever called slab_free.
  slab_arena_track(chunk, (slab_page_header *)cpage, idx);

  return chunk;
}

// Push a chunk back onto its class's freelist. Assumes p was returned
// by slab_alloc — the caller (free()) gates by reading the slab page
// magic at p's page base.
//
// SLAB.1: if the arena owns this chunk (bitmap bit set), do nothing
// here — qz_arena_end will sweep it and clear the bit.
static void slab_free(void *p) {
  uintptr_t page_base = (uintptr_t)p & PAGE_MASK;
  slab_page_header *hdr = (slab_page_header *)page_base;
  uint64_t class_idx = hdr->class_idx;
  if (class_idx >= SLAB_NUM_CLASSES) {
    // Corrupt header — refuse to free rather than push onto a
    // bogus freelist. Allocation effectively leaks; better than
    // wedging the slab dispatcher.
    return;
  }
  int slot = slab_slot_idx_for((uintptr_t)p, page_base, (size_t)hdr->chunk_size);
  if (slab_bitmap_get(hdr, slot)) {
    // Arena-owned — arena_end will release. No-op now.
    return;
  }
  slab_class *cls = &g_slab_classes[class_idx];
  *(void **)p = cls->freelist;
  cls->freelist = p;
  cls->frees++;
}

// Test whether p was returned by slab_alloc (vs. a multi-page
// allocation). Used by free() to dispatch.
static int slab_owns(void *p) {
  if (p == 0) return 0;
  uintptr_t page_base = (uintptr_t)p & PAGE_MASK;
  return *(uint64_t *)page_base == SLAB_PAGE_MAGIC;
}

// Read the chunk size (= the maximum live bytes the chunk can hold)
// for a slab-owned pointer. Used by realloc when migrating between
// classes or deciding "shrink fits in place."
static size_t slab_chunk_size(void *p) {
  uintptr_t page_base = (uintptr_t)p & PAGE_MASK;
  slab_page_header *hdr = (slab_page_header *)page_base;
  return (size_t)hdr->chunk_size;
}

// External accessors — Quartz side reads these via FFI to populate
// /api/stats.json and to drive the boot smoke test.

// Field codes: 0=chunk_size, 1=allocs, 2=frees, 3=refills, 4=in_use.
// Out-of-range (class_idx >= 6 or field >= 5) returns 0.
unsigned long slab_class_stat(int class_idx, int field) {
  if (class_idx < 0 || class_idx >= SLAB_NUM_CLASSES) return 0;
  slab_class *cls = &g_slab_classes[class_idx];
  switch (field) {
    case 0: return SLAB_CLASS_SIZES[class_idx];
    case 1: return cls->allocs;
    case 2: return cls->frees;
    case 3: return cls->refills;
    case 4: return cls->allocs - cls->frees;
    default: return 0;
  }
}

int slab_num_classes(void) { return SLAB_NUM_CLASSES; }

// ============================================================================
// Multi-page bump (> 512 B)
// ============================================================================

// ALIGNMENT NOTE: pmm_alloc_page returns page-aligned addresses. We
// want malloc to return 16-byte-aligned addresses so Vec<T>'s load/
// store of @value struct slots is well-defined. Multi-page allocations
// therefore reserve 16 bytes for the size header (size_t at offset 0,
// padded to 16 B) and return base + 16. Slab allocations bypass this
// header entirely; their chunk addresses are 16-byte-aligned because
// every slab class size is a multiple of 16 and chunks start at
// offset 32 (16-byte-aligned within the page).
#define BUMP_HEADER_BYTES 16

// ============================================================================
// Multi-page chunk freelist
// ============================================================================
//
// Background: the original multi-page path bumped pages off the PMM cursor
// and never reclaimed on free — fine for kernel-lifetime allocations, fatal
// once the supervised HTTP server started churning per-request 64 KiB
// scratch buffers in `_kernel_router_dispatch`. With the post-D.11 Phase
// 8b.2.c spawn fix making the listener loop concurrent, the soul page's
// fsoul_grid() polling (`/api/soul/tasks.json` every 500 ms, ~33 KiB
// response → 64 KiB request scratch) leaked 64 KiB per poll. 3 GiB PMM
// pool was exhausting in ~3.4 hours of idle browser presence; under spawn
// load + parallel polling, OOM hit inside ~10 min and the kernel halted
// (`OOM (pmm)` on UART).
//
// Original fix (commit c06a148d): per-chunk LIFO freelist threaded
// through the 16-byte chunk header. Free() pushed; malloc_pages() popped
// the first chunk that fit. That closed the no-reclaim leak but had its
// own degenerate case under bursty mixed-size traffic: a 200-byte alloc
// would pop a freed 64-KiB chunk, the 16-page capacity wasted; the next
// 64-KiB request missed the freelist and consumed fresh PMM. Production
// (2026-05-26) showed `refills` climbing at ~94/sec under live load
// even though `frees ≈ recycles` — fragmentation, not a leak.
//
// Current fix: per-page-count buckets. One freelist per page-count
// (indexed 1..MULTIPAGE_MAX_BUCKETS-1). Chunks of N pages only service
// requests of N pages. No "scan larger" fallback — that resurrects the
// fragmentation. The few sizes the kernel actually uses (1-page Strings,
// 17-page router scratch, etc.) each gravitate to their own bucket and
// recycle in steady state. Chunks of >= MULTIPAGE_MAX_BUCKETS pages
// (rare) spill onto an overflow first-fit list with the legacy policy.
//
// Memory layout for chunks is unchanged: size at offset 0 (capacity bytes,
// low bit = arena-owned), next at offset 8 (intrusive freelist), payload
// at offset 16. realloc, multi_page_size, and the arena code all see the
// same shape they did before.

// Sentinel for "next" slot in the chunk header. Stored at offset 8 of the
// chunk base; size lives at offset 0. Both are written by free(), only
// `size` survives across alloc.
typedef struct __attribute__((aligned(16))) bump_freenode {
  size_t size;                  // offset 0  — chunk payload-capable bytes
  struct bump_freenode *next;   // offset 8  — single-linked freelist
  // payload follows at offset 16 (= BUMP_HEADER_BYTES)
} bump_freenode;

// Bucket indexed by page count. Index 0 is unused (no zero-page chunks).
// 32 buckets cover chunks up to 31 pages (= 124 KiB capacity); the only
// known caller above 16 pages is `_kernel_router_dispatch` at 17 pages
// (65536-byte scratch). Anything ≥ MULTIPAGE_MAX_BUCKETS spills onto
// `g_multipage_overflow` and uses first-fit (legacy LIFO).
#define MULTIPAGE_MAX_BUCKETS 32

static bump_freenode *g_multipage_buckets[MULTIPAGE_MAX_BUCKETS] = {0};
static bump_freenode *g_multipage_overflow = 0;

// Telemetry — exposed via libc_multipage_stat for /api/stats.json hooks.
// Counts EVENTS (alloc/free) not bytes. With per-bucket freelists, a
// healthy steady state has `refills` plateauing once each bucket has
// filled to its peak working set; only fresh size classes drive refills.
static unsigned long g_multipage_allocs = 0;     // total malloc_pages calls
static unsigned long g_multipage_frees = 0;      // total multi-page frees
static unsigned long g_multipage_refills = 0;    // calls that consumed fresh PMM
static unsigned long g_multipage_recycles = 0;   // calls that reused a freelist entry
static unsigned long g_multipage_multi_refills = 0; // refills with pages>1 (fresh contiguous multi-page bumps via pmm_alloc_pages_contig)

unsigned long libc_multipage_stat(int field) {
  switch (field) {
    case 0: return g_multipage_allocs;
    case 1: return g_multipage_frees;
    case 2: return g_multipage_refills;
    case 3: return g_multipage_recycles;
    case 4: return g_multipage_multi_refills;
    default: return 0;
  }
}

// Recover the page count from a chunk's stored capacity. Capacity is
// always `pages * PAGE_SIZE - BUMP_HEADER_BYTES` (set at refill time),
// so the arithmetic is exact regardless of `want_bytes` at alloc.
static inline size_t pages_for_capacity(size_t cap) {
  return (cap + BUMP_HEADER_BYTES) / PAGE_SIZE;
}

// Push a non-arena-owned chunk onto the freelist (per-bucket or overflow).
// Caller is responsible for clearing the arena-owned bit and bumping any
// telemetry counter; `next` is overwritten here.
static void multipage_push_freelist(bump_freenode *hdr) {
  size_t pages = pages_for_capacity(hdr->size);
  if (pages < MULTIPAGE_MAX_BUCKETS) {
    hdr->next = g_multipage_buckets[pages];
    g_multipage_buckets[pages] = hdr;
  } else {
    hdr->next = g_multipage_overflow;
    g_multipage_overflow = hdr;
  }
}

// ============================================================================
// Per-request arena (D.11 Phase 8b.2.c.7)
// ============================================================================
//
// Background: even after the multi-page freelist (commit c06a148d) recycles
// per-request scratch (64 KiB router buffers), each HTTP response still
// allocates ~10–12 Quartz Strings (status_line + headers + body concats in
// `_async_http_write_response_timeout`) that have no explicit `mem_free`
// call. Native Quartz has no GC; pre-arena those chunks leaked forever and
// production exhausted PMM in ~30 min wall.
//
// Fix: per-request arena. The supervised per-conn loop calls
// `qz_arena_begin()` at the top of each iteration and `qz_arena_end()` at
// the bottom. All multi-page allocations made during the arena are tracked
// on a per-task chain; arena_end pushes every tracked chunk back onto the
// global multi-page freelist in O(N). Subsequent requests reuse the same
// chunks via the freelist's first-fit scan.
//
// Per-task (not global) state: cooperative scheduling means several
// connections can have arenas in flight simultaneously (one yields inside
// `_async_http_parse_request_timeout`, another runs its handler, etc.).
// A single global flag would conflate them. We store one i64 slot per task
// at TASK_ARENA_HEAD (offset 184 in the task struct, currently the only
// unused 8-byte slot before B.5 park_deadline — relocate if/when B.5 ships).
//
// Slot encoding (one i64):
//   0     — arena inactive
//   1     — arena active, empty chain (sentinel; chain head ptrs are
//           16-byte aligned so 1 is unambiguous)
//   ptr   — arena active, head of chain at ptr
//
// Per-chunk encoding (low bit of `size`):
//   Sizes are page_count*4096 - 16, always a multiple of 16, so bit 0 is
//   always clear for "real" sizes. We use bit 0 as the "arena-owned"
//   flag: when set, free() is a no-op (arena will release at end);
//   when clear, free() pushes to the global freelist as before.
//
// Lifecycle:
//   arena_begin: defensively call arena_end if slot != 0 (catches throw-
//     unwind through the with-block); then write slot = 1 (active+empty).
//   malloc_pages while active: alloc as usual, set hdr->size |= 1, link
//     hdr->next = (slot == 1 ? 0 : slot), slot = hdr.
//   free while chunk has size&1 == 1: no-op.
//   arena_end: walk chain from slot; for each chunk, clear bit 0, push to
//     global freelist (overwriting next), increment released counter.
//     Finally write slot = 0.

extern long sched_current(void);

// Mirror the Quartz constants TASK_ARENA_HEAD / TASK_SLAB_ARENA_HEAD /
// TASK_SAVED_STACK_PTR / TASK_STACK_CANARY in tools/baremetal/hello_x86.qz.
// Relocate together if the task struct layout changes. SLAB.1 (2026-05-27)
// added TASK_SLAB_ARENA_HEAD at +192 and bumped TASK_STRUCT_SIZE 192→200.
// Path C.5.2 (2026-05-31) repurposed slot 16 (was TASK_STACK_BASE, a per-task
// leased running-stack) into TASK_SAVED_STACK_PTR (the per-task SAVED-stack
// buffer for copying-stack scheduling), added LEN at +200 / CAP at +208, and
// bumped TASK_STRUCT_SIZE 200→216. B.5e (2026-06-03) added TASK_ACTOR_INBOX
// at +216 and bumped TASK_STRUCT_SIZE 216→224.
#define TASK_SAVED_STACK_PTR 16
#define TASK_ARENA_HEAD 184
#define TASK_SLAB_ARENA_HEAD 192
#define TASK_STRUCT_SIZE 224
// Sentinel written once by Quartz uk_sched_init at the single active stack's
// base+0. Stack grows DOWN, so the canary at the BASE is the last 8 bytes
// before overflow. Mirror of TASK_STACK_CANARY in hello_x86.qz — must match.
#define TASK_STACK_CANARY ((uint64_t)0xCAFEBABEDEADBEEFULL)

// Path C.5.5 — the active stack is PER-CPU. Each CPU's 16-KiB active-stack
// base lives at %gs:PCPU_ACTIVE_STACK_BASE (allocated + canary-stamped in
// kern8_pcpu_init). The stack-overflow canary check reads the RUNNING CPU's
// base directly via kern8_gs_load_u64 — no set-once C global. Must match the
// PCPU_ACTIVE_STACK_BASE const in hello_x86.qz. The read is only performed
// when sched_current() != 0, i.e. a task is running on this CPU, so %gs is
// valid and the slot is populated by then.
#define PCPU_ACTIVE_STACK_BASE 112
extern uint64_t kern8_gs_load_u64(uint64_t offset);

#define ARENA_ACTIVE_EMPTY_SENTINEL ((uintptr_t)1)

// `sched_current()` reads gs-base via `mov %gs:24, %rax` (see
// `cpu_local_load` in hello_x86.qz). Before `uk_sched_init` writes the
// per-CPU base into IA32_GS_BASE, the segment override reads whatever
// physical bytes happen to sit at offset 24 — garbage that the arena
// would treat as a task pointer and dereference, faulting #GP. Module
// initializers (Vec, Map, channel, scheduler internals) run BEFORE
// uk_sched_init and DO go through malloc()/malloc_pages(). The kernel
// calls `qz_arena_runtime_ready()` once gs-base is live; until then,
// `current_arena_slot()` returns NULL and the arena code is fully
// skipped (allocations behave exactly as they did pre-arena).
static int g_arena_runtime_ready = 0;

void qz_arena_runtime_ready(void) { g_arena_runtime_ready = 1; }

static inline uintptr_t *current_arena_slot(void) {
  if (g_arena_runtime_ready == 0) return (uintptr_t *)0;
  long t = sched_current();
  if (t == 0) return (uintptr_t *)0;  // boot/scheduler-internal context
  return (uintptr_t *)(uintptr_t)(t + TASK_ARENA_HEAD);
}

// SLAB.1 — slab arena chain head slot (separate from multipage). Active
// state is gated by TASK_ARENA_HEAD (we only track slab chunks when the
// multipage arena is active).
static inline uintptr_t *current_slab_arena_slot(void) {
  if (g_arena_runtime_ready == 0) return (uintptr_t *)0;
  long t = sched_current();
  if (t == 0) return (uintptr_t *)0;
  return (uintptr_t *)(uintptr_t)(t + TASK_SLAB_ARENA_HEAD);
}

static inline size_t bump_capacity_of(bump_freenode *hdr) {
  return (size_t)(hdr->size & ~(size_t)1);
}

static inline int bump_is_arena_owned(bump_freenode *hdr) {
  return (int)(hdr->size & (size_t)1);
}

// Arena telemetry. begins/ends count qz_arena_begin/end calls; released
// counts chunks that arena_end returned to the multi-page freelist.
// SLAB.1 added slab counters.
static unsigned long g_arena_begins = 0;
static unsigned long g_arena_ends = 0;
static unsigned long g_arena_released = 0;
static unsigned long g_slab_arena_tracked = 0;
static unsigned long g_slab_arena_released = 0;
static unsigned long g_slab_arena_chain_pages = 0;

// SLAB.1 — slab arena chain page. Holds up to 510 chunk_ptrs; linked
// via `next` when one fills. 4096-byte exact size (one PMM page).
typedef struct slab_arena_chain {
  struct slab_arena_chain *next;
  uint64_t count;
  void *entries[510];
} slab_arena_chain;
_Static_assert(sizeof(slab_arena_chain) == PAGE_SIZE,
               "slab_arena_chain must be exactly one page");

static slab_arena_chain *g_slab_arena_chain_freelist = (slab_arena_chain *)0;

static slab_arena_chain *slab_arena_chain_alloc(void) {
  slab_arena_chain *p = g_slab_arena_chain_freelist;
  if (p != 0) {
    g_slab_arena_chain_freelist = p->next;
    p->next = (slab_arena_chain *)0;
    p->count = 0;
    return p;
  }
  long page = pmm_alloc_page();
  if (page == 0) return (slab_arena_chain *)0;
  p = (slab_arena_chain *)(uintptr_t)page;
  p->next = (slab_arena_chain *)0;
  p->count = 0;
  g_slab_arena_chain_pages++;
  return p;
}

static void slab_arena_chain_release(slab_arena_chain *p) {
  p->next = g_slab_arena_chain_freelist;
  p->count = 0;
  g_slab_arena_chain_freelist = p;
}

static int slab_arena_chain_push(uintptr_t *slot, void *chunk) {
  uintptr_t encoded = *slot;
  if (!slab_arena_slot_value_ok(encoded)) {
    arena_slot_corrupt_halt("slab_chain_push.entry", sched_current(),
                            (uintptr_t)slot, encoded);
  }
  slab_arena_chain *head = (slab_arena_chain *)encoded;
  if (head == 0 || head->count >= 510) {
    slab_arena_chain *fresh = slab_arena_chain_alloc();
    if (fresh == 0) return -1;
    fresh->next = head;
    *slot = (uintptr_t)fresh;
    head = fresh;
  }
  head->entries[head->count++] = chunk;
  return 0;
}

static void slab_arena_track(void *chunk, slab_page_header *hdr, int class_idx) {
  uintptr_t *arena_slot = current_arena_slot();
  if (arena_slot == 0 || *arena_slot == 0) return;
  uintptr_t *slab_slot = current_slab_arena_slot();
  if (slab_slot == 0) return;
  int slot = slab_slot_idx_for((uintptr_t)chunk, (uintptr_t)hdr,
                               SLAB_CLASS_SIZES[class_idx]);
  slab_bitmap_set(hdr, slot);
  if (slab_arena_chain_push(slab_slot, chunk) != 0) {
    slab_bitmap_clear(hdr, slot);
    return;
  }
  g_slab_arena_tracked++;
}

// Drain the slab arena chain: walk each chunk_ptr, clear bitmap bit,
// push back to class freelist. Release chain pages.
static void slab_arena_drain(uintptr_t *slot) {
  uintptr_t encoded = *slot;
  if (!slab_arena_slot_value_ok(encoded)) {
    arena_slot_corrupt_halt("slab_drain.entry", sched_current(),
                            (uintptr_t)slot, encoded);
  }
  slab_arena_chain *cur = (slab_arena_chain *)encoded;
  while (cur != 0) {
    if (!slab_arena_slot_value_ok((uintptr_t)cur)) {
      arena_slot_corrupt_halt("slab_drain.loop", sched_current(),
                              (uintptr_t)slot, (uintptr_t)cur);
    }
    slab_arena_chain *next = cur->next;
    for (uint64_t i = 0; i < cur->count; i++) {
      void *chunk = cur->entries[i];
      if (chunk == 0) continue;
      uintptr_t page_base = (uintptr_t)chunk & PAGE_MASK;
      slab_page_header *hdr = (slab_page_header *)page_base;
      uint64_t class_idx = hdr->class_idx;
      if (class_idx >= SLAB_NUM_CLASSES) continue;
      int slot_idx = slab_slot_idx_for((uintptr_t)chunk, page_base,
                                       (size_t)hdr->chunk_size);
      slab_bitmap_clear(hdr, slot_idx);
      slab_class *cls = &g_slab_classes[class_idx];
      *(void **)chunk = cls->freelist;
      cls->freelist = chunk;
      cls->frees++;
      g_slab_arena_released++;
    }
    slab_arena_chain_release(cur);
    cur = next;
  }
  *slot = 0;
}

unsigned long libc_arena_stat(int field) {
  uintptr_t *slot = current_arena_slot();
  switch (field) {
    case 0: return g_arena_begins;
    case 1: return g_arena_ends;
    case 2: return g_arena_released;
    case 3: return (slot != 0 && *slot != 0) ? 1UL : 0UL;
    case 4: return g_slab_arena_tracked;
    case 5: return g_slab_arena_released;
    case 6: return g_slab_arena_chain_pages;
    default: return 0;
  }
}

// KERN.SLAB.2 — arena-slot value validators. The local repro of
// `arena_drain+0x4a` #GP on 2026-05-28 had TASK_ARENA_HEAD set to a
// .rodata address (the effect-name string `tcp_stream_scoped`). Reading
// `cur->next` from a .rodata ptr returns ASCII bytes interpreted as a
// pointer → non-canonical → #GP TWO iterations later, far from the
// corruption. Worse, the FIRST iteration writes through the .rodata ptr
// (cur->size &= ~1) and pushes the .rodata ptr onto the multipage
// freelist — silently corrupting future allocations.
//
// These predicates catch the cascade at the moment of detection. Halt
// path uses dbg_puts (matches the [SLAB-CORRUPT] pattern at slab_alloc).
// See feedback_kern_slab_2_redzone_and_arena_drain_gp.md.

// True if v is a legal TASK_ARENA_HEAD value: 0 (inactive), 1 (active
// empty sentinel), or a 16-byte-aligned bump_freenode* in PMM range.
static inline int arena_slot_value_ok(uintptr_t v) {
  if (v == 0) return 1;
  if (v == ARENA_ACTIVE_EMPTY_SENTINEL) return 1;
  if ((v & 0xFULL) != 0) return 0;
  uintptr_t lo = (uintptr_t)get_pmm_pool_start();
  uintptr_t hi = (uintptr_t)get_pmm_pool_end();
  return (v >= lo && v < hi);
}

// True if v is a legal TASK_SLAB_ARENA_HEAD value: 0, or a page-aligned
// slab_arena_chain* in PMM range.
static inline int slab_arena_slot_value_ok(uintptr_t v) {
  if (v == 0) return 1;
  if ((v & (PAGE_SIZE - 1)) != 0) return 0;
  uintptr_t lo = (uintptr_t)get_pmm_pool_start();
  uintptr_t hi = (uintptr_t)get_pmm_pool_end();
  return (v >= lo && v < hi);
}

// Halt loudly with a diagnostic dump when an arena slot value is wild.
// `site` is a static C-string identifier (caller name). Names the wild
// value, the slot address, the owning task, and the PMM range — enough
// for the next session to start ruling in/out write paths.
static void arena_slot_corrupt_halt(const char *site, long task,
                                    uintptr_t slot_addr, uintptr_t value) {
  dbg_puts("\n[ARENA-CORRUPT] site=");
  dbg_puts(site);
  dbg_puts(" task=");
  dbg_put_hex((uintptr_t)task);
  dbg_puts(" slot_addr=");
  dbg_put_hex(slot_addr);
  dbg_puts(" value=");
  dbg_put_hex(value);
  dbg_puts(" pool=[");
  dbg_put_hex((uintptr_t)get_pmm_pool_start());
  dbg_puts(",");
  dbg_put_hex((uintptr_t)get_pmm_pool_end());
  dbg_puts(") begins=");
  dbg_put_dec(g_arena_begins);
  dbg_puts(" ends=");
  dbg_put_dec(g_arena_ends);
  dbg_puts(" released=");
  dbg_put_dec(g_arena_released);
  dbg_putc('\n');
  while (1) { __asm__ volatile ("cli; hlt"); }
}

// KERN.SLAB.2 — write-side barrier for emitted __qz_effect_handle_install.
// Three sessions of evidence point at this path putting the `.rodata` string
// `tcp_stream_scoped` into TASK_ARENA_HEAD: same task, same +0xb8 slot
// offset, same string across three builds. Called from emitted IR right
// before `store i64 %eff_i64, ptr %name_slot, align 8` — validates that
// `name_slot` does NOT land anywhere inside the current task struct.
// If it does, names_base / top / strip-alloc is broken; halt with the
// full diagnostic context so the next session can narrow further.
//
// Skips silently if no runtime task (boot / scheduler-internal context).
void qz_effect_install_alias_check(uintptr_t name_slot, uintptr_t names_base,
                                   uint64_t top, uintptr_t eff_name) {
  if (g_arena_runtime_ready == 0) return;
  long t = sched_current();
  if (t == 0) return;
  uintptr_t task_lo = (uintptr_t)t;
  uintptr_t task_hi = task_lo + TASK_STRUCT_SIZE;
  if (name_slot >= task_lo && name_slot < task_hi) {
    dbg_puts("\n[EFFECT-INSTALL-ALIAS] task=");
    dbg_put_hex(task_lo);
    dbg_puts(" name_slot=");
    dbg_put_hex(name_slot);
    dbg_puts(" task_offset=");
    dbg_put_hex(name_slot - task_lo);
    dbg_puts(" names_base=");
    dbg_put_hex(names_base);
    dbg_puts(" top=");
    dbg_put_dec(top);
    dbg_puts(" eff_name_ptr=");
    dbg_put_hex(eff_name);
    dbg_puts(" pool=[");
    dbg_put_hex((uintptr_t)get_pmm_pool_start());
    dbg_puts(",");
    dbg_put_hex((uintptr_t)get_pmm_pool_end());
    dbg_putc(')');
    dbg_putc('\n');
    while (1) { __asm__ volatile ("cli; hlt"); }
  }
}

// Snapshot of the suspect 7 effect-stack ptr-base slots + TASK_PARK_RV
// for a single task at a given point in time. Call from Quartz code
// right after `task_alloc()` returns to assert task[+88] is 0; halts
// with the wild value if the slot is dirty. This catches whether the
// corruption is in the alloc path (task_free / pool init) or downstream.
void qz_task_alloc_dirty_check(long task) {
  if (g_arena_runtime_ready == 0) return;
  if (task == 0) return;
  uintptr_t t = (uintptr_t)task;
  // The 7 ptr-base slots: 88, 96, 104, 112, 120, 128, 136.
  // Check NAMES (offset 88) first since that's the documented load-bearing
  // assumption (task_effect_strip_alloc's idempotency check + the install
  // path's null-guard both gate on it).
  uint64_t v_names = *(uint64_t *)(t + 88);
  if (v_names != 0) {
    // KERN.SLAB.2 — the 2026-05-28 evidence pattern: slot 88 holds
    // `&task[176]`, slot 96 holds a struct-address into another task,
    // slot 104 holds a return-address inside `task_a_body`. That's
    // stack-frame-shaped data, matching the SLAB.1 burst-race-diag memo.
    // Dump enough context (task id, adjacent stacks, stack_base) for the
    // next session to confirm "stack overflow into adjacent pool" or
    // pivot to another mechanism.
    // task_id is a U32 at offset 40; read it as the low 32 bits of a u64 load.
    uint64_t task_id = (*(uint64_t *)(t + 40)) & 0xFFFFFFFFULL;
    // Path C.5.2 — slot 16 is now TASK_SAVED_STACK_PTR (the parked-frame
    // buffer), not a stack base. For a freshly-alloc'd task it should be 0;
    // a non-zero value here is itself a dirtiness signal worth dumping.
    uint64_t saved_stack_ptr = *(uint64_t *)(t + 16);  // TASK_SAVED_STACK_PTR
    dbg_puts("\n[TASK-ALLOC-DIRTY] task=");
    dbg_put_hex(t);
    dbg_puts(" task_id=");
    dbg_put_dec(task_id);
    dbg_puts(" saved_stack_ptr=");
    dbg_put_hex((uintptr_t)saved_stack_ptr);
    dbg_puts(" slot_88_NAMES=");
    dbg_put_hex((uintptr_t)v_names);
    dbg_puts(" delta_from_task=");
    dbg_put_hex((uintptr_t)v_names - t);
    dbg_puts(" handlers_96=");
    dbg_put_hex((uintptr_t)*(uint64_t *)(t + 96));
    dbg_puts(" bufs_104=");
    dbg_put_hex((uintptr_t)*(uint64_t *)(t + 104));
    dbg_puts(" filters_112=");
    dbg_put_hex((uintptr_t)*(uint64_t *)(t + 112));
    dbg_puts(" results_120=");
    dbg_put_hex((uintptr_t)*(uint64_t *)(t + 120));
    dbg_puts(" states_128=");
    dbg_put_hex((uintptr_t)*(uint64_t *)(t + 128));
    dbg_puts(" resumed_136=");
    dbg_put_hex((uintptr_t)*(uint64_t *)(t + 136));
    // Dump the first word of the saved-stack buffer (if any) — for a clean
    // fresh task this is 0; a non-zero buffer ptr with content is a clue.
    if (saved_stack_ptr != 0) {
      dbg_puts(" saved_buf_word0=");
      dbg_put_hex((uintptr_t)*(uint64_t *)saved_stack_ptr);
    }
    dbg_putc('\n');
    while (1) { __asm__ volatile ("cli; hlt"); }
  }
}

// Companion: validate the global `@__qz_effect_stack_names` value at
// save-to-task time. If the global is already wild BEFORE save copies it
// into task[+88], we know the corruption was in the global itself —
// somebody wrote a wild value to the global between the last restore
// and this save. If save NEVER fires but restore DOES, the corruption
// is happening to task[+88] directly via some non-save writer.
void qz_effect_save_names_check(uintptr_t v_names, long task) {
  if (g_arena_runtime_ready == 0) return;
  if (task == 0) return;
  if (v_names == 0) return;
  uintptr_t lo = (uintptr_t)get_pmm_pool_start();
  uintptr_t hi = (uintptr_t)get_pmm_pool_end();
  if (v_names < lo || v_names >= hi || (v_names & (PAGE_SIZE - 1)) != 0) {
    dbg_puts("\n[EFFECT-SAVE-WILD-NAMES] task=");
    dbg_put_hex((uintptr_t)task);
    dbg_puts(" v_names=");
    dbg_put_hex(v_names);
    dbg_puts(" task_lo_aligned=");
    dbg_put_hex((uintptr_t)task & ~(uintptr_t)0xFFFF);
    dbg_puts(" delta_from_task=");
    dbg_put_hex(v_names - (uintptr_t)task);
    dbg_puts(" pool=[");
    dbg_put_hex(lo);
    dbg_puts(",");
    dbg_put_hex(hi);
    dbg_putc(')');
    dbg_putc('\n');
    while (1) { __asm__ volatile ("cli; hlt"); }
  }
}

// Companion: validate `@__qz_effect_stack_names` at restore-from-task time.
// The global is loaded from task[+88]; if THAT slot is wild, the install
// path's `names + top*8` math is wrong from the start. Called from
// emitted __qz_effect_restore_from_task right after `%v_names` is loaded.
// Strip is 4 PMM pages, so a valid names_base is either null (no strip
// yet) or in PMM range and page-aligned.
void qz_effect_restore_names_check(uintptr_t v_names, long task) {
  if (g_arena_runtime_ready == 0) return;
  if (task == 0) return;
  if (v_names == 0) return;  // null = strip not yet alloc'd; legal
  uintptr_t lo = (uintptr_t)get_pmm_pool_start();
  uintptr_t hi = (uintptr_t)get_pmm_pool_end();
  if (v_names < lo || v_names >= hi || (v_names & (PAGE_SIZE - 1)) != 0) {
    dbg_puts("\n[EFFECT-RESTORE-WILD-NAMES] task=");
    dbg_put_hex((uintptr_t)task);
    dbg_puts(" v_names=");
    dbg_put_hex(v_names);
    dbg_puts(" task_slot_88_addr=");
    dbg_put_hex((uintptr_t)task + 88);
    dbg_puts(" pool=[");
    dbg_put_hex(lo);
    dbg_puts(",");
    dbg_put_hex(hi);
    dbg_putc(')');
    dbg_putc('\n');
    while (1) { __asm__ volatile ("cli; hlt"); }
  }
}

// Walk the arena chain and push every entry onto the multi-page freelist.
// Caller already holds (or doesn't need) the slot — we read it fresh and
// zero it. Safe to call when slot == 0 or sentinel (no-op).
static void arena_drain(uintptr_t *slot) {
  uintptr_t encoded = *slot;
  if (!arena_slot_value_ok(encoded)) {
    arena_slot_corrupt_halt("arena_drain.entry", sched_current(),
                            (uintptr_t)slot, encoded);
  }
  if (encoded == 0) return;
  bump_freenode *cur = (encoded == ARENA_ACTIVE_EMPTY_SENTINEL)
                          ? (bump_freenode *)0
                          : (bump_freenode *)encoded;
  while (cur != 0) {
    // Validate each chain node BEFORE deref. Catches the case where a
    // chain `next` field was wild (this is what produced the original
    // #GP — the chain head was .rodata, first iter wrote-back to .rodata
    // + pushed it onto the freelist, second iter dereffed the rodata
    // bytes as a ptr → non-canonical).
    if (!arena_slot_value_ok((uintptr_t)cur)) {
      arena_slot_corrupt_halt("arena_drain.loop", sched_current(),
                              (uintptr_t)slot, (uintptr_t)cur);
    }
    bump_freenode *next = cur->next;
    cur->size &= ~(size_t)1;          // clear arena-owned
    multipage_push_freelist(cur);     // dispatch by page-count bucket
    g_arena_released++;
    cur = next;
  }
  *slot = 0;
}

void qz_arena_begin(void) {
  uintptr_t *slot = current_arena_slot();
  if (slot == 0) return;
  // Stack-overflow canary check. Quartz uk_sched_init writes TASK_STACK_CANARY
  // once at the single active stack's base+0. Stack grows DOWN; if the running
  // task's RSP gets within 8 bytes of overflowing the bottom, the canary is
  // the first word clobbered. This runs once per HTTP request (qz_arena_begin
  // is the per-conn-loop boundary in std/net/http_server.qz), making any
  // future stack-pressure regression LOUD instead of a silent triple-fault.
  // Background: in 5/2026 the 8 KiB per-task stack was exhausted by
  // _http_access_log's interpolation chain; raised to 16 KiB and added
  // this check. See [[feedback-slab1-burst-race-root-cause]].
  // Path C.5.5 — every RUNNING task runs on ITS CPU's active stack, so the
  // canary lives at this CPU's active-stack base (%gs:PCPU_ACTIVE_STACK_BASE),
  // NOT at a per-task slot. (Slot 16 now holds the parked SAVED-stack buffer,
  // 0 while RUNNING — reading it here would always see 0 and skip the check.)
  // sched_current() reads %gs:PCPU_CURRENT_TASK; if it's non-zero a task is
  // running on this CPU, so %gs is valid and ACTIVE_STACK_BASE is populated.
  long cur_task = sched_current();
  if (cur_task != 0) {
    uintptr_t stack_base = (uintptr_t)kern8_gs_load_u64(PCPU_ACTIVE_STACK_BASE);
    if (stack_base != 0) {
      uint64_t observed = *(uint64_t *)stack_base;
      if (observed != TASK_STACK_CANARY) {
        dbg_puts("\n[STACK-OVERFLOW] task=");
        dbg_put_hex((uintptr_t)cur_task);
        dbg_puts(" stack_base=");
        dbg_put_hex(stack_base);
        dbg_puts(" canary_observed=");
        dbg_put_hex(observed);
        dbg_puts(" expected=");
        dbg_put_hex((uintptr_t)TASK_STACK_CANARY);
        dbg_putc('\n');
        while (1) { __asm__ volatile ("cli; hlt"); }
      }
    }
  }
  if (*slot != 0) {
    // Defensive: prior arena_end was skipped (throw unwind). Drain stale
    // chain back to the global freelist before opening a fresh arena so
    // the leak is bounded to one request, not one task lifetime.
    arena_drain(slot);
  }
  // SLAB.1 — also defensively drain any stale slab chain.
  uintptr_t *slab_slot = current_slab_arena_slot();
  if (slab_slot != 0 && *slab_slot != 0) {
    slab_arena_drain(slab_slot);
  }
  *slot = ARENA_ACTIVE_EMPTY_SENTINEL;
  g_arena_begins++;
}

void qz_arena_end(void) {
  uintptr_t *slot = current_arena_slot();
  if (slot == 0) return;
  if (*slot == 0) return;  // no active arena
  arena_drain(slot);
  // SLAB.1 — drain the slab chain too.
  uintptr_t *slab_slot = current_slab_arena_slot();
  if (slab_slot != 0 && *slab_slot != 0) {
    slab_arena_drain(slab_slot);
  }
  g_arena_ends++;
}

// Release the arena chain on `task`'s TASK_ARENA_HEAD slot back to the
// multi-page freelist. Called from task_free to handle the case where a
// task dies mid-arena (throw past arena_end). Does NOT consult
// sched_current() — operates on the explicitly-passed task pointer so
// the call site can run from any context (including the scheduler's
// own task_free path where sched_current may be transient/zero).
void qz_arena_drain_task(long task) {
  if (g_arena_runtime_ready == 0) return;
  if (task == 0) return;
  uintptr_t *slot = (uintptr_t *)(uintptr_t)(task + TASK_ARENA_HEAD);
  arena_drain(slot);
  // SLAB.1 — also drain this task's slab arena chain.
  uintptr_t *slab_slot = (uintptr_t *)(uintptr_t)(task + TASK_SLAB_ARENA_HEAD);
  if (*slab_slot != 0) {
    slab_arena_drain(slab_slot);
  }
}

static void *malloc_pages(size_t want_bytes) {
  g_multipage_allocs++;
  void *payload = (void *)0;
  bump_freenode *chosen = (bump_freenode *)0;

  // Concurrency invariant (Path C.5.5): malloc_pages runs ONLY on the BSP
  // serve path (effect-using HTTP handlers are BSP-pinned — PATH_C §12.1),
  // so the freelist bucket mutation below is effectively single-writer and
  // stays unlocked. The one cross-CPU hazard was the multi-page FRESH bump:
  // APs bump the SHARED g_pmm_next (ss_refill → pmm_alloc_page) concurrently,
  // so the contiguous N-page allocation is taken via pmm_alloc_pages_contig
  // (one g_pmm_lock acquisition) rather than an unlocked per-page loop. If a
  // future change schedules malloc_pages onto an AP, the bucket freelists
  // also need a lock — they are NOT lock-safe today.

  size_t total = want_bytes + BUMP_HEADER_BYTES;
  size_t pages = (total + PAGE_SIZE - 1) / PAGE_SIZE;

  if (pages < MULTIPAGE_MAX_BUCKETS) {
    // O(1) exact-bucket pop. No "scan larger" fallback: that would
    // re-introduce the very fragmentation this scheme exists to fix
    // (a 200-byte alloc grabbing a freed 64-KiB chunk). A larger
    // chunk sitting unused stays in its bucket for the next same-size
    // caller.
    if (g_multipage_buckets[pages] != 0) {
      chosen = g_multipage_buckets[pages];
      g_multipage_buckets[pages] = chosen->next;
      chosen->next = 0;
      g_multipage_recycles++;
    }
  } else {
    // Overflow path — first-fit scan, legacy LIFO policy. Chunks above
    // MULTIPAGE_MAX_BUCKETS pages are rare; this list usually stays
    // empty or tiny in real workloads.
    bump_freenode **prev = &g_multipage_overflow;
    bump_freenode *cur = g_multipage_overflow;
    while (cur != 0) {
      if (bump_capacity_of(cur) >= want_bytes) {
        *prev = cur->next;
        cur->next = 0;
        g_multipage_recycles++;
        chosen = cur;
        break;
      }
      prev = &cur->next;
      cur = cur->next;
    }
  }

  if (chosen == 0) {
    // Freelist miss — bump fresh pages off the PMM cursor.
    //
    // `chosen->size` (set below) spans the WHOLE `pages*PAGE_SIZE` run, so
    // the run MUST be physically contiguous. Under SMP a per-page
    // pmm_alloc_page() loop is NOT safe: an AP bumping g_pmm_next (via
    // ss_refill → pmm_alloc_page) between iterations steals a middle page,
    // leaving this "chunk" overlapping a page already handed to a parked
    // task's saved-stack buffer → frame corruption → wild-RSP on resume
    // (PATH_C_STACK_ON_DEMAND.md §12.8 #2; the [PMM-NONCONTIG] detector
    // below caught this deterministically with the old loop). The fix:
    // pmm_alloc_pages_contig bumps all N pages under a SINGLE g_pmm_lock
    // acquisition, atomic w.r.t. every other PMM consumer.
    if (pages > 1) g_multipage_multi_refills++;
    long base = pmm_alloc_pages_contig((long)pages);
    // Defensive invariant check (kept post-fix — malloc_pages is off the
    // hot per-schedule path, so the cost is negligible). pmm_alloc_pages_contig
    // returns a page-aligned base of N sequential pages; a non-aligned or
    // zero base means the contiguity invariant regressed. Loud-halt rather
    // than hand back a chunk that may overlap live memory.
    if (base == 0 || (base & (long)(PAGE_SIZE - 1)) != 0) {
      dbg_puts("[PMM-NONCONTIG base=");
      dbg_put_hex((uint64_t)base);
      dbg_puts(" pages=");
      dbg_put_dec((uint64_t)pages);
      dbg_puts(" — contig bump returned bad base]\n");
      while (1) { __asm__ volatile ("cli; hlt"); }
    }
    chosen = (bump_freenode *)(uintptr_t)base;
    // Record the FULL capacity of the bump-rounded allocation, not just
    // `want_bytes`, so the bucket dispatch on free reaches the right
    // page-count bucket and any in-place realloc up to the rounded size
    // stays free.
    chosen->size = pages * PAGE_SIZE - BUMP_HEADER_BYTES;
    chosen->next = 0;
    g_multipage_refills++;
  }

  payload = (void *)(uintptr_t)((unsigned char *)chosen + BUMP_HEADER_BYTES);

  // If the calling task has an arena open, link this chunk onto the arena
  // chain and mark the size header as arena-owned so free() is a no-op
  // until arena_end releases the whole chain. Must run AFTER the freelist
  // pop / fresh-PMM init so `chosen->next` / `chosen->size` are fully set.
  uintptr_t *slot = current_arena_slot();
  if (slot != 0 && *slot != 0) {
    uintptr_t encoded = *slot;
    // KERN.SLAB.2 — validate before treating encoded as a chain head.
    // Without this, a wild `encoded` (e.g. the .rodata ptr seen on
    // 2026-05-28) would be linked into via `chosen->next = head`,
    // re-amplifying the corruption.
    if (!arena_slot_value_ok(encoded)) {
      arena_slot_corrupt_halt("malloc_pages.link", sched_current(),
                              (uintptr_t)slot, encoded);
    }
    bump_freenode *head = (encoded == ARENA_ACTIVE_EMPTY_SENTINEL)
                            ? (bump_freenode *)0
                            : (bump_freenode *)encoded;
    chosen->next = head;
    chosen->size |= (size_t)1;
    *slot = (uintptr_t)chosen;
  }

  return payload;
}

static size_t multi_page_size(void *p) {
  bump_freenode *hdr = (bump_freenode *)((unsigned char *)p - BUMP_HEADER_BYTES);
  return bump_capacity_of(hdr);
}

static void multi_page_free(void *p) {
  bump_freenode *hdr = (bump_freenode *)((unsigned char *)p - BUMP_HEADER_BYTES);
  if (bump_is_arena_owned(hdr)) {
    // Arena owns this chunk; arena_end will release it. Don't push onto
    // the freelist (would double-list and corrupt either link).
    return;
  }
  g_multipage_frees++;
  multipage_push_freelist(hdr);
}

// ============================================================================
// libc shim: malloc / free / realloc dispatching across the two tiers
// ============================================================================

void *malloc(size_t n) {
  if (n == 0) {
    n = 1;
  }
  if (n <= SLAB_CLASS_SIZES[SLAB_NUM_CLASSES - 1]) {
    void *p = slab_alloc(n);
    if (p != 0) return p;
    // slab refill failed (PMM exhausted via the slab path); fall
    // through to multi-page so the kernel hits a single OOM site.
  }
  return malloc_pages(n);
}

void free(void *p) {
  if (p == 0) return;
  if (slab_owns(p)) {
    slab_free(p);
    return;
  }
  // Multi-page chunk — push onto the freelist for future reuse.
  // See the freelist header comment above malloc_pages for rationale.
  multi_page_free(p);
}

void *realloc(void *p, size_t n) {
  if (p == 0) {
    return malloc(n);
  }
  if (n == 0) {
    // Standard C says behavior is impl-defined. Keep the allocation
    // alive but hand back the same pointer.
    return p;
  }
  size_t old;
  int from_slab = slab_owns(p);
  if (from_slab) {
    old = slab_chunk_size(p);
    if (n <= old) {
      return p; // shrink-or-equal stays in the same chunk
    }
  } else {
    old = multi_page_size(p);
    if (old >= n) {
      return p;
    }
  }
  // Grow: fresh allocation + byte copy + drop the old.
  void *q = malloc(n);
  if (q == 0) {
    return 0;
  }
  unsigned char *dst = (unsigned char *)q;
  unsigned char *src = (unsigned char *)p;
  size_t copy = old < n ? old : n;
  for (size_t i = 0; i < copy; i++) {
    dst[i] = src[i];
  }
  free(p);
  return q;
}

// calloc: malloc + zero. Required by KaRaMeL's runtime helpers
// (`KRML_HOST_CALLOC`) for the streaming-incremental crypto state
// allocators. The WireGuard primitive subset doesn't actually call
// the streaming APIs (one-shot AEAD only), but the symbols still need
// to resolve at link time before dead-strip drops them.
void *calloc(size_t nmemb, size_t size) {
  size_t total = nmemb * size;
  void *p = malloc(total);
  if (p == 0) {
    return 0;
  }
  unsigned char *dst = (unsigned char *)p;
  for (size_t i = 0; i < total; i++) {
    dst[i] = 0;
  }
  return p;
}

// ============================================================================
// Boot-time slab smoke test
// ============================================================================

// Returns the number of passing checks (out of a fixed total). Caller
// (kernel main) prints `SLAB ok/total` to serial. Each phase exercises
// a different invariant:
//
//   1. Single alloc/free round-trip on every class — proves refill +
//      basic alloc + free + class-size accounting all work.
//   2. LIFO ordering — after free(a); free(b); free(c), the next three
//      allocs return c, b, a in that order.
//   3. Class-boundary picks — bytes=15, 16, 17, 511, 512, 513 land in
//      classes 0, 0, 1, 5, 5, multi-page respectively.
//
// Total passing count: 6 (round-trip) + 3 (LIFO) + 6 (boundaries) = 15.
int slab_smoke(void) {
  int ok = 0;
  // (1) Round-trip per class — alloc, write a marker into the chunk's
  // first byte, verify the marker, free, re-alloc same class and
  // verify we got the same address back (LIFO single-element case).
  for (int i = 0; i < SLAB_NUM_CLASSES; i++) {
    size_t sz = SLAB_CLASS_SIZES[i];
    unsigned char *p = (unsigned char *)slab_alloc(sz);
    if (p == 0) continue;
    p[0] = 0xAB;
    if (p[0] == 0xAB && slab_owns(p) && slab_chunk_size(p) == sz) {
      ok++;
    }
    slab_free(p);
  }

  // (2) LIFO ordering — three allocs of class 0, then three frees in
  // order, then three re-allocs should reverse the original order.
  void *a = slab_alloc(16);
  void *b = slab_alloc(16);
  void *c = slab_alloc(16);
  slab_free(a);
  slab_free(b);
  slab_free(c);
  void *r1 = slab_alloc(16);
  void *r2 = slab_alloc(16);
  void *r3 = slab_alloc(16);
  if (r1 == c) ok++;
  if (r2 == b) ok++;
  if (r3 == a) ok++;
  slab_free(r1);
  slab_free(r2);
  slab_free(r3);

  // (3) Class boundary picks — verify slab_class_idx_for routing for
  // edge sizes, and that multi-page handles 513 B without slab
  // claiming ownership.
  if (slab_class_idx_for(15) == 0) ok++;
  if (slab_class_idx_for(16) == 0) ok++;
  if (slab_class_idx_for(17) == 1) ok++;
  if (slab_class_idx_for(511) == 5) ok++;
  if (slab_class_idx_for(512) == 5) ok++;
  void *big = malloc(513);
  if (big != 0 && slab_owns(big) == 0) ok++;
  free(big);

  return ok;
}

// ============================================================================
// Plain mem helpers (libc shim)
// ============================================================================

void *memcpy(void *d, const void *s, size_t n) {
  unsigned char *dst = (unsigned char *)d;
  const unsigned char *src = (const unsigned char *)s;
  for (size_t i = 0; i < n; i++) {
    dst[i] = src[i];
  }
  return d;
}

void *memset(void *d, int v, size_t n) {
  unsigned char *dst = (unsigned char *)d;
  unsigned char b = (unsigned char)v;
  for (size_t i = 0; i < n; i++) {
    dst[i] = b;
  }
  return d;
}

// D.11 Phase 8b.2.b — libc string helpers used by http_server.qz
// transitive imports (Quartz prelude's @qz_str_eq → @memcmp,
// @qz_str_split_impl → @strstr, etc.). Trivial pure-C bodies; no
// syscalls. Match the signatures declared by the freestanding
// branch of cg_emit_runtime_decls.

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *pa = (const unsigned char *)a;
  const unsigned char *pb = (const unsigned char *)b;
  for (size_t i = 0; i < n; i++) {
    if (pa[i] != pb[i]) {
      return (int)pa[i] - (int)pb[i];
    }
  }
  return 0;
}

size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n] != '\0') n++;
  return n;
}

int strcmp(const char *a, const char *b) {
  size_t i = 0;
  while (a[i] != '\0' && a[i] == b[i]) i++;
  return (int)(unsigned char)a[i] - (int)(unsigned char)b[i];
}

// Returns first occurrence of `needle` in `haystack` or NULL. Naive
// O(n*m) search. HTTP parsing uses this for header field lookups.
char *strstr(const char *haystack, const char *needle) {
  if (needle[0] == '\0') return (char *)haystack;
  for (size_t i = 0; haystack[i] != '\0'; i++) {
    size_t j = 0;
    while (needle[j] != '\0' && haystack[i + j] == needle[j]) j++;
    if (needle[j] == '\0') return (char *)(haystack + i);
  }
  return (void *)0;
}

char *strncpy(char *dst, const char *src, size_t n) {
  size_t i = 0;
  while (i < n && src[i] != '\0') {
    dst[i] = src[i];
    i++;
  }
  while (i < n) {
    dst[i] = '\0';
    i++;
  }
  return dst;
}

char *strcpy(char *dst, const char *src) {
  size_t i = 0;
  while (src[i] != '\0') {
    dst[i] = src[i];
    i++;
  }
  dst[i] = '\0';
  return dst;
}

// qsort stays as a no-op — kernel code doesn't sort on startup and
// writing a real qsort here isn't K.1 work. When something actually
// needs it we'll wire a Quartz-side sort.
void qsort(void *base, size_t nmemb, size_t size,
           int (*cmp)(const void *, const void *)) {
  (void)base;
  (void)nmemb;
  (void)size;
  (void)cmp;
}

// ============================================================================
// time(2) / gettimeofday(2) — RDTSC-derived monotonic stubs.
// ============================================================================
//
// Used by std/net/wireguard/handshake.qz::wg_tai64n_now to populate the
// 12-byte TAI64N watermark in MSG_INITIATION. WG cares about monotonicity
// across handshakes from the same initiator (replay defense, paper §5.4.4)
// — the receiver compares byte-wise BE, so any strictly-increasing
// 12-byte sequence works. Wall-clock fidelity is not required.
//
// On the bare-metal unikernel there is no `time` syscall; we synthesize
// monotonicity from RDTSC. The TSC starts at boot (or a hypervisor-reset
// value) and ticks at the CPU's nominal frequency — for our purposes a
// fixed pretend frequency (1 GHz) gives "seconds" that increase fast
// enough to never repeat within a session. This is wrong for displaying
// a real time, but right for WG's invariant: subsequent calls return
// strictly increasing values.

struct __qz_timeval { long tv_sec; long tv_usec; };

static inline uint64_t __qz_rdtsc(void) {
  // __builtin_ia32_rdtsc is provided by clang/gcc in <x86intrin.h>, but
  // including it pulls in too much under -ffreestanding. The builtin is
  // available without the header.
  return (uint64_t)__builtin_ia32_rdtsc();
}

// Pretend the TSC ticks at 1 GHz. Real TSC frequencies on QEMU TCG are
// ~2-3 GHz; for monotonic-only consumers the actual ratio is irrelevant.
#define __QZ_TSC_PER_SEC 1000000000ULL
#define __QZ_TSC_PER_USEC 1000ULL

long time(long *t) {
  long s = (long)(__qz_rdtsc() / __QZ_TSC_PER_SEC);
  if (t) *t = s;
  return s;
}

int gettimeofday(struct __qz_timeval *tv, void *tz) {
  (void)tz;
  if (!tv) return -1;
  uint64_t now = __qz_rdtsc();
  tv->tv_sec  = (long)(now / __QZ_TSC_PER_SEC);
  tv->tv_usec = (long)((now / __QZ_TSC_PER_USEC) % 1000000ULL);
  return 0;
}

// ============================================================================
// KERN.8 K8.2 — per-CPU state via GS-base
// ============================================================================
//
// In long mode, segment selectors do NOT determine GS-base; the
// IA32_GS_BASE MSR (0xC0000101) does directly. Each CPU writes its
// own per-CPU page address into IA32_GS_BASE during init, then
// `mov %gs:N, %rax` reads/writes land in that page at offset N.
// Quartz can write the MSR via its `wrmsr` intrinsic but doesn't
// have a way to emit `mov %gs:offset, %rax` parametrically — these
// helpers do the segment override on Quartz's behalf.
//
// Refs: Intel SDM Vol 3 §3.4.4 (segment register usage in 64-bit
// mode), §10.10 (SWAPGS). docs/design/KERN_8_SMP.md decision D2.

uint64_t kern8_gs_load_u64(uint64_t offset) {
  uint64_t v;
  __asm__ volatile ("movq %%gs:(%1), %0" : "=r"(v) : "r"(offset));
  return v;
}

void kern8_gs_store_u64(uint64_t offset, uint64_t value) {
  __asm__ volatile ("movq %0, %%gs:(%1)" : : "r"(value), "r"(offset) : "memory");
}

// ============================================================================
// setjmp / longjmp — x86_64 SysV ABI inline asm (D.11 Phase 7 / B.2)
// ============================================================================
//
// Replaces the no-op stubs (`define i32 @setjmp { ret 0 }` and `define
// void @longjmp { unreachable }`) that the freestanding codegen emitted
// through B.1.b. With real setjmp/longjmp wired in, B.3 can replace the
// @__qz_effect_perform stub with the kind=2 (Throws) dispatch — i.e.,
// `throw` from kernel code actually unwinds to the matching with-block's
// handler instead of returning 0 and silently swallowing the throw.
//
// Layout: 8 × 8 B = 64 B. The SysV callee-saved register set
// (rbx, rbp, r12, r13, r14, r15) plus the stack pointer and instruction
// pointer. glibc and musl reserve a 200-B `jmp_buf` array; the
// compiler-emitted alloca for body-wrap jmpbufs matches that size, so
// the unused tail bytes are padding the alloca grants for free.
//
// We do NOT save signal mask state — there are no signals in the kernel,
// so the `_setjmp` (no-sigmask) variant is what we want under both names.
// Hosted programs link against glibc/musl's real setjmp; this file is
// freestanding-only.
//
// References (consulted 2026-05-24):
//   - musl 1.2.5 src/setjmp/x86_64/{setjmp,longjmp}.s
//   - glibc 2.39 sysdeps/x86_64/{setjmp,__longjmp}.S
//   - System V AMD64 ABI § 3.2.1 (callee-saved register set)
//
// Aarch64: this file is also fed to `baremetal:verify_hello_aarch64`,
// but that target has been broken on rdtsc (line 464, `__builtin_ia32_rdtsc`,
// x86-only) since commit 31dd4ff4 (NET.1 Phase 1, Step 2.5; 2026-05-08).
// The `#if defined(__x86_64__)` gate below makes sure B.2 doesn't widen
// that pre-existing break — once rdtsc is gated, a parallel aarch64
// setjmp/longjmp can land here.

#if defined(__x86_64__)

// ============================================================================
// __qz_invoke_closure — dispatch a Quartz closure value (tag-bit encoding)
// to its underlying function, for kernel-side spawn of stdlib closures
// (kern_go_closure, http_dyn_gsup_spawn_one freestanding variant).
//
// Quartz closure ABI (see self-hosted/backend/codegen_runtime.qz:4208
// `@__qz_poll_closure` and friends — single source of truth):
//
//   clo: i64
//   if (clo & 1) == 1:
//     // tagged closure
//     env_p   = (void*)(clo & ~1)
//     code_p  = *(i64*)env_p          // first slot of env is fn pointer
//     return code_p(env_p)            // call fn(env)
//   else:
//     // plain (no-capture) function pointer
//     fn_p = (void*)clo
//     return fn_p()                   // call fn()
//
// Used by D.11 Phase 8b followup: freestanding goroutine spawn for
// supervised HTTP per-conn handlers. Without this the supervised loop
// is sequential and Caddy keep-alive monopolizes the listener
// goroutine — see [[feedback-soul7-prod-supervised-hang]].
// ============================================================================
long long __qz_invoke_closure(long long clo) {
  if (clo & 1LL) {
    long long env_i = clo & ~1LL;
    long long *env_p = (long long *)(uintptr_t)env_i;
    long long code_i = *env_p;
    long long (*fn)(long long) = (long long (*)(long long))(uintptr_t)code_i;
    return fn(env_i);
  } else {
    long long (*fn)(void) = (long long (*)(void))(uintptr_t)clo;
    return fn();
  }
}

typedef struct __qz_jmp_buf {
  uint64_t slots[8];  // rbx, rbp, r12, r13, r14, r15, rsp, rip
} __qz_jmp_buf;

// `naked` is mandatory here: a C-wrapped function gets a clang-emitted
// prologue (push %rbp, mov %rsp,%rbp) that displaces the return address
// from the top-of-stack position the asm reads as %rip. musl ships these
// as a pure `.s` file for the same reason; naked + basic-asm body gives
// us the equivalent inside a C TU. Body must contain ONLY basic asm
// (no C statements, no extended-asm constraints, no template
// substitution) — that's the `naked` contract.
//
// Argument convention: SysV ABI puts the first ptr arg in %rdi and the
// second int arg in %esi (= low 32 of %rsi). `movl %esi, %eax` zero-
// extends because x86-64 movl-to-32-bit-dest implicitly zeros the upper
// 32 bits.

__attribute__((naked, returns_twice, nothrow))
int setjmp(__qz_jmp_buf *env) {
  __asm__(
    "movq %rbx, 0(%rdi)\n"
    "movq %rbp, 8(%rdi)\n"
    "movq %r12, 16(%rdi)\n"
    "movq %r13, 24(%rdi)\n"
    "movq %r14, 32(%rdi)\n"
    "movq %r15, 40(%rdi)\n"
    "leaq 8(%rsp), %rax\n"   // caller's rsp = our rsp + 8 (skip our ret addr)
    "movq %rax, 48(%rdi)\n"
    "movq (%rsp), %rax\n"    // caller's rip = the ret addr at top of our frame
    "movq %rax, 56(%rdi)\n"
    "xorl %eax, %eax\n"      // first return = 0
    "retq\n"
  );
}

__attribute__((naked, noreturn, nothrow))
void longjmp(__qz_jmp_buf *env, int val) {
  __asm__(
    "movq 0(%rdi), %rbx\n"
    "movq 8(%rdi), %rbp\n"
    "movq 16(%rdi), %r12\n"
    "movq 24(%rdi), %r13\n"
    "movq 32(%rdi), %r14\n"
    "movq 40(%rdi), %r15\n"
    "movq 48(%rdi), %rsp\n"
    "movl %esi, %eax\n"      // val → eax (= setjmp's second return value)
    "testl %eax, %eax\n"     // longjmp(env, 0) is UB; coerce 0 → 1
    "jnz 1f\n"
    "movl $1, %eax\n"
    "1:\n"
    "jmpq *56(%rdi)\n"       // restore rip — control resumes at setjmp's caller
  );
}

// Boot-time round-trip smoke. Allocates a jmp_buf on its own stack frame,
// setjmp returns 0 → longjmp(env, 7) → setjmp returns 7. Caller (kernel
// main) prints `[B.2] setjmp round-trip 7 ok` on UART when this returns 7.
//
// Kept in C rather than wired as `extern "C" def setjmp(...)` in the
// kernel-side Quartz: Quartz codegen would have to emit `declare i32
// @setjmp(ptr) returns_twice` matching the freestanding bridge's emit, and
// inline a Quartz call across a returns_twice boundary that would also
// need llvm.frameaddress / stacksave guards in the right order. Doing it
// in C is one isolated frame with the right calling convention by
// construction.
int setjmp_longjmp_smoke(void) {
  __qz_jmp_buf env;
  int rc = setjmp(&env);
  if (rc == 0) {
    longjmp(&env, 7);
  }
  return rc;
}

#else

// Aarch64 (and any future freestanding target) — placeholder so the
// linker is satisfied if the smoke is referenced from a build that
// somehow links this file without the x86_64 gate. The kernel-side
// smoke caller only invokes setjmp_longjmp_smoke() from the x86_64
// build path, so this is defensive only.
int setjmp_longjmp_smoke(void) { return 0; }

#endif // __x86_64__
