# Bytes — Binary Data Type

Quartz's `Bytes` type provides first-class binary data handling with ergonomic construction, structured parsing, and (planned) pattern matching.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Naming** | `Bytes` | Concrete, unambiguous. `Data` too abstract, `Buffer` implies mutability |
| **Endianness** | Big-endian default | Network byte order. Most binary data is protocols/file formats |
| **String interop** | Always copy | Different memory layouts (String = `char*`, Bytes = Vec header). Different invariants (String = valid text, Bytes = arbitrary octets) |
| **Mutability** | Immutable output | `Bytes.build {}` is mutable during construction, result is immutable. Aligns with future `let`/`var` split |
| **Representation** | `Vec<Int>`-backed | Each byte stored as i64 in Vec data array. Reuses all existing Vec infrastructure including LS.5 slicing and LS.6 custom indexing |

## Layer 1: `Bytes` Type

### Construction

```quartz
# Empty
var data = Bytes.new()

# With capacity hint
var data = Bytes.new(1024)

# From string (copies UTF-8 bytes)
var data = Bytes.from("hello")   # [104, 101, 108, 108, 111]

# From array (each value clamped to 0-255)
var data = Bytes.from([0x48, 0x65, 0x6C])
```

### Access

```quartz
data.size          # number of bytes
data[0]            # single byte (0-255) via custom index
data[1..4]         # slice → new Bytes, via sliceable trait
```

### Positional Readers

Read typed values at a specific byte offset without advancing a cursor:

```quartz
data.read_u8(at: 0)       # unsigned 8-bit
data.read_u16be(at: 0)    # unsigned 16-bit, big-endian
data.read_u16le(at: 0)    # unsigned 16-bit, little-endian
data.read_u32be(at: 0)    # unsigned 32-bit, big-endian
data.read_u32le(at: 0)    # unsigned 32-bit, little-endian
data.read_i8(at: 0)       # signed 8-bit (sign-extended)
data.read_i16be(at: 0)    # signed 16-bit, big-endian
data.read_i32be(at: 0)    # signed 32-bit, big-endian
```

**Endianness convention:** Methods ending in `be` are big-endian (network order), `le` are little-endian. Unadorned `u16`/`u32` without suffix default to big-endian.

### String Interop

```quartz
# Bytes → String (copies, interprets as UTF-8)
var s = data.to_string()

# Hex representation
var hex = data.to_hex()    # "48656c6c6f"

# Round-trip
Bytes.from("abc").to_string() == "abc"  # true
```

### Comparison

```quartz
var a = Bytes.from([1, 2, 3])
var b = Bytes.from([1, 2, 3])
a.eq(b)   # true
```

## Layer 2: `b[...]` Literals & Builder

### Simple Byte Literal

```quartz
# Plain byte values
var magic = b[0x89, 0x50, 0x4E, 0x47]   # PNG magic bytes
var empty = b[]                           # empty Bytes
```

### Typed Segment Builder

Segments specify how values are encoded into bytes:

```quartz
var packet = b[
  u8:     1,           # 1 byte
  u16be:  1024,        # 2 bytes, big-endian → [0x04, 0x00]
  u32le:  sequence,    # 4 bytes, little-endian
  bytes:  payload,     # raw Bytes concatenation
  string: "OK"         # UTF-8 encoded string bytes
]
```

| Segment | Size | Encoding |
|---------|------|----------|
| `u8:` | 1 byte | Single byte |
| `u16be:` / `u16:` | 2 bytes | Big-endian (default) |
| `u16le:` | 2 bytes | Little-endian |
| `u32be:` / `u32:` | 4 bytes | Big-endian (default) |
| `u32le:` | 4 bytes | Little-endian |
| `bytes:` | variable | Raw byte concatenation |
| `string:` | variable | UTF-8 encoded |

### Block Builder

For more complex construction with control flow:

```quartz
var packet = Bytes.build {
  u8(0x01)
  u16be(content.size)
  if has_checksum
    u32be(compute_crc(content))
  end
  bytes(content)
}
```

## Layer 3: `ByteReader` Cursor

Sequential reading with automatic position tracking:

```quartz
var reader = data.reader()

var version = reader.u8()        # read 1 byte, advance
var length = reader.u16be()      # read 2 bytes, advance
var body = reader.bytes(length)  # read N bytes, advance

reader.remaining()  # bytes left
reader.eof()        # true if no bytes remain
```

### Typical Protocol Parsing

```quartz
def parse_packet(data: Bytes): Packet
  var r = data.reader()
  var version = r.u8()
  var msg_type = r.u8()
  var payload_len = r.u16be()
  var payload = r.bytes(payload_len)
  return Packet {
    version: version,
    msg_type: msg_type,
    payload: payload
  }
end
```

## Layer 4: Binary Pattern Matching (Planned)

> **Status:** Stretch goal. Will be implemented after Layers 1–3 are stable.

Destructure binary data directly in `match` expressions:

```quartz
match data
  b[0x89, "PNG", rest: bytes]              => handle_png(rest)
  b[0xFF, 0xD8, rest: bytes]               => handle_jpeg(rest)
  b[v: u8, len: u16be, body: bytes]        => process(v, body)
end
```

### Sub-byte Extraction

Extract nibbles and bit fields:

```quartz
match header_byte
  b[version: u4, ihl: u4]  => # IPv4: version=4, ihl=5
end

# version = (byte >> 4) & 0x0F
# ihl     = byte & 0x0F
```

### Pattern Semantics

- **Literal values** (`0x89`, `"PNG"`) are matched exactly
- **Named segments** (`v: u8`, `len: u16be`) bind extracted values to variables
- **`rest: bytes`** captures all remaining bytes (must be last segment)
- **Sub-byte** (`v: u4`) uses bit-shift and mask extraction
- Non-matching patterns fall through to the next `match` arm
