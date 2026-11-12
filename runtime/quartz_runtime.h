/*
 * Quartz Runtime Library — C Backend
 *
 * Implements Quartz's core data structures (Vec, StringBuilder, HashMap,
 * String ops) in C. Memory layouts exactly match the LLVM backend so that
 * MIR-level code emitted by codegen_c.qz interoperates correctly.
 *
 * All values are int64_t (Quartz's existential type model).
 */

#ifndef QUARTZ_RUNTIME_H
#define QUARTZ_RUNTIME_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dirent.h>
#include <ctype.h>
#include <math.h>

typedef int64_t qz_val;

/* ========================================================================
 * String Operations
 *
 * Quartz strings are length-prefixed:
 *   [8-byte i64 length] [data bytes ...] [\0]
 *
 * The qz_val holds a pointer to the first data byte (NOT the length header).
 * str_len reads *(int64_t*)(ptr - 8).
 * ======================================================================== */

/* Allocate a new Quartz string with given length (uninitialized data). */
qz_val qz_alloc_str(int64_t len);

/* Get length of a Quartz string (reads the 8-byte prefix). */
int64_t qz_str_len(qz_val s);

/* Concatenate two Quartz strings. */
qz_val qz_str_concat(qz_val a, qz_val b);

/* Compare two Quartz strings for equality. Returns 1 or 0. */
qz_val qz_str_eq(qz_val a, qz_val b);

/* Get character code at index. */
qz_val qz_str_char_at(qz_val s, qz_val idx);

/* Get a slice of a string [start, end). Returns new string. */
qz_val qz_str_slice(qz_val s, qz_val start, qz_val end);

/* Convert int64_t to Quartz string. */
qz_val qz_str_from_int(qz_val n);

/* Convert Quartz string to int64_t. */
qz_val qz_str_to_int(qz_val s);

/* Check if string contains substring. */
qz_val qz_str_contains(qz_val haystack, qz_val needle);

/* Find index of substring, or -1. */
qz_val qz_str_find(qz_val haystack, qz_val needle);

/* Check if string starts with prefix. */
qz_val qz_str_starts_with(qz_val s, qz_val prefix);

/* Check if string ends with suffix. */
qz_val qz_str_ends_with(qz_val s, qz_val suffix);

/* Create string from single character code. */
qz_val qz_str_from_char(qz_val ch);

/* Hash a Quartz string (FNV-1a). */
qz_val qz_str_hash(qz_val s);

/* Replace all occurrences of old with new in s. */
qz_val qz_str_replace(qz_val s, qz_val old_s, qz_val new_s);

/* Split string by delimiter, returns Vec<String>. */
qz_val qz_str_split(qz_val s, qz_val delim);

/* Trim whitespace from both sides. */
qz_val qz_str_trim(qz_val s);
qz_val qz_str_trim_left(qz_val s);
qz_val qz_str_trim_right(qz_val s);

/* Case conversion. */
qz_val qz_str_downcase(qz_val s);
qz_val qz_str_upcase(qz_val s);

/* Join Vec<String> with separator. */
qz_val qz_str_join(qz_val vec, qz_val sep);

/* Repeat a string N times. */
qz_val qz_str_repeat(qz_val s, qz_val n);

/* Count occurrences of substring. */
qz_val qz_str_count(qz_val s, qz_val sub);

/* Check if string is empty. */
qz_val qz_str_is_empty(qz_val s);

/* String to/from C pointer. */
qz_val qz_cstr_to_string(qz_val cstr);
qz_val qz_string_to_cstr(qz_val s);

/* String to/from F64. */
qz_val qz_str_to_f64(qz_val s);
qz_val qz_f64_to_str(qz_val bits);

/* Reverse a string. */
qz_val qz_str_reverse(qz_val s);

/* Pad left/right. */
qz_val qz_str_pad_left(qz_val s, qz_val width, qz_val pad_char);
qz_val qz_str_pad_right(qz_val s, qz_val width, qz_val pad_char);

/* UTF-8 codepoint at byte index (returns codepoint value). */
qz_val qz_str_codepoint_at(qz_val s, qz_val idx);

/* UTF-8 length (number of codepoints). */
qz_val qz_str_len_utf8(qz_val s);

/* Get substring by start and length. */
qz_val qz_str_substr(qz_val s, qz_val start, qz_val length);

/* String to/from raw pointer. */
qz_val qz_str_to_ptr(qz_val s);
qz_val qz_str_from_ptr(qz_val ptr, qz_val len);

/* Chars: returns Vec<Int> of character codes. */
qz_val qz_str_chars(qz_val s);

/* ========================================================================
 * StringBuilder
 *
 * Layout: 24-byte header [capacity(i64), length(i64), data_ptr(i64)]
 * ======================================================================== */

qz_val qz_sb_new(void);
void   qz_sb_append(qz_val sb, qz_val s);
void   qz_sb_append_char(qz_val sb, qz_val ch);
void   qz_sb_append_int(qz_val sb, qz_val n);
qz_val qz_sb_to_string(qz_val sb);
void   qz_sb_clear(qz_val sb);
void   qz_sb_free(qz_val sb);
qz_val qz_sb_len(qz_val sb);

