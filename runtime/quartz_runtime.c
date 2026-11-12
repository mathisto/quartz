/* Quartz Runtime Library — C Backend
 * Implements core data structures matching LLVM backend memory layouts.
 * All values are int64_t (Quartz's existential type model). */

#include "quartz_runtime.h"

/* ======== String Operations ========
 * Layout: [8-byte length (i64)] [data bytes] [\0]
 * qz_val points to data[0], length at (ptr - 8). */

qz_val qz_alloc_str(int64_t len) {
  char *buf = (char *)malloc(8 + len + 1);
  *(int64_t *)buf = len;
  char *data = buf + 8;
  data[len] = '\0';
  return (qz_val)(intptr_t)data;
}

int64_t qz_str_len(qz_val s) {
  if (!s)
    return 0;
  return *(int64_t *)((char *)(intptr_t)s - 8);
}

qz_val qz_str_concat(qz_val a, qz_val b) {
  int64_t alen = qz_str_len(a);
  int64_t blen = qz_str_len(b);
  qz_val r = qz_alloc_str(alen + blen);
  memcpy((char *)(intptr_t)r, (char *)(intptr_t)a, alen);
  memcpy((char *)(intptr_t)r + alen, (char *)(intptr_t)b, blen);
  return r;
}

qz_val qz_str_eq(qz_val a, qz_val b) {
  int64_t al = qz_str_len(a), bl = qz_str_len(b);
  if (al != bl)
    return 0;
  return memcmp((char *)(intptr_t)a, (char *)(intptr_t)b, al) == 0 ? 1 : 0;
}

qz_val qz_str_char_at(qz_val s, qz_val idx) {
  return (qz_val)((unsigned char *)((intptr_t)s))[idx];
}

qz_val qz_str_slice(qz_val s, qz_val start, qz_val end) {
  int64_t len = end - start;
  if (len < 0)
    len = 0;
  qz_val r = qz_alloc_str(len);
  memcpy((char *)(intptr_t)r, (char *)(intptr_t)s + start, len);
  return r;
}

qz_val qz_str_from_int(qz_val n) {
  char buf[32];
  int len = snprintf(buf, sizeof(buf), "%lld", (long long)n);
  qz_val r = qz_alloc_str(len);
  memcpy((char *)(intptr_t)r, buf, len);
  return r;
}

qz_val qz_str_to_int(qz_val s) {
  return (qz_val)strtoll((char *)(intptr_t)s, NULL, 10);
}

qz_val qz_str_contains(qz_val h, qz_val n) {
  return strstr((char *)(intptr_t)h, (char *)(intptr_t)n) ? 1 : 0;
}

qz_val qz_str_find(qz_val h, qz_val n) {
  char *p = strstr((char *)(intptr_t)h, (char *)(intptr_t)n);
  return p ? (qz_val)(p - (char *)(intptr_t)h) : -1;
}

qz_val qz_str_starts_with(qz_val s, qz_val pfx) {
  int64_t pl = qz_str_len(pfx);
  if (qz_str_len(s) < pl)
    return 0;
  return memcmp((char *)(intptr_t)s, (char *)(intptr_t)pfx, pl) == 0 ? 1 : 0;
}

qz_val qz_str_ends_with(qz_val s, qz_val sfx) {
  int64_t sl = qz_str_len(s), xl = qz_str_len(sfx);
  if (sl < xl)
    return 0;
  return memcmp((char *)(intptr_t)s + sl - xl, (char *)(intptr_t)sfx, xl) == 0
             ? 1
             : 0;
}

qz_val qz_str_from_char(qz_val ch) {
  qz_val r = qz_alloc_str(1);
  ((char *)(intptr_t)r)[0] = (char)ch;
  return r;
}

qz_val qz_str_hash(qz_val s) {
  uint64_t h = 14695981039346656037ULL;
  char *p = (char *)(intptr_t)s;
  int64_t len = qz_str_len(s);
  for (int64_t i = 0; i < len; i++) {
    h ^= (uint8_t)p[i];
    h *= 1099511628211ULL;
  }
  return (qz_val)h;
}

qz_val qz_str_replace(qz_val s, qz_val old_s, qz_val new_s) {
  char *src = (char *)(intptr_t)s;
  char *o = (char *)(intptr_t)old_s;
  char *n = (char *)(intptr_t)new_s;
  int64_t ol = qz_str_len(old_s), nl = qz_str_len(new_s), sl = qz_str_len(s);
  if (ol == 0)
    return s;
  /* Count occurrences */
  int64_t cnt = 0;
  char *p = src;
  while ((p = strstr(p, o)) != NULL) {
    cnt++;
    p += ol;
  }
  int64_t rlen = sl + cnt * (nl - ol);
  qz_val r = qz_alloc_str(rlen);
  char *dst = (char *)(intptr_t)r;
  p = src;
  while (*p) {
    char *f = strstr(p, o);
    if (!f) {
      int64_t rem = sl - (p - src);
      memcpy(dst, p, rem);
      dst += rem;
      break;
    }
    memcpy(dst, p, f - p);
    dst += (f - p);
    memcpy(dst, n, nl);
    dst += nl;
    p = f + ol;
  }
  return r;
}

qz_val qz_str_trim(qz_val s) {
  char *p = (char *)(intptr_t)s;
  int64_t len = qz_str_len(s);
  int64_t l = 0, r = len;
  while (l < r && isspace((unsigned char)p[l]))
    l++;
  while (r > l && isspace((unsigned char)p[r - 1]))
    r--;
  return qz_str_slice(s, l, r);
}

