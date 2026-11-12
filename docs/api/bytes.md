# bytes

## Structs

### `Bytes` *(std/bytes.qz:10)*

| Field | Type |
|-------|------|
| `_data` | `Vec<Int>` |

#### Methods

##### `get(): Int`

##### `set(): Void`

##### `size(): Int`

##### `read_u8(): Int`

##### `read_u16be(): Int`

##### `read_u16le(): Int`

##### `read_u32be(): Int`

##### `read_u32le(): Int`

##### `push(): Void`

##### `is_empty(): Bool`

Return true if the bytes buffer is empty.

##### `to_vec(): Vec<Int>`

Convert to a Vec<Int> copy.

##### `eq(): Bool`