/* ========================================================================
 * Vec
 *
 * Layout: 32-byte header [capacity(i64), size(i64), data_ptr(i64), elem_width(i64)]
 * Default elem_width = 8 (i64).
 * ======================================================================== */

qz_val qz_vec_new(void);
void   qz_vec_push(qz_val vec, qz_val val);
qz_val qz_vec_get(qz_val vec, qz_val idx);
void   qz_vec_set(qz_val vec, qz_val idx, qz_val val);
qz_val qz_vec_pop(qz_val vec);
qz_val qz_vec_len(qz_val vec);
void   qz_vec_free(qz_val vec);
void   qz_vec_clear(qz_val vec);
qz_val qz_vec_contains(qz_val vec, qz_val val);
qz_val qz_vec_index_of(qz_val vec, qz_val val);
void   qz_vec_insert(qz_val vec, qz_val idx, qz_val val);
qz_val qz_vec_remove(qz_val vec, qz_val idx);
qz_val qz_vec_clone(qz_val vec);
void   qz_vec_sort(qz_val vec);
void   qz_vec_sort_by(qz_val vec, qz_val cmp_fn);
qz_val qz_vec_reverse(qz_val vec);
qz_val qz_vec_join(qz_val vec, qz_val sep);
qz_val qz_vec_slice(qz_val vec, qz_val start, qz_val len);
qz_val qz_vec_new_filled(qz_val count, qz_val fill);
qz_val qz_vec_get_unchecked(qz_val vec, qz_val idx);
void   qz_vec_set_unchecked(qz_val vec, qz_val idx, qz_val val);

/* ========================================================================
 * HashMap
 *
 * Open-addressing hash table with string keys.
 * ======================================================================== */

qz_val qz_hashmap_new(void);
void   qz_hashmap_set(qz_val map, qz_val key, qz_val val);
qz_val qz_hashmap_get(qz_val map, qz_val key);
qz_val qz_hashmap_has(qz_val map, qz_val key);
void   qz_hashmap_del(qz_val map, qz_val key);
qz_val qz_hashmap_keys(qz_val map);
qz_val qz_hashmap_values(qz_val map);
qz_val qz_hashmap_size(qz_val map);
void   qz_hashmap_free(qz_val map);
void   qz_hashmap_clear(qz_val map);

/* ========================================================================
 * IntMap (integer-keyed hash map)
 * ======================================================================== */

qz_val qz_intmap_new(void);
void   qz_intmap_set(qz_val map, qz_val key, qz_val val);
qz_val qz_intmap_get(qz_val map, qz_val key);
qz_val qz_intmap_has(qz_val map, qz_val key);
void   qz_intmap_del(qz_val map, qz_val key);
void   qz_intmap_free(qz_val map);

/* ========================================================================
 * Set (string-keyed set, backed by HashMap)
 * ======================================================================== */

qz_val qz_set_new(void);
void   qz_set_add(qz_val set, qz_val val);
qz_val qz_set_contains(qz_val set, qz_val val);
void   qz_set_remove(qz_val set, qz_val val);
qz_val qz_set_size(qz_val set);
qz_val qz_set_members(qz_val set);
void   qz_set_clear(qz_val set);
void   qz_set_free(qz_val set);
qz_val qz_set_union(qz_val a, qz_val b);
qz_val qz_set_intersection(qz_val a, qz_val b);
qz_val qz_set_difference(qz_val a, qz_val b);
qz_val qz_set_is_subset(qz_val a, qz_val b);

/* ========================================================================
 * Option (tagged pair: [tag(i64), value(i64)])
 * tag=0 → Some, tag=1 → None
 * ======================================================================== */

qz_val qz_option_some(qz_val val);
qz_val qz_option_none(void);
qz_val qz_option_is_some(qz_val opt);
qz_val qz_option_get(qz_val opt);
void   qz_option_free(qz_val opt);

/* ========================================================================
 * I/O
 * ======================================================================== */

qz_val qz_read_file(qz_val path);
qz_val qz_write_file(qz_val path, qz_val content);
qz_val qz_file_exists(qz_val path);
qz_val qz_file_size(qz_val path);
qz_val qz_file_delete(qz_val path);
qz_val qz_read_line(void);
qz_val qz_readdir(qz_val path);
qz_val qz_getcwd(void);
qz_val qz_path_join(qz_val a, qz_val b);
qz_val qz_path_basename(qz_val path);
qz_val qz_path_dir(qz_val path);
qz_val qz_path_ext(qz_val path);

/* ========================================================================
 * Call dispatch (closure support)
 * ======================================================================== */

qz_val qz_call_0(qz_val fn_val);
qz_val qz_call_1(qz_val fn_val, qz_val a0);
qz_val qz_call_2(qz_val fn_val, qz_val a0, qz_val a1);
qz_val qz_call_3(qz_val fn_val, qz_val a0, qz_val a1, qz_val a2);
qz_val qz_call_4(qz_val fn_val, qz_val a0, qz_val a1, qz_val a2, qz_val a3);
qz_val qz_call_5(qz_val fn_val, qz_val a0, qz_val a1, qz_val a2, qz_val a3, qz_val a4);

#endif /* QUARTZ_RUNTIME_H */