qz_val qz_str_trim_left(qz_val s) {
  char *p = (char *)(intptr_t)s;
  int64_t len = qz_str_len(s), l = 0;
  while (l < len && isspace((unsigned char)p[l]))
    l++;
  return qz_str_slice(s, l, len);
}

qz_val qz_str_trim_right(qz_val s) {
  int64_t len = qz_str_len(s);
  char *p = (char *)(intptr_t)s;
  while (len > 0 && isspace((unsigned char)p[len - 1]))
    len--;
  return qz_str_slice(s, 0, len);
}

qz_val qz_str_downcase(qz_val s) {
  int64_t len = qz_str_len(s);
  qz_val r = qz_alloc_str(len);
  char *src = (char *)(intptr_t)s, *dst = (char *)(intptr_t)r;
  for (int64_t i = 0; i < len; i++)
    dst[i] = tolower((unsigned char)src[i]);
  return r;
}

qz_val qz_str_upcase(qz_val s) {
  int64_t len = qz_str_len(s);
  qz_val r = qz_alloc_str(len);
  char *src = (char *)(intptr_t)s, *dst = (char *)(intptr_t)r;
  for (int64_t i = 0; i < len; i++)
    dst[i] = toupper((unsigned char)src[i]);
  return r;
}

qz_val qz_str_repeat(qz_val s, qz_val n) {
  int64_t sl = qz_str_len(s);
  qz_val r = qz_alloc_str(sl * n);
  char *dst = (char *)(intptr_t)r, *src = (char *)(intptr_t)s;
  for (int64_t i = 0; i < n; i++) {
    memcpy(dst, src, sl);
    dst += sl;
  }
  return r;
}

qz_val qz_str_count(qz_val s, qz_val sub) {
  char *p = (char *)(intptr_t)s, *needle = (char *)(intptr_t)sub;
  int64_t nl = qz_str_len(sub), cnt = 0;
  if (nl == 0)
    return 0;
  while ((p = strstr(p, needle))) {
    cnt++;
    p += nl;
  }
  return cnt;
}

qz_val qz_str_is_empty(qz_val s) { return qz_str_len(s) == 0 ? 1 : 0; }

qz_val qz_cstr_to_string(qz_val cstr) {
  char *p = (char *)(intptr_t)cstr;
  int64_t len = strlen(p);
  qz_val r = qz_alloc_str(len);
  memcpy((char *)(intptr_t)r, p, len);
  return r;
}

qz_val qz_string_to_cstr(qz_val s) { return s; /* already null-terminated */ }

qz_val qz_str_to_f64(qz_val s) {
  double d = strtod((char *)(intptr_t)s, NULL);
  qz_val r;
  memcpy(&r, &d, 8);
  return r;
}

qz_val qz_f64_to_str(qz_val bits) {
  double d;
  memcpy(&d, &bits, 8);
  char buf[64];
  int len = snprintf(buf, sizeof(buf), "%.17g", d);
  qz_val r = qz_alloc_str(len);
  memcpy((char *)(intptr_t)r, buf, len);
  return r;
}

qz_val qz_str_reverse(qz_val s) {
  int64_t len = qz_str_len(s);
  qz_val r = qz_alloc_str(len);
  char *src = (char *)(intptr_t)s, *dst = (char *)(intptr_t)r;
  for (int64_t i = 0; i < len; i++)
    dst[i] = src[len - 1 - i];
  return r;
}

qz_val qz_str_pad_left(qz_val s, qz_val width, qz_val pad_char) {
  int64_t sl = qz_str_len(s);
  if (sl >= width)
    return s;
  int64_t pad = width - sl;
  qz_val r = qz_alloc_str(width);
  char *dst = (char *)(intptr_t)r;
  memset(dst, (char)pad_char, pad);
  memcpy(dst + pad, (char *)(intptr_t)s, sl);
  return r;
}

qz_val qz_str_pad_right(qz_val s, qz_val width, qz_val pad_char) {
  int64_t sl = qz_str_len(s);
  if (sl >= width)
    return s;
  int64_t pad = width - sl;
  qz_val r = qz_alloc_str(width);
  char *dst = (char *)(intptr_t)r;
  memcpy(dst, (char *)(intptr_t)s, sl);
  memset(dst + sl, (char)pad_char, pad);
  return r;
}

qz_val qz_str_codepoint_at(qz_val s, qz_val idx) {
  unsigned char *p = (unsigned char *)(intptr_t)s;
  unsigned char c = p[idx];
  if (c < 0x80)
    return c;
  if ((c & 0xE0) == 0xC0)
    return ((c & 0x1F) << 6) | (p[idx + 1] & 0x3F);
  if ((c & 0xF0) == 0xE0)
    return ((c & 0x0F) << 12) | ((p[idx + 1] & 0x3F) << 6) |
           (p[idx + 2] & 0x3F);
  if ((c & 0xF8) == 0xF0)
    return ((c & 0x07) << 18) | ((p[idx + 1] & 0x3F) << 12) |
           ((p[idx + 2] & 0x3F) << 6) | (p[idx + 3] & 0x3F);
  return c;
}

