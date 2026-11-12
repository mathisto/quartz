# net/udp

## Structs

### `UdpSocket` *(std/net/udp.qz:16)*

| Field | Type |
|-------|------|
| `fd` | `Int` |
| `port` | `Int` |

## Enums

### `UdpResult` *(std/net/udp.qz:21)*

| Variant | Payload |
|---------|----------|
| `Ok` | — |
| `Err` | — |

## Functions

### `udp_bind(): UdpResult` *(std/net/udp.qz:27)*

---

### `udp_send_to(): WriteResult` *(std/net/udp.qz:70)*

---

### `udp_recv_from(): ReadResult` *(std/net/udp.qz:94)*

---

### `udp_close(): Int` *(std/net/udp.qz:121)*

---

