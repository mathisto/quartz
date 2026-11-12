# unicode/normalize

## Functions

### `HANGUL_SBASE(): Int` *(std/unicode/normalize.qz:15)*

---------------------------------------------------------------------------
Hangul constants (algorithmic, no table needed)
---------------------------------------------------------------------------

---

### `HANGUL_LBASE(): Int` *(std/unicode/normalize.qz:16)*

---

### `HANGUL_VBASE(): Int` *(std/unicode/normalize.qz:17)*

---

### `HANGUL_TBASE(): Int` *(std/unicode/normalize.qz:18)*

---

### `HANGUL_LCOUNT(): Int` *(std/unicode/normalize.qz:19)*

---

### `HANGUL_VCOUNT(): Int` *(std/unicode/normalize.qz:20)*

---

### `HANGUL_TCOUNT(): Int` *(std/unicode/normalize.qz:21)*

---

### `HANGUL_NCOUNT(): Int` *(std/unicode/normalize.qz:22)*

---

### `HANGUL_SCOUNT(): Int` *(std/unicode/normalize.qz:23)*

---

### `unicode_ccc(): Int` *(std/unicode/normalize.qz:31)*

---------------------------------------------------------------------------
CCC lookup
---------------------------------------------------------------------------
Get the Canonical Combining Class of a codepoint.
Returns 0 for starters, > 0 for combining marks.

---

### `_decompose_cp(): Void` *(std/unicode/normalize.qz:60)*

---------------------------------------------------------------------------
Decomposition
---------------------------------------------------------------------------
Decompose a single codepoint. Appends decomposed codepoints to result vec.
Recursively decomposes until fully decomposed (NFD).

---

### `_sort_by_ccc(): Void` *(std/unicode/normalize.qz:124)*

Sort combining marks by CCC (stable sort using insertion sort).
Only sorts within each "block" between starters (CCC=0).

---

### `unicode_nfd(): String` *(std/unicode/normalize.qz:164)*

---------------------------------------------------------------------------
NFD — Canonical Decomposition
---------------------------------------------------------------------------
Decompose a string to NFD (Canonical Decomposition).

---

### `_compose_pair(): Int` *(std/unicode/normalize.qz:212)*

---------------------------------------------------------------------------
NFC — Canonical Composition (NFD + recompose)
---------------------------------------------------------------------------
Look up canonical composition for a pair of codepoints.
Returns the composed codepoint, or -1 if no composition exists.

---

### `unicode_nfc(): String` *(std/unicode/normalize.qz:255)*

Compose a string to NFC (Canonical Composition).
First decomposes to NFD, then recomposes canonical pairs.

---

### `unicode_eq_canonical(): Bool` *(std/unicode/normalize.qz:344)*

Compare two strings for canonical equivalence.

---