qz_val qz_str_len_utf8(qz_val s) {
  unsigned char *p = (unsigned char *)(intptr_t)s;
  int64_t len = qz_str_len(s), cnt = 0;
  for (int64_t i = 0; i < len;) {
    if (p[i] < 0x80)
      i += 1;
    else if ((p[i] & 0xE0) == 0xC0)
      i += 2;
    else if ((p[i] & 0xF0) == 0xE0)
      i += 3;
    else
      i += 4;
    cnt++;
  }
  return cnt;
}

qz_val qz_str_substr(qz_val s, qz_val start, qz_val length) {
  return qz_str_slice(s, start, start + length);
}

qz_val qz_str_to_ptr(qz_val s) { return s; }
qz_val qz_str_from_ptr(qz_val ptr, qz_val len) {
  qz_val r = qz_alloc_str(len);
  memcpy((char *)(intptr_t)r, (void *)(intptr_t)ptr, len);
  return r;
}

/* Forward declaration for split/join/chars (needs vec) */
qz_val qz_vec_new(void);
void qz_vec_push(qz_val, qz_val);

qz_val qz_str_split(qz_val s, qz_val delim) {
  qz_val result = qz_vec_new();
  char *src = (char *)(intptr_t)s;
  char *d = (char *)(intptr_t)delim;
  int64_t dl = qz_str_len(delim), sl = qz_str_len(s);
  if (dl == 0) {
    for (int64_t i = 0; i < sl; i++)
      qz_vec_push(result, qz_str_from_char(src[i]));
    return result;
  }
  char *p = src;
  while (1) {
    char *f = strstr(p, d);
    if (!f) {
      qz_vec_push(result, qz_str_from_ptr((qz_val)(intptr_t)p, strlen(p)));
      break;
    }
    qz_vec_push(result, qz_str_from_ptr((qz_val)(intptr_t)p, f - p));
    p = f + dl;
  }
  return result;
}

qz_val qz_str_chars(qz_val s) {
  int64_t len = qz_str_len(s);
  qz_val result = qz_vec_new();
  unsigned char *p = (unsigned char *)(intptr_t)s;
  for (int64_t i = 0; i < len; i++)
    qz_vec_push(result, (qz_val)p[i]);
  return result;
}

/* ======== StringBuilder ========
 * Layout: 24-byte header [capacity(i64), length(i64), data_ptr(i64)] */

qz_val qz_sb_new(void) {
  int64_t *h = (int64_t *)malloc(24);
  h[0] = 64;                            /* capacity */
  h[1] = 0;                             /* length */
  h[2] = (int64_t)(intptr_t)malloc(64); /* data */
  return (qz_val)(intptr_t)h;
}

static void sb_ensure(int64_t *h, int64_t need) {
  if (need <= h[0])
    return;
  int64_t newcap = h[0] * 2;
  if (newcap < need)
    newcap = need;
  h[2] = (int64_t)(intptr_t)realloc((void *)(intptr_t)h[2], newcap);
  h[0] = newcap;
}

void qz_sb_append(qz_val sb, qz_val s) {
  int64_t *h = (int64_t *)(intptr_t)sb;
  int64_t sl = qz_str_len(s);
  sb_ensure(h, h[1] + sl + 1);
  memcpy((char *)(intptr_t)h[2] + h[1], (char *)(intptr_t)s, sl);
  h[1] += sl;
  ((char *)(intptr_t)h[2])[h[1]] = '\0';
}

void qz_sb_append_char(qz_val sb, qz_val ch) {
  int64_t *h = (int64_t *)(intptr_t)sb;
  char *data;
  int64_t len = h[1];
  if (ch < 128) {
    sb_ensure(h, len + 2);
    data = (char *)(intptr_t)h[2];
    data[len] = (char)ch;
    h[1] = len + 1;
  } else if (ch < 2048) {
    sb_ensure(h, len + 3);
    data = (char *)(intptr_t)h[2];
    data[len]     = (char)((ch >> 6) | 0xC0);
    data[len + 1] = (char)((ch & 0x3F) | 0x80);
    h[1] = len + 2;
  } else if (ch < 65536) {
    sb_ensure(h, len + 4);
    data = (char *)(intptr_t)h[2];
    data[len]     = (char)((ch >> 12) | 0xE0);
    data[len + 1] = (char)(((ch >> 6) & 0x3F) | 0x80);
    data[len + 2] = (char)((ch & 0x3F) | 0x80);
    h[1] = len + 3;
  } else {
    sb_ensure(h, len + 5);
    data = (char *)(intptr_t)h[2];
    data[len]     = (char)((ch >> 18) | 0xF0);
    data[len + 1] = (char)(((ch >> 12) & 0x3F) | 0x80);
    data[len + 2] = (char)(((ch >> 6) & 0x3F) | 0x80);
    data[len + 3] = (char)((ch & 0x3F) | 0x80);
    h[1] = len + 4;
  }
  ((char *)(intptr_t)h[2])[h[1]] = '\0';
}

void qz_sb_append_int(qz_val sb, qz_val n) {
  qz_val s = qz_str_from_int(n);
  qz_sb_append(sb, s);
}

qz_val qz_sb_to_string(qz_val sb) {
  int64_t *h = (int64_t *)(intptr_t)sb;
  qz_val r = qz_alloc_str(h[1]);
  memcpy((char *)(intptr_t)r, (char *)(intptr_t)h[2], h[1]);
  return r;
}

void qz_sb_clear(qz_val sb) {
  int64_t *h = (int64_t *)(intptr_t)sb;
  h[1] = 0;
  ((char *)(intptr_t)h[2])[0] = '\0';
}

