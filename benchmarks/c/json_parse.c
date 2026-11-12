/* JSON parse benchmark — C equivalent
 * Matches the Quartz json_parse.qz benchmark exactly:
 *   1. Generate a JSON array of 100K objects
 *   2. Parse it 10 times, counting all values (strings, numbers,
 * true/false/null)
 *
 * Same algorithm: char-by-char scanning, no external JSON library.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NUM_OBJECTS 100000
#define PARSE_ITERATIONS 10

/* ─── Dynamic string builder (matches Quartz StringBuilder) ──────────────── */

typedef struct {
  char *data;
  int len;
  int cap;
} StringBuilder;

static StringBuilder sb_new(void) {
  StringBuilder sb;
  sb.cap = 256;
  sb.data = malloc(sb.cap);
  sb.len = 0;
  sb.data[0] = '\0';
  return sb;
}

static void sb_ensure(StringBuilder *sb, int extra) {
  while (sb->len + extra + 1 > sb->cap) {
    sb->cap *= 2;
    sb->data = realloc(sb->data, sb->cap);
  }
}

static void sb_append(StringBuilder *sb, const char *s) {
  int slen = strlen(s);
  sb_ensure(sb, slen);
  memcpy(sb->data + sb->len, s, slen);
  sb->len += slen;
  sb->data[sb->len] = '\0';
}

static void sb_append_int(StringBuilder *sb, int n) {
  char buf[32];
  snprintf(buf, sizeof(buf), "%d", n);
  sb_append(sb, buf);
}

static char *sb_to_string(StringBuilder *sb) {
  char *result = malloc(sb->len + 1);
  memcpy(result, sb->data, sb->len + 1);
  return result;
}

static void sb_free(StringBuilder *sb) {
  free(sb->data);
  sb->data = NULL;
  sb->len = 0;
  sb->cap = 0;
}

/* ─── JSON generation ────────────────────────────────────────────────────── */

static char *generate_json(int n, int *out_len) {
  StringBuilder sb = sb_new();
  sb_append(&sb, "[");
  for (int i = 0; i < n; i++) {
    if (i > 0)
      sb_append(&sb, ",");
    sb_append(&sb, "{\"id\":");
    sb_append_int(&sb, i);
    sb_append(&sb, ",\"name\":\"item_");
    sb_append_int(&sb, i);
    sb_append(&sb, "\",\"value\":");
    sb_append_int(&sb, i * 17 + 42);
    sb_append(&sb, ",\"active\":");
    if (i % 3 == 0)
      sb_append(&sb, "true");
    else
      sb_append(&sb, "false");
    sb_append(&sb, "}");
  }
  sb_append(&sb, "]");
  *out_len = sb.len;
  char *result = sb_to_string(&sb);
  sb_free(&sb);
  return result;
}

/* ─── Parsing (matches Quartz code exactly) ──────────────────────────────── */

static int skip_whitespace(const char *s, int len, int pos) {
  while (pos < len) {
    char c = s[pos];
    if (c != ' ' && c != '\n' && c != '\r' && c != '\t')
      return pos;
    pos++;
  }
  return pos;
}

/* Skip a JSON string starting at the opening '"', return position after closing
 * '"' */
static int skip_string(const char *s, int len, int pos) {
  int i = pos + 1; /* skip opening " */
  while (i < len) {
    char c = s[i];
    if (c == '"')
      return i + 1;
    if (c == '\\') {
      i++; /* skip escaped character */
    }
    i++;
  }
  return i;
}

/* Skip a JSON number, return position after last digit */
static int skip_number(const char *s, int len, int pos) {
  int i = pos;
  if (i < len && s[i] == '-')
    i++;
  while (i < len && s[i] >= '0' && s[i] <= '9')
    i++;
  return i;
}

/* Count all JSON values in the string (strings, numbers, true, false, null) */
static int count_values(const char *s, int len) {
  int count = 0;
  int i = 0;
  while (i < len) {
    i = skip_whitespace(s, len, i);
    if (i >= len)
      break;

    char c = s[i];
    if (c == '"') {
      i = skip_string(s, len, i);
      count++;
    } else if ((c >= '0' && c <= '9') || c == '-') {
      i = skip_number(s, len, i);
      count++;
    } else if (c == 't') { /* true */
      i += 4;
      count++;
    } else if (c == 'f') { /* false */
      i += 5;
      count++;
    } else if (c == 'n') { /* null */
      i += 4;
      count++;
    } else {
      i++; /* structural chars: { } [ ] , : */
    }
  }
  return count;
}

/* ─── Main ───────────────────────────────────────────────────────────────── */

int main(void) {
  int json_len = 0;
  char *json = generate_json(NUM_OBJECTS, &json_len);
  printf("Generated JSON: %d bytes\n", json_len);

  long total = 0;
  for (int i = 0; i < PARSE_ITERATIONS; i++) {
    total += count_values(json, json_len);
  }

  printf("Total values parsed: %ld\n", total);

  free(json);
  return 0;
}
