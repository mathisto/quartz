# Binary DSL — `binary {}` blocks and `packed struct(uN)`

Status: **Shipped** (Apr 2026) — Phases 1, 1.5, 2 landed (`packed struct(uN)` named bit-fields, `.with{}`, `as`-bitcast, width-sum check; 19 passing specs). LSB-first toggle (decision #6) remains deferred; the B.10 value-types epic is its first consumer.
Companions: [`BYTES.md`](BYTES.md) (the underlying `Bytes` buffer type).

## Relationship to `Bytes`

`Bytes` is the runtime byte buffer (defined in `BYTES.md`). `binary {}` is a typed layout description that operates *on* `Bytes`. The two are orthogonal: `Bytes` doesn't know about layouts, and `binary {}` types don't replace `Bytes` — they decode from it and encode to it.

The mental model:

```
Bytes  ──── IPv4Header.decode(bytes) ────► Result<IPv4Header, ParseError>
                                              │
                                       (typed value)
                                              │
Bytes  ◄──── header.encode() ──────────  IPv4Header { ... }
```

`IPv4Header` is a *type*. Constructing one (`IPv4Header { ... }`) gives you a typed value, not bytes. To get bytes you call `.encode()`. To parse, `Type.decode(bytes)` returns a `Result`.

## Goals

Make binary data a first-class citizen in Quartz so that protocols, file formats, hardware register layouts, and the compiler's own struct codegen are all expressed in one declarative, bidirectional, optimizer-friendly syntax. Sets up future formal verification (Nail-style structural bijection) without committing to it now.

## Two constructs, one philosophy

These are intentionally separate. They solve different problems.

| Construct | For | Reads/writes | Layout |
|---|---|---|---|
| `binary { ... }` | **Streams** — network protocols, file formats, encoded messages | Stream-positional; fields can be any width incl. sub-byte; can include length-prefixed `bytes` and `rest` | Sequential bit packing |
| `packed struct(uN) { ... }` | **Register layouts** — MMIO, MCU peripheral configs, bitfields with a fixed total width | Whole-word load/store, atomic when N ≤ machine word | Fixed-width backing integer, fields fit inside |

A `binary {}` block describes **how to read or write a sequence of bits**. A `packed struct(u32)` describes **how a single 32-bit value is internally laid out**. They look similar; they are not the same thing.

## Type vocabulary

```
Byte-aligned      Sub-byte (binary/packed only)   Float
u8,  i8           u1..u7                          f32le, f32be
u16le, u16be      i1..i7                          f64le, f64be
u32le, u32be
u64le, u64be      Stream tail (binary only)       Strings (binary only)
i16le, i16be      bytes(n)     — exactly n bytes  cstring        — null-terminated
i32le, i32be      bytes        — rest of stream   pstring(u8)    — u8-length-prefixed
i64le, i64be      [T; n]       — fixed-len array  pstring(u16le) — u16-length-prefixed
                  [T; field]   — count-prefixed   pstring(u32le) — u32-length-prefixed
                  [T]          — rest-of-stream
```

**No `native`-endian variants.** Every field is explicitly `le` or `be`. Native is a footgun that hides cross-compilation bugs.

**No struct-level endianness default.** `binary(be) { width: u32 }` was considered and rejected — too much sugar for too little juice. Each multi-byte field carries its own suffix.

**Sub-byte types are only legal inside `binary {}` and `packed struct(uN)` blocks.** A top-level `var x: u4` is a type error. Erlang and Zig both made this restriction; we follow.

## Arrays of binary types

Inside `binary {}` blocks, arrays use square-bracket syntax (no `array` keyword) — disambiguated from list literals by context (always inside a `binary {}` field type position).

```be
fixed:    [AudioSample; 256]      # exactly 256 elements
variable: [Entry; count]          # length from a prior field named `count`
rest:     [Entry]                 # consume to end of stream
```

Semicolon separates element type from count (matches Rust). The `count` form is the most common real-world pattern and is the entire reason length-prefixed formats exist.

## Worked examples

### 1. IPv4 header (network protocol)

```be
type IPv4Header = binary {
  version:    u4
  ihl:        u4         # internet header length in 32-bit words
  tos:        u8
  total:      u16be
  id:         u16be
  flags:      u3
  frag_off:   u13be
  ttl:        u8
  proto:      u8
  checksum:   u16be
  src:        u32be
  dst:        u32be
  payload:    bytes
}

# Parse — explicit Result, errors visible
match IPv4Header.decode(incoming)
  Ok(IPv4Header { proto: 6, src, dst, payload, .. }) => tcp_handle(src, dst, payload)
  Ok(IPv4Header { proto: 17, src, dst, payload, .. }) => udp_handle(src, dst, payload)
  Ok(_) => drop()
  Err(e) => log_parse_error(e)
end

# Construct — same syntax as struct literal, produces typed value
header = IPv4Header {
  version: 4, ihl: 5, tos: 0,
  total: 1500, id: 0x1234,
  flags: 0b010, frag_off: 0,
  # Phase 1: compute checksum manually before construction.
  # Phase 2 (computed fields) will declare this declaratively.
  ttl: 64, proto: 6, checksum: ipv4_checksum(...),
  src: my_ip, dst: peer_ip,
  payload: tcp_segment,
}
bytes = header.encode()           # Bytes, ready for the wire
```

### 2. Bluetooth LE advertising PDU header (sub-byte heavy)

```be
type BleAdvHeader = binary {
  pdu_type:  u4
  rfu:       u2          # reserved for future use
  tx_addr:   u1
  rx_addr:   u1
  length:    u8
}
```

Eight bits of header carry four logical fields. Today's compiler-bookkeeping in Quartz hides this with bit shifts; `binary {}` makes it readable and verifiable.

### 3. STM32 GPIO MODER register (microcontroller register layout)

```be
packed struct(u32) GpioModer
  pin0_mode:  2          # 00=input, 01=output, 10=alt, 11=analog
  pin1_mode:  2
  pin2_mode:  2
  pin3_mode:  2
  pin4_mode:  2
  pin5_mode:  2
  pin6_mode:  2
  pin7_mode:  2
  pin8_mode:  2
  pin9_mode:  2
  pin10_mode: 2
  pin11_mode: 2
  pin12_mode: 2
  pin13_mode: 2
  pin14_mode: 2
  pin15_mode: 2
end

# Bare integer widths because backing type (u32) already says "32 bits total".
# The compiler verifies the widths sum to exactly 32 and emits a layout check.

# Use — mutating path (var) for typical MMIO RMW
var moder = volatile_load_u32(GPIOA_MODER_ADDR) as GpioModer
moder.pin5_mode = 0b01           # register-level shift+mask+or, no memory access
moder.pin6_mode = 0b01           # still in register
volatile_store_u32(GPIOA_MODER_ADDR, moder as u32)   # one store

# Use — immutable path (let) with `with` block for derived configs
let base = default_moder_config
let configured = base.with {
  pin5_mode = 0b01
  pin6_mode = 0b01
}
volatile_store_u32(GPIOA_MODER_ADDR, configured as u32)
```

Field assignment is gated by Quartz's normal const/var rule: `var moder.field = X` mutates in place; `let moder` requires the `.with { ... }` block form to derive a new value. Both compile to the same shift+mask+or sequence — register-level only, no memory round-trip between consecutive field updates. The memory access happens at `volatile_store`.

The `as` operator is a typed bitcast between a `packed struct(uN)` and its backing integer `uN` (and vice versa). Strict, compile-time-checked — no widening, no narrowing, no implicit conversion. Zero runtime cost (just a type-level reinterpret).

### Padding rule (worked example with friendly error)

Total field widths must sum to a multiple of 8 bits. The compiler errors at definition time if not. Use a leading-underscore field name to declare an explicit pad slot:

```be
type BadAlignment = binary {
  flags: u4
  count: u3                # 4 + 3 = 7 bits → COMPILE ERROR
}

# Friendly error (planned):
# error[QZ0950]: binary {} block 'BadAlignment' is 7 bits — not byte-aligned.
#   --> example.qz:2:14
#    |
#  2 | type BadAlignment = binary {
#    |              ^^^^
#    | total field width must be a multiple of 8.
#    | tip: add a pad field — `_: u1` — to round up to 8 bits.
#    | or change `count` to `u4` if that's the real width.

type GoodAlignment = binary {
  flags: u4
  count: u3
  _:     u1                # explicit pad — name `_` means "ignored"
}
```

### 4. PNG IHDR chunk (file format header with mixed widths)

```be
type PngIhdr = binary {
  width:       u32be
  height:      u32be
  bit_depth:   u8         # 1, 2, 4, 8, or 16
  color_type:  u8         # 0, 2, 3, 4, or 6
  compression: u8         # always 0
  filter:      u8         # always 0
  interlace:  u8         # 0 or 1
}

# Parse usage
match PngIhdr.decode(chunk_bytes)
  Ok(PngIhdr { width, height, bit_depth, .. }) => allocate_image(width, height, bit_depth)
  Err(e) => return PngError::InvalidIhdr(e)
end
```

Demonstrates the cross-platform value: PNG is big-endian on disk regardless of host, so `u32be` is correct everywhere; `u32` (host-endian) would be a portability bug.

### 5. Dogfooding example — Quartz intmap header

```be
# Currently in cg_intrinsic_intmap.qz: a series of getelementptr loads.
# After binary DSL — typed, named, regenerable.
type IntMapHeader = binary {
  cap:    u64le        # Quartz runtime is little-endian on supported platforms
  len:    u64le
  keys:   u64le        # ptr stored as u64
  vals:   u64le        # ptr stored as u64
  used:   u64le        # ptr to bitmap
}

# In codegen — same `decode()` API as everything else:
match IntMapHeader.decode(Bytes.from_ptr(hdr_ptr, 40))
  Ok(IntMapHeader { keys, .. }) => emit_load(keys, idx)
  Err(_) => panic("intmap header corrupted")  # internal invariant; can't happen
end
# vs. today's `getelementptr i64, ptr %hdr, i64 2`
```

The compiler's own struct emission becomes readable. This is the dogfooding test: if `binary {}` is good enough to replace `cg_intrinsic_intmap.qz`'s manual offset arithmetic, it's good enough to ship.

## MIR opcodes

Three new MIR instructions plus a layout-aware codegen pass:

- **`MIR_BINARY_PACK`** — `(layout_id, field_values...) -> Bytes` — emit a serialized representation of the named binary type from scalar fields. Backs `.encode()`.
- **`MIR_BINARY_UNPACK`** — `(layout_id, Bytes) -> Result<(field_values...), ParseError>` — destructure bytes into scalar fields per the named layout. Backs `.decode()`.
- **`MIR_PACKED_BITCAST`** — `(layout_id, integer | layout) -> (layout | integer)` — zero-cost reinterpret between a `packed struct(uN)` and its backing integer. Backs the `as` operator.

Layouts are registered in MIR with a numeric ID; the codegen pass looks up the layout and emits straight-line shift/mask sequences. Adjacent byte-aligned fields fuse into single loads — e.g., `u32be` followed by `u32be` becomes one i64 load + one bswap + two extracts, not two i32 loads.

**Cursor semantics.** `MIR_BINARY_UNPACK` always parses starting at byte 0 of the input `Bytes`. To parse at an offset, the user slices first: `IPv4Header.decode(packet.slice(14, 34))` to skip the Ethernet header. There is no implicit cursor argument; this keeps the opcode signature small and the parsing model trivially composable.

## Pipeline placement

**Surface syntax → typecheck → MIR → codegen.** The block desugars *into* the new MIR opcodes, **not** into existing intrinsics. Reasons:

1. **Codegen quality.** Fusing 4-bit + 4-bit + 8-bit + 16-bit into one i32 load needs a structured view of the layout. Desugaring to `mask`/`or` calls throws that view away.
2. **Bidirectionality.** One MIR layout-id emits both `pack` and `unpack`. Desugaring forces two separate codepaths to stay in sync — exactly the bug Nail was designed to prevent.
3. **Future formal verification.** A structured layout is reasonable to verify; a desugared pile of int ops is not.

Heavier upfront. The right call.

## Phasing

### Phase 1 — Foundation (the overnight implementation target)

| Deliverable | Approx scope |
|---|---|
| Surface syntax: `binary {}` blocks, `packed struct(uN)`, type vocabulary in this doc | parser + AST |
| MIR opcodes: `MIR_BINARY_PACK`, `MIR_BINARY_UNPACK`, `MIR_PACKED_BITCAST` | mir.qz |
| Codegen with adjacent-field fusion (single i32 load + N shifts, not N i32 loads) | new file: `cg_intrinsic_binary.qz` |
| `Result<T, ParseError>` integration; structured errors | typecheck + mir |
| Compile-time width-sum check, friendly padding error | typecheck |
| Phase 1 string types: `bytes(n)`, `cstring`, `pstring(uN)` | codegen |
| Zero-copy rest-of-stream via `Bytes` slicing | runtime |
| QSpec coverage for all 5 worked examples | spec/qspec/binary_*_spec.qz |

Approx total: ~1500 lines, multi-session.

### Phase 2 — Bidirectionality + missing semantics

| Deliverable | Why it's v2 |
|---|---|
| Bijection enforcement — `unpack(pack(x)) == x` proven structurally (Nail-style, no SAT solver) | Needs Phase 1 stable first |
| **Computed fields** — `value: u16be = checksum(payload)` declarative checksum/length-from-prior-field | Common in TCP/UDP/PNG/gzip |
| **Discriminated unions inside `binary {}`** — `match`-driven dispatch on a discriminator field for TLV-shaped formats | Required for TCP options, ELF sections, PE chunks, USB descriptors |
| **UTF-8-aware string types** — `utf8(n)`, `pstring_utf8(uN)` with codepoint validation at parse time | `cstring`/`pstring` only handle bytes in Phase 1 |
| **Versioning / multi-format dispatch** — composable from discriminated unions above | Common in protocol design (TLS records, DNS queries) |
| **Per-field `lsb` annotation implementation** | Locked in design (#6); deferred from Phase 1 because no current consumer needs it |

### Phase 3 — Dogfood

Migrate compiler internals to use the DSL: intmap header, channel layout, Future state machines, MIR-instruction encoding, AST-node layout. Mechanical work spread over multiple sessions. Gates on Phase 1 + Phase 2 being stable.

### Phase 4 — Tooling

| Deliverable | Why |
|---|---|
| `quartz binary --dump-layout TypeName` — visual bit layout printer | Format authoring + debugging |
| LSP hover support for binary fields — show bit offset, width, endianness on hover | Editor integration |
| Hex viewer integration — given a `Bytes` and a `binary {}` type, highlight which bytes correspond to which field | Reverse engineering / debugging real-world formats |

### Phase 5 *(moonshot)* — Formal verification

Refinement types or a proof-carrying-code backend for full formal verification of parsers. Years out, separate type-system extension. Phase 2's bijection check is the structural foundation.

## Out of scope — permanent non-goals

- **Native-endian as a type.** Always specify `le` or `be`. Type alias in user code if really needed.
- **Sub-byte types outside `binary {}` / `packed struct(uN)`.** A top-level `u4` is meaningless without a containing block to define the bit position.
- **Compatibility with other languages' DSLs.** This is Quartz-shaped. Kaitai files won't import. By design — we get pattern-matching integration in exchange.
- **Struct-level endianness default** (`binary(be) {}` sugar). Considered, rejected — too much sugar for too little juice.

(Phase 2-5 deferred items are *not* in this list — they are tracked in the Phasing section above as planned work.)

## Locked design decisions

Recorded for posterity so future revisions know what was chosen and why.

| # | Question | Decision | Rationale |
|---|---|---|---|
| 1 | Default endianness | Always explicit per multi-byte field. No struct-level default. | Matches "no native" decision; mixed-endian formats are common; 2 chars per field is cheap insurance. The struct-level default sugar (`binary(be) {}`) was considered and rejected as not-enough-juice. |
| 2 | Sub-byte total width | Total of all field widths must be a multiple of 8. Pad explicitly with `_: uN`. Friendly compile-time error otherwise. | Implicit padding hides serialization bugs. `_` pad slot is self-documenting and matches existing wildcard-binding idioms. |
| 3 | Nested binary types and arrays | Yes to nesting. Yes to fixed-length, count-prefixed, and rest-of-stream arrays. Square-bracket syntax — `[T; n]`, `[T; field]`, `[T]` — no `array` keyword needed. | Composing protocols is non-negotiable. Square brackets read as "an array of" in every modern language. Inside `binary {}` field positions there's no ambiguity with list literals. |
| 4 | `packed struct(uN)` field assignment | Both mutating (`.field = X`) on `var` bindings, and immutable `.with(field = X)` on `let` bindings. Same const/var rule as regular structs. | Reuses Quartz's existing const-by-default story — no new mental model. `var` users get familiar imperative ergonomics; `let` users get composable functional updates. Both compile to identical shift+mask+or in registers. |
| 5 | Parse error model | `Result<T, ParseError>` with structured error enum: `UnexpectedEof`, `InvalidValue { field, expected, got }`, `LengthOverflow`. | Errors-as-values composes with existing Result machinery; no panics in the hot path; `match` integration falls out for free. |
| 6 | Bit order within bytes | MSB-first by default. Per-field `lsb` annotation when needed (rare — DSP, some USB descriptors). | Network protocols and the overwhelming majority of formats are MSB-first. Most users will never need to know this question exists. |
| 7 | Multi-byte field misalignment after sub-byte | **Compile error.** "Multi-byte field `X` starts at bit Y; insert a `_: uN` pad to byte-align." | Reasonable formats are byte-aligned anyway. The slow shift-out sequence hides perf bugs from users who don't know they're paying for it. Force the explicit pad. |
| 8 | Phase 1 string vocabulary | `bytes(n)`, `cstring`, `pstring(u8)`, `pstring(u16le)`, `pstring(u32le)`. UTF-8-aware strings deferred to Phase 2 (see roadmap). | Covers 95% of file/protocol formats. UTF-8 awareness needs codepoint-level decoding which is a separate concern from layout. |
| 9 | Rest-of-stream `bytes` and `[T]` ownership | Zero-copy by default — references into the input buffer. `Bytes` type gains an internal owned/borrowed flag (one extra pointer in the header) and an `.into_owned()` method that clones if borrowed. Phase 1 implementation; Phase 2 may evolve to a separate `BytesSlice` type once Quartz's lifetime story matures. | Essential for systems work and microcontrollers. Erlang's sub-binary references prove this works. The owned/borrowed flag avoids introducing a lifetime-bearing type before the broader lifetime system is ready. |
| 10 | `binary {}` ↔ `Bytes` boundary | `IPv4Header { ... }` constructs a typed value. `.encode()` on the value returns `Bytes`. `IPv4Header.decode(bytes)` returns `Result<IPv4Header, ParseError>`. No implicit parse-in-match. | Typed value stays inspectable and mutable; serialization is an explicit step; parse failures are visible in the type system. |
| 11 | `.with` syntax for packed-struct immutable update | Block form: `moder.with { pin5_mode = 0b01; pin6_mode = 0b01 }`. Single call, multiple fields, no new keyword-argument language feature needed. | Quartz lacks keyword arguments; per-field methods would explode the API surface. Block form composes one allocation per derivation. |
| 12 | `as` operator for packed struct ↔ integer | `as` is a typed bitcast operator strictly between a `packed struct(uN)` and its backing integer `uN` (and vice versa). Compile-time-checked. No widening, narrowing, or implicit conversion. Zero runtime cost. | Existing function-style casts (`as_int`, `as_int_generic`) stay as the catch-all. The keyword form is reserved for the layout-preserving case. |