void qz_sb_free(qz_val sb) {
  int64_t *h = (int64_t *)(intptr_t)sb;
  free((void *)(intptr_t)h[2]);
  free(h);
}

qz_val qz_sb_len(qz_val sb) { return ((int64_t *)(intptr_t)sb)[1]; }

/* ======== Vec ========
 * Layout: 32-byte header [capacity(i64), size(i64), data_ptr(i64),
 * elem_width(i64)] Default elem_width = 8. */

qz_val qz_vec_new(void) {
  int64_t *h = (int64_t *)malloc(32);
  h[0] = 8;                               /* capacity */
  h[1] = 0;                               /* size */
  h[2] = (int64_t)(intptr_t)calloc(8, 8); /* data (8 slots × 8 bytes) */
  h[3] = 8;                               /* elem_width */
  return (qz_val)(intptr_t)h;
}

qz_val qz_vec_new_filled(qz_val count, qz_val fill) {
  int64_t *h = (int64_t *)malloc(32);
  h[0] = count;
  h[1] = count;
  h[3] = 8;
  h[2] = (int64_t)(intptr_t)malloc(count * 8);
  int64_t *data = (int64_t *)(intptr_t)h[2];
  for (int64_t i = 0; i < count; i++)
    data[i] = fill;
  return (qz_val)(intptr_t)h;
}

static void vec_grow(int64_t *h) {
  int64_t newcap = h[0] * 2;
  if (newcap < 4)
    newcap = 4;
  h[2] = (int64_t)(intptr_t)realloc((void *)(intptr_t)h[2], newcap * h[3]);
  h[0] = newcap;
}

void qz_vec_push(qz_val vec, qz_val val) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  if (h[1] >= h[0])
    vec_grow(h);
  int64_t ew = h[3];
  if (ew == 8) {
    ((int64_t *)(intptr_t)h[2])[h[1]] = val;
  } else if (ew == 1) {
    ((uint8_t *)(intptr_t)h[2])[h[1]] = (uint8_t)val;
  } else if (ew == 2) {
    ((uint16_t *)(intptr_t)h[2])[h[1]] = (uint16_t)val;
  } else if (ew == 4) {
    ((uint32_t *)(intptr_t)h[2])[h[1]] = (uint32_t)val;
  } else {
    ((int64_t *)(intptr_t)h[2])[h[1]] = val;
  }
  h[1]++;
}

qz_val qz_vec_get(qz_val vec, qz_val idx) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  if (idx < 0 || idx >= h[1]) {
    fprintf(stderr, "Vec index out of bounds: %lld (size %lld)\n",
            (long long)idx, (long long)h[1]);
    abort();
  }
  return ((int64_t *)(intptr_t)h[2])[idx];
}

qz_val qz_vec_get_unchecked(qz_val vec, qz_val idx) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  return ((int64_t *)(intptr_t)h[2])[idx];
}

void qz_vec_set(qz_val vec, qz_val idx, qz_val val) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  if (idx < 0 || idx >= h[1]) {
    fprintf(stderr, "Vec set index out of bounds: %lld (size %lld)\n",
            (long long)idx, (long long)h[1]);
    abort();
  }
  ((int64_t *)(intptr_t)h[2])[idx] = val;
}

void qz_vec_set_unchecked(qz_val vec, qz_val idx, qz_val val) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  ((int64_t *)(intptr_t)h[2])[idx] = val;
}

qz_val qz_vec_pop(qz_val vec) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  if (h[1] == 0) {
    fprintf(stderr, "Vec pop on empty\n");
    abort();
  }
  h[1]--;
  return ((int64_t *)(intptr_t)h[2])[h[1]];
}

qz_val qz_vec_len(qz_val vec) { return ((int64_t *)(intptr_t)vec)[1]; }

void qz_vec_free(qz_val vec) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  free((void *)(intptr_t)h[2]);
  free(h);
}

void qz_vec_clear(qz_val vec) { ((int64_t *)(intptr_t)vec)[1] = 0; }

void qz_vec_shrink_to_fit(qz_val vec) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  int64_t cap = h[0];
  int64_t sz = h[1];
  if (cap > sz && sz > 0) {
    h[2] = (int64_t)(intptr_t)realloc((void *)(intptr_t)h[2], sz * h[3]);
    h[0] = sz;
  }
}

qz_val qz_vec_contains(qz_val vec, qz_val val) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  int64_t *data = (int64_t *)(intptr_t)h[2];
  for (int64_t i = 0; i < h[1]; i++)
    if (data[i] == val)
      return 1;
  return 0;
}

qz_val qz_vec_index_of(qz_val vec, qz_val val) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  int64_t *data = (int64_t *)(intptr_t)h[2];
  for (int64_t i = 0; i < h[1]; i++)
    if (data[i] == val)
      return i;
  return -1;
}

void qz_vec_insert(qz_val vec, qz_val idx, qz_val val) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  if (h[1] >= h[0])
    vec_grow(h);
  int64_t *data = (int64_t *)(intptr_t)h[2];
  memmove(&data[idx + 1], &data[idx], (h[1] - idx) * 8);
  data[idx] = val;
  h[1]++;
}

qz_val qz_vec_remove(qz_val vec, qz_val idx) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  int64_t *data = (int64_t *)(intptr_t)h[2];
  qz_val val = data[idx];
  memmove(&data[idx], &data[idx + 1], (h[1] - idx - 1) * 8);
  h[1]--;
  return val;
}

