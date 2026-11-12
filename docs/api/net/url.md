# net/url

## Functions

### `_hex_val(): Int` *(std/net/url.qz:15)*

---

### `_byte_to_hex(): String` *(std/net/url.qz:28)*

---

### `url_decode(): String` *(std/net/url.qz:41)*

Decode a percent-encoded string.
%XX → byte value, + → space. Malformed sequences pass through literally.

---

### `url_encode(): String` *(std/net/url.qz:81)*

Percent-encode a string for use in URLs.
Unreserved chars (A-Z, a-z, 0-9, - . _ ~) pass through. All others → %XX.

---