qz_val qz_vec_clone(qz_val vec) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  int64_t *nh = (int64_t *)malloc(32);
  nh[0] = h[0];
  nh[1] = h[1];
  nh[3] = h[3];
  int64_t bytes = h[0] * h[3];
  nh[2] = (int64_t)(intptr_t)malloc(bytes);
  memcpy((void *)(intptr_t)nh[2], (void *)(intptr_t)h[2], h[1] * h[3]);
  return (qz_val)(intptr_t)nh;
}

static int vec_sort_cmp(const void *a, const void *b) {
  int64_t va = *(const int64_t *)a, vb = *(const int64_t *)b;
  return (va > vb) - (va < vb);
}

void qz_vec_sort(qz_val vec) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  qsort((void *)(intptr_t)h[2], h[1], 8, vec_sort_cmp);
}

/* sort_by: cmp_fn is a Quartz function pointer taking 2 args, returning <0/0/>0
 */
static qz_val g_sort_cmp_fn;
static int vec_sort_by_cmp(const void *a, const void *b) {
  int64_t va = *(const int64_t *)a, vb = *(const int64_t *)b;
  qz_val (*fn)(qz_val, qz_val) =
      (qz_val (*)(qz_val, qz_val))(intptr_t)g_sort_cmp_fn;
  return (int)fn(va, vb);
}

void qz_vec_sort_by(qz_val vec, qz_val cmp_fn) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  g_sort_cmp_fn = cmp_fn;
  qsort((void *)(intptr_t)h[2], h[1], 8, vec_sort_by_cmp);
}

qz_val qz_vec_reverse(qz_val vec) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  int64_t *data = (int64_t *)(intptr_t)h[2];
  for (int64_t i = 0; i < h[1] / 2; i++) {
    int64_t t = data[i];
    data[i] = data[h[1] - 1 - i];
    data[h[1] - 1 - i] = t;
  }
  return 0;
}

qz_val qz_vec_join(qz_val vec, qz_val sep) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  if (h[1] == 0)
    return qz_alloc_str(0);
  qz_val sb = qz_sb_new();
  int64_t *data = (int64_t *)(intptr_t)h[2];
  for (int64_t i = 0; i < h[1]; i++) {
    if (i > 0)
      qz_sb_append(sb, sep);
    qz_sb_append(sb, data[i]);
  }
  qz_val r = qz_sb_to_string(sb);
  qz_sb_free(sb);
  return r;
}

qz_val qz_vec_slice(qz_val vec, qz_val start, qz_val len) {
  int64_t *h = (int64_t *)(intptr_t)vec;
  int64_t *nh = (int64_t *)malloc(32);
  nh[0] = len;
  nh[1] = len;
  nh[3] = h[3];
  int64_t bytes = len * h[3];
  nh[2] = (int64_t)(intptr_t)malloc(bytes);
  memcpy((void *)(intptr_t)nh[2], (char *)(intptr_t)h[2] + start * h[3], bytes);
  return (qz_val)(intptr_t)nh;
}

/* str_join: join Vec<String> with separator */
qz_val qz_str_join(qz_val vec, qz_val sep) { return qz_vec_join(vec, sep); }

/* ======== HashMap ========
 * Open-addressing with linear probing, string keys (FNV-1a hash). */

#define HM_INIT_CAP 16
#define HM_EMPTY 0
#define HM_OCCUPIED 1
#define HM_DELETED 2

typedef struct {
  int64_t capacity;
  int64_t size;
  int64_t *keys; /* qz_val string pointers */
  int64_t *values;
  uint8_t *states;
} QzHashMap;

qz_val qz_hashmap_new(void) {
  QzHashMap *m = (QzHashMap *)calloc(1, sizeof(QzHashMap));
  m->capacity = HM_INIT_CAP;
  m->keys = (int64_t *)calloc(HM_INIT_CAP, sizeof(int64_t));
  m->values = (int64_t *)calloc(HM_INIT_CAP, sizeof(int64_t));
  m->states = (uint8_t *)calloc(HM_INIT_CAP, 1);
  return (qz_val)(intptr_t)m;
}

static int64_t hm_find_slot(QzHashMap *m, qz_val key) {
  uint64_t h = (uint64_t)qz_str_hash(key);
  int64_t mask = m->capacity - 1;
  int64_t idx = h & mask;
  for (int64_t i = 0; i < m->capacity; i++) {
    int64_t slot = (idx + i) & mask;
    if (m->states[slot] == HM_EMPTY)
      return -(slot + 1); /* negative = empty */
    if (m->states[slot] == HM_OCCUPIED && qz_str_eq(m->keys[slot], key))
      return slot;
  }
  return -(int64_t)m->capacity; /* should not happen if load < 1 */
}

static void hm_rehash(QzHashMap *m) {
  int64_t old_cap = m->capacity;
  int64_t *old_keys = m->keys, *old_vals = m->values;
  uint8_t *old_states = m->states;
  m->capacity *= 2;
  m->keys = (int64_t *)calloc(m->capacity, sizeof(int64_t));
  m->values = (int64_t *)calloc(m->capacity, sizeof(int64_t));
  m->states = (uint8_t *)calloc(m->capacity, 1);
  m->size = 0;
  for (int64_t i = 0; i < old_cap; i++) {
    if (old_states[i] == HM_OCCUPIED) {
      qz_hashmap_set((qz_val)(intptr_t)m, old_keys[i], old_vals[i]);
    }
  }
  free(old_keys);
  free(old_vals);
  free(old_states);
}

void qz_hashmap_set(qz_val map, qz_val key, qz_val val) {
  QzHashMap *m = (QzHashMap *)(intptr_t)map;
  if (m->size * 4 >= m->capacity * 3)
    hm_rehash(m); /* 75% load */
  int64_t slot = hm_find_slot(m, key);
  if (slot >= 0) {
    m->values[slot] = val;
    return;
  }
  slot = -(slot + 1);
  m->keys[slot] = key;
  m->values[slot] = val;
  m->states[slot] = HM_OCCUPIED;
  m->size++;
}

qz_val qz_hashmap_get(qz_val map, qz_val key) {
  QzHashMap *m = (QzHashMap *)(intptr_t)map;
  int64_t slot = hm_find_slot(m, key);
  if (slot >= 0)
    return m->values[slot];
  return 0;
}

qz_val qz_hashmap_has(qz_val map, qz_val key) {
  QzHashMap *m = (QzHashMap *)(intptr_t)map;
  return hm_find_slot(m, key) >= 0 ? 1 : 0;
}

void qz_hashmap_del(qz_val map, qz_val key) {
  QzHashMap *m = (QzHashMap *)(intptr_t)map;
  int64_t slot = hm_find_slot(m, key);
  if (slot >= 0) {
    m->states[slot] = HM_DELETED;
    m->size--;
  }
}

qz_val qz_hashmap_keys(qz_val map) {
  QzHashMap *m = (QzHashMap *)(intptr_t)map;
  qz_val result = qz_vec_new();
  for (int64_t i = 0; i < m->capacity; i++)
    if (m->states[i] == HM_OCCUPIED)
      qz_vec_push(result, m->keys[i]);
  return result;
}

qz_val qz_hashmap_values(qz_val map) {
  QzHashMap *m = (QzHashMap *)(intptr_t)map;
  qz_val result = qz_vec_new();
  for (int64_t i = 0; i < m->capacity; i++)
    if (m->states[i] == HM_OCCUPIED)
      qz_vec_push(result, m->values[i]);
  return result;
}

qz_val qz_hashmap_size(qz_val map) {
  return ((QzHashMap *)(intptr_t)map)->size;
}

void qz_hashmap_free(qz_val map) {
  QzHashMap *m = (QzHashMap *)(intptr_t)map;
  free(m->keys);
  free(m->values);
  free(m->states);
  free(m);
}

void qz_hashmap_clear(qz_val map) {
  QzHashMap *m = (QzHashMap *)(intptr_t)map;
  memset(m->states, 0, m->capacity);
  m->size = 0;
}

/* ======== IntMap (integer keys) ======== */

typedef struct {
  int64_t capacity, size;
  int64_t *keys, *values;
  uint8_t *states;
} QzIntMap;

qz_val qz_intmap_new(void) {
  QzIntMap *m = (QzIntMap *)calloc(1, sizeof(QzIntMap));
  m->capacity = HM_INIT_CAP;
  m->keys = (int64_t *)calloc(HM_INIT_CAP, sizeof(int64_t));
  m->values = (int64_t *)calloc(HM_INIT_CAP, sizeof(int64_t));
  m->states = (uint8_t *)calloc(HM_INIT_CAP, 1);
  return (qz_val)(intptr_t)m;
}

static int64_t im_find(QzIntMap *m, qz_val key) {
  uint64_t h = (uint64_t)key * 0x9E3779B97F4A7C15ULL;
  int64_t mask = m->capacity - 1;
  for (int64_t i = 0; i < m->capacity; i++) {
    int64_t slot = (h + i) & mask;
    if (m->states[slot] == HM_EMPTY)
      return -(slot + 1);
    if (m->states[slot] == HM_OCCUPIED && m->keys[slot] == key)
      return slot;
  }
  return -(int64_t)m->capacity;
}

static void im_rehash(QzIntMap *m) {
  int64_t oc = m->capacity;
  int64_t *ok = m->keys, *ov = m->values;
  uint8_t *os = m->states;
  m->capacity *= 2;
  m->size = 0;
  m->keys = (int64_t *)calloc(m->capacity, sizeof(int64_t));
  m->values = (int64_t *)calloc(m->capacity, sizeof(int64_t));
  m->states = (uint8_t *)calloc(m->capacity, 1);
  for (int64_t i = 0; i < oc; i++)
    if (os[i] == HM_OCCUPIED)
      qz_intmap_set((qz_val)(intptr_t)m, ok[i], ov[i]);
  free(ok);
  free(ov);
  free(os);
}

void qz_intmap_set(qz_val map, qz_val key, qz_val val) {
  QzIntMap *m = (QzIntMap *)(intptr_t)map;
  if (m->size * 4 >= m->capacity * 3)
    im_rehash(m);
  int64_t s = im_find(m, key);
  if (s >= 0) {
    m->values[s] = val;
    return;
  }
  s = -(s + 1);
  m->keys[s] = key;
  m->values[s] = val;
  m->states[s] = HM_OCCUPIED;
  m->size++;
}

qz_val qz_intmap_get(qz_val map, qz_val key) {
  int64_t s = im_find((QzIntMap *)(intptr_t)map, key);
  return s >= 0 ? ((QzIntMap *)(intptr_t)map)->values[s] : 0;
}

qz_val qz_intmap_has(qz_val map, qz_val key) {
  return im_find((QzIntMap *)(intptr_t)map, key) >= 0 ? 1 : 0;
}

void qz_intmap_del(qz_val map, qz_val key) {
  QzIntMap *m = (QzIntMap *)(intptr_t)map;
  int64_t s = im_find(m, key);
  if (s >= 0) {
    m->states[s] = HM_DELETED;
    m->size--;
  }
}

void qz_intmap_free(qz_val map) {
  QzIntMap *m = (QzIntMap *)(intptr_t)map;
  free(m->keys);
  free(m->values);
  free(m->states);
  free(m);
}

/* ======== Set (backed by HashMap, value=1) ======== */

qz_val qz_set_new(void) { return qz_hashmap_new(); }
void qz_set_add(qz_val s, qz_val v) { qz_hashmap_set(s, v, 1); }
qz_val qz_set_contains(qz_val s, qz_val v) { return qz_hashmap_has(s, v); }
void qz_set_remove(qz_val s, qz_val v) { qz_hashmap_del(s, v); }
qz_val qz_set_size(qz_val s) { return qz_hashmap_size(s); }
qz_val qz_set_members(qz_val s) { return qz_hashmap_keys(s); }
void qz_set_clear(qz_val s) { qz_hashmap_clear(s); }
void qz_set_free(qz_val s) { qz_hashmap_free(s); }

qz_val qz_set_union(qz_val a, qz_val b) {
  qz_val r = qz_set_new();
  qz_val ka = qz_hashmap_keys(a), kb = qz_hashmap_keys(b);
  int64_t *ha = (int64_t *)(intptr_t)ka;
  int64_t *da = (int64_t *)(intptr_t)ha[2];
  for (int64_t i = 0; i < ha[1]; i++)
    qz_set_add(r, da[i]);
  int64_t *hb = (int64_t *)(intptr_t)kb;
  int64_t *db = (int64_t *)(intptr_t)hb[2];
  for (int64_t i = 0; i < hb[1]; i++)
    qz_set_add(r, db[i]);
  return r;
}

qz_val qz_set_intersection(qz_val a, qz_val b) {
  qz_val r = qz_set_new();
  qz_val ka = qz_hashmap_keys(a);
  int64_t *h = (int64_t *)(intptr_t)ka;
  int64_t *d = (int64_t *)(intptr_t)h[2];
  for (int64_t i = 0; i < h[1]; i++)
    if (qz_hashmap_has(b, d[i]))
      qz_set_add(r, d[i]);
  return r;
}

qz_val qz_set_difference(qz_val a, qz_val b) {
  qz_val r = qz_set_new();
  qz_val ka = qz_hashmap_keys(a);
  int64_t *h = (int64_t *)(intptr_t)ka;
  int64_t *d = (int64_t *)(intptr_t)h[2];
  for (int64_t i = 0; i < h[1]; i++)
    if (!qz_hashmap_has(b, d[i]))
      qz_set_add(r, d[i]);
  return r;
}

qz_val qz_set_is_subset(qz_val a, qz_val b) {
  qz_val ka = qz_hashmap_keys(a);
  int64_t *h = (int64_t *)(intptr_t)ka;
  int64_t *d = (int64_t *)(intptr_t)h[2];
  for (int64_t i = 0; i < h[1]; i++)
    if (!qz_hashmap_has(b, d[i]))
      return 0;
  return 1;
}

/* ======== Option ========
 * Layout: 16-byte [tag(i64), value(i64)], tag=0 → Some, tag=1 → None */

qz_val qz_option_some(qz_val val) {
  int64_t *p = (int64_t *)malloc(16);
  p[0] = 0;
  p[1] = val;
  return (qz_val)(intptr_t)p;
}

qz_val qz_option_none(void) {
  int64_t *p = (int64_t *)malloc(16);
  p[0] = 1;
  p[1] = 0;
  return (qz_val)(intptr_t)p;
}

qz_val qz_option_is_some(qz_val opt) {
  return ((int64_t *)(intptr_t)opt)[0] == 0 ? 1 : 0;
}

qz_val qz_option_get(qz_val opt) { return ((int64_t *)(intptr_t)opt)[1]; }

void qz_option_free(qz_val opt) { free((void *)(intptr_t)opt); }

/* ======== I/O ======== */

qz_val qz_read_file(qz_val path) {
  FILE *f = fopen((char *)(intptr_t)path, "rb");
  if (!f)
    return qz_alloc_str(0);
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  qz_val r = qz_alloc_str(sz);
  fread((char *)(intptr_t)r, 1, sz, f);
  fclose(f);
  return r;
}

qz_val qz_write_file(qz_val path, qz_val content) {
  FILE *f = fopen((char *)(intptr_t)path, "wb");
  if (!f)
    return 0;
  int64_t len = qz_str_len(content);
  fwrite((char *)(intptr_t)content, 1, len, f);
  fclose(f);
  return 1;
}

qz_val qz_file_exists(qz_val path) {
  return access((char *)(intptr_t)path, F_OK) == 0 ? 1 : 0;
}

qz_val qz_file_size(qz_val path) {
  struct stat st;
  if (stat((char *)(intptr_t)path, &st) != 0)
    return -1;
  return (qz_val)st.st_size;
}

qz_val qz_file_delete(qz_val path) {
  return unlink((char *)(intptr_t)path) == 0 ? 1 : 0;
}

qz_val qz_read_line(void) {
  char buf[4096];
  if (!fgets(buf, sizeof(buf), stdin))
    return qz_alloc_str(0);
  int64_t len = strlen(buf);
  if (len > 0 && buf[len - 1] == '\n')
    len--;
  qz_val r = qz_alloc_str(len);
  memcpy((char *)(intptr_t)r, buf, len);
  return r;
}

qz_val qz_readdir(qz_val path) {
  qz_val result = qz_vec_new();
  DIR *d = opendir((char *)(intptr_t)path);
  if (!d)
    return result;
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
      continue;
    qz_vec_push(result, qz_cstr_to_string((qz_val)(intptr_t)ent->d_name));
  }
  closedir(d);
  return result;
}

qz_val qz_getcwd(void) {
  char buf[4096];
  if (!getcwd(buf, sizeof(buf)))
    return qz_alloc_str(0);
  return qz_cstr_to_string((qz_val)(intptr_t)buf);
}

qz_val qz_path_join(qz_val a, qz_val b) {
  qz_val slash = qz_alloc_str(1);
  ((char *)(intptr_t)slash)[0] = '/';
  return qz_str_concat(qz_str_concat(a, slash), b);
}

qz_val qz_path_basename(qz_val path) {
  char *p = (char *)(intptr_t)path;
  char *last = strrchr(p, '/');
  if (!last)
    return path;
  return qz_cstr_to_string((qz_val)(intptr_t)(last + 1));
}

qz_val qz_path_dir(qz_val path) {
  char *p = (char *)(intptr_t)path;
  char *last = strrchr(p, '/');
  if (!last)
    return qz_alloc_str(1); /* "." */
  return qz_str_slice(path, 0, last - p);
}

qz_val qz_path_ext(qz_val path) {
  char *p = (char *)(intptr_t)path;
  char *dot = strrchr(p, '.');
  if (!dot)
    return qz_alloc_str(0);
  return qz_cstr_to_string((qz_val)(intptr_t)dot);
}

/* ======== Call Dispatch (Closure Support) ========
 * Tagged pointer: low bit = 1 means closure.
 * Closure env: env[0] = fn pointer, env[1..] = captured values.
 * Closure fn signature: fn(env_ptr, args...) */

qz_val qz_call_0(qz_val fn_val) {
  if (fn_val & 1) {
    int64_t *e = (int64_t *)(intptr_t)(fn_val & ~1L);
    return ((qz_val (*)(qz_val))(intptr_t)e[0])((qz_val)(intptr_t)e);
  }
  return ((qz_val (*)(void))(intptr_t)fn_val)();
}

qz_val qz_call_1(qz_val fn_val, qz_val a0) {
  if (fn_val & 1) {
    int64_t *e = (int64_t *)(intptr_t)(fn_val & ~1L);
    return ((qz_val (*)(qz_val, qz_val))(intptr_t)e[0])((qz_val)(intptr_t)e,
                                                        a0);
  }
  return ((qz_val (*)(qz_val))(intptr_t)fn_val)(a0);
}

qz_val qz_call_2(qz_val fn_val, qz_val a0, qz_val a1) {
  if (fn_val & 1) {
    int64_t *e = (int64_t *)(intptr_t)(fn_val & ~1L);
    return ((qz_val (*)(qz_val, qz_val, qz_val))(intptr_t)e[0])(
        (qz_val)(intptr_t)e, a0, a1);
  }
  return ((qz_val (*)(qz_val, qz_val))(intptr_t)fn_val)(a0, a1);
}

qz_val qz_call_3(qz_val fn_val, qz_val a0, qz_val a1, qz_val a2) {
  if (fn_val & 1) {
    int64_t *e = (int64_t *)(intptr_t)(fn_val & ~1L);
    return ((qz_val (*)(qz_val, qz_val, qz_val, qz_val))(intptr_t)e[0])(
        (qz_val)(intptr_t)e, a0, a1, a2);
  }
  return ((qz_val (*)(qz_val, qz_val, qz_val))(intptr_t)fn_val)(a0, a1, a2);
}

qz_val qz_call_4(qz_val fn_val, qz_val a0, qz_val a1, qz_val a2, qz_val a3) {
  if (fn_val & 1) {
    int64_t *e = (int64_t *)(intptr_t)(fn_val & ~1L);
    return ((qz_val (*)(qz_val, qz_val, qz_val, qz_val, qz_val))(intptr_t)e[0])(
        (qz_val)(intptr_t)e, a0, a1, a2, a3);
  }
  return ((qz_val (*)(qz_val, qz_val, qz_val, qz_val))(intptr_t)fn_val)(a0, a1,
                                                                        a2, a3);
}

qz_val qz_call_5(qz_val fn_val, qz_val a0, qz_val a1, qz_val a2, qz_val a3,
                 qz_val a4) {
  if (fn_val & 1) {
    int64_t *e = (int64_t *)(intptr_t)(fn_val & ~1L);
    return ((qz_val (*)(qz_val, qz_val, qz_val, qz_val, qz_val, qz_val))(
        intptr_t)e[0])((qz_val)(intptr_t)e, a0, a1, a2, a3, a4);
  }
  return ((qz_val (*)(qz_val, qz_val, qz_val, qz_val, qz_val))(intptr_t)fn_val)(
      a0, a1, a2, a3, a4);
}
